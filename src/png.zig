/// PNG decode via vendored stb_image, in a Zig-allocator-friendly form.
///
/// Self-contained so the decode logic can be unit-tested without
/// libghostty's allocator interface.  `sys.zig` wraps this for the
/// libghostty `decode_png` callback contract.
const std = @import("std");
const gt = @import("ghostty-vt");
const stb = @import("stb_image_c");

pub const DecodeError = error{
    EmptyData,
    InvalidData,
    OutOfMemory,
    OverflowDimensions,
};

/// Decode a PNG buffer to RGBA pixels.
///
/// Returns a `DecodedImage` whose `data` slice is owned by `allocator`.
/// Caller is responsible for `allocator.free(result.data)`.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) gt.sys.DecodeError!gt.sys.Image {
    if (data.len == 0) return error.InvalidData;

    // stb takes the size as c_int — refuse payloads that don't fit.
    // PNGs above 2 GiB aren't a real-world kitty graphics use case.
    const data_len_int = std.math.cast(c_int, data.len) orelse return error.InvalidData;

    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const pixels = stb.stbi_load_from_memory(
        data.ptr,
        data_len_int,
        &w,
        &h,
        &channels,
        4, // force RGBA
    ) orelse return error.InvalidData;
    defer stb.stbi_image_free(pixels);

    if (w <= 0 or h <= 0) return error.InvalidData;

    // Compute pixel_len with checked arithmetic — defends against a
    // hostile/corrupt PNG where w*h*4 overflows usize.
    const w_usize: usize = @intCast(w);
    const h_usize: usize = @intCast(h);
    const wh = std.math.mul(usize, w_usize, h_usize) catch return error.InvalidData;
    const pixel_len = std.math.mul(usize, wh, 4) catch return error.InvalidData;

    const buf = try allocator.alloc(u8, pixel_len);
    @memcpy(buf, pixels[0..pixel_len]);

    return .{
        .data = buf,
        .width = @intCast(w),
        .height = @intCast(h),
    };
}

/// Encode straight-alpha RGBA, optionally using a stride for a canvas subregion.
pub fn encode(allocator: std.mem.Allocator, data: []const u8, width: u32, height: u32, stride: u32) ![]u8 {
    const row_bytes = try std.math.mul(u32, width, 4);
    if (width == 0 or height == 0 or stride < row_bytes) return error.InvalidImage;
    const needed = try std.math.add(usize, try std.math.mul(usize, height - 1, stride), row_bytes);
    if (data.len < needed) return error.InvalidImage;
    const Context = struct {
        alloc: std.mem.Allocator,
        bytes: std.ArrayList(u8) = .empty,
        failure: ?std.mem.Allocator.Error = null,

        fn write(context: ?*anyopaque, ptr: ?*anyopaque, size: c_int) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.failure != null) return;
            const chunk: [*]const u8 = @ptrCast(ptr.?);
            self.bytes.appendSlice(self.alloc, chunk[0..@intCast(size)]) catch |err| {
                self.failure = err;
            };
        }
    };
    var context: Context = .{ .alloc = allocator };
    errdefer context.bytes.deinit(allocator);
    const ok = stb.stbi_write_png_to_func(
        &Context.write,
        &context,
        std.math.cast(c_int, width) orelse return error.ImageTooLarge,
        std.math.cast(c_int, height) orelse return error.ImageTooLarge,
        4,
        data.ptr,
        std.math.cast(c_int, stride) orelse return error.ImageTooLarge,
    );
    if (context.failure) |err| return err;
    if (ok == 0) return error.PngEncodeFailed;
    return context.bytes.toOwnedSlice(allocator);
}

fn compressZlib(allocator: std.mem.Allocator, data: []const u8) std.mem.Allocator.Error![]u8 {
    const flate = std.compress.flate;
    const Workspace = struct {
        history: [flate.max_window_len]u8,
        compressor: flate.Compress,
    };
    const workspace = try allocator.create(Workspace);
    defer allocator.destroy(workspace);
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 128);
    defer output.deinit();
    // This writer only fails when its output buffer cannot grow.
    workspace.compressor = flate.Compress.init(&output.writer, &workspace.history, .zlib, .fastest) catch
        return error.OutOfMemory;
    workspace.compressor.writer.writeAll(data) catch return error.OutOfMemory;
    workspace.compressor.finish() catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

/// stb's compression hook: return a malloc-compatible buffer or null on failure.
export fn ghostel_png_compress(data: [*]const u8, data_len: c_int, out_len: *c_int, _: c_int) callconv(.c) ?[*]u8 {
    const len = std.math.cast(usize, data_len) orelse return null;
    // Byte-aligned c_allocator allocations are released by stb's ordinary free.
    const compressed = compressZlib(std.heap.c_allocator, data[0..len]) catch return null;
    out_len.* = std.math.cast(c_int, compressed.len) orelse {
        std.heap.c_allocator.free(compressed);
        return null;
    };
    return compressed.ptr;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// 2x2 RGBA PNG, generated via Python's zlib + struct (see commit
// for the generator script).  Pixel layout (row-major):
//   (0,0) red   opaque    (1,0) blue  opaque
//   (0,1) green opaque    (1,1) (0,0,0) fully transparent
const TINY_PNG_2x2 = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00,
    0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02,
    0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72,
    0xB6, 0x0D, 0x24, 0x00, 0x00, 0x00, 0x13, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x42, 0x60,
    0x0A, 0x48, 0x30, 0x30, 0x00, 0x00, 0x3F, 0xD2, 0x05, 0xFB,
    0x07, 0x27, 0x46, 0xD2, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

test "decode: 2x2 RGBA PNG yields expected dimensions and pixels" {
    const result = try decode(testing.allocator, &TINY_PNG_2x2);
    defer testing.allocator.free(result.data);
    try testing.expectEqual(@as(u32, 2), result.width);
    try testing.expectEqual(@as(u32, 2), result.height);
    try testing.expectEqual(@as(usize, 16), result.data.len);
    // Pixel (0,0): red opaque
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x00, 0x00, 0xFF }, result.data[0..4]);
    // Pixel (1,1): fully transparent — alpha = 0
    try testing.expectEqual(@as(u8, 0), result.data[15]);
}

test "encode: strided RGBA roundtrips with alpha" {
    const rgba = [_]u8{ 0, 0, 0, 0, 255, 0, 0, 128, 0, 0, 0, 0, 0, 0, 255, 255 };
    const encoded = try encode(testing.allocator, rgba[4..], 1, 2, 8);
    defer testing.allocator.free(encoded);
    const decoded = try decode(testing.allocator, encoded);
    defer testing.allocator.free(decoded.data);
    try testing.expectEqual(@as(u32, 1), decoded.width);
    try testing.expectEqual(@as(u32, 2), decoded.height);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128, 0, 0, 255, 255 }, decoded.data);
}

test "encode: compression propagates allocation failures without leaking" {
    const Exercise = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var data: [std.compress.flate.max_window_len + 1]u8 = undefined;
            var random = std.Random.DefaultPrng.init(0);
            random.random().bytes(&data);
            const compressed = try compressZlib(allocator, &data);
            defer allocator.free(compressed);
            var input: std.Io.Reader = .fixed(compressed);
            var history: [std.compress.flate.max_window_len]u8 = undefined;
            var decompressor: std.compress.flate.Decompress = .init(&input, .zlib, &history);
            var restored: [data.len]u8 = undefined;
            try decompressor.reader.readSliceAll(&restored);
            try testing.expectError(error.EndOfStream, decompressor.reader.takeByte());
            try testing.expectEqualSlices(u8, &data, &restored);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Exercise.run, .{});
}

test "encode: output allocation failures propagate without leaking" {
    const Exercise = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const encoded = try encode(allocator, &.{ 255, 0, 0, 128 }, 1, 1, 4);
            defer allocator.free(encoded);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Exercise.run, .{});
}

test "decode: empty data returns InvalidData" {
    const empty = [_]u8{};
    try testing.expectError(error.InvalidData, decode(testing.allocator, &empty));
}

test "decode: garbage bytes return InvalidData" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03 };
    try testing.expectError(error.InvalidData, decode(testing.allocator, &garbage));
}

test "decode: truncated PNG header returns InvalidData" {
    // First 16 bytes — IHDR length declared but body incomplete.
    const truncated = TINY_PNG_2x2[0..16];
    try testing.expectError(error.InvalidData, decode(testing.allocator, truncated));
}
