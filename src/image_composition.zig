//! Axis-aligned image composition into bounded, transparent row bands.
const std = @import("std");
const stb = @import("stb_image_c");
const SourceRect = @import("ghostty-vt").kitty.graphics.ImageStorage.Placement.SourceRect;
const Allocator = std.mem.Allocator;

const max_scratch_bytes = 64 * 1024 * 1024;

/// Reused across layers and rows; stb requests one aligned working block per resize.
pub const Scratch = struct {
    sampled: std.ArrayList(u8) = .empty,
    working: std.array_list.Aligned(u8, .@"16") = .empty,

    pub fn deinit(self: *Scratch, alloc: Allocator) void {
        self.sampled.deinit(alloc);
        self.working.deinit(alloc);
    }
};

const ResizeContext = struct {
    scratch: *Scratch,
    alloc: Allocator,
    failure: ?anyerror = null,

    fn acquire(context: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (size > max_scratch_bytes) {
            self.failure = error.ImageTooLarge;
            return null;
        }
        self.scratch.working.ensureTotalCapacityPrecise(self.alloc, size) catch |err| {
            self.failure = err;
            return null;
        };
        return self.scratch.working.items.ptr;
    }
};

pub const Source = struct {
    data: []const u8,
    width: u32,
    height: u32,
    channels: u32,
};

pub const Destination = struct { x: i64, y: i64, width: u32, height: u32 };

/// The canvas contains premultiplied RGBA. SOURCE contains straight-alpha pixels.
/// Clip before allocating: even enormous protocol placements only allocate the
/// portion that intersects this band. Sampling uses the full placement transform,
/// so rendering successive bands doesn't introduce new filter boundaries.
pub fn draw(
    alloc: Allocator,
    scratch: *Scratch,
    canvas: []u8,
    width: u32,
    height: u32,
    source: Source,
    rect: SourceRect,
    dest: Destination,
    clip: ?Destination,
) !void {
    if (rect.width == 0 or rect.height == 0 or dest.width == 0 or dest.height == 0) return;
    if (source.channels == 0 or source.channels > 4 or
        rect.width > source.width or rect.height > source.height or
        rect.x > source.width - rect.width or rect.y > source.height - rect.height)
        return error.InvalidImage;
    const stride = try std.math.mul(u32, source.width, source.channels);
    const source_len = try std.math.mul(usize, stride, source.height);
    if (source.data.len < source_len) return error.InvalidImage;
    const canvas_len = try byteLength(width, height);
    if (canvas.len < canvas_len) return error.InvalidCanvas;

    const bounds = clip orelse Destination{ .x = 0, .y = 0, .width = width, .height = height };
    const left = @max(0, @max(dest.x, bounds.x));
    const top = @max(0, @max(dest.y, bounds.y));
    const right = @min(@as(i64, width), @min(dest.x + dest.width, bounds.x + bounds.width));
    const bottom = @min(@as(i64, height), @min(dest.y + dest.height, bounds.y + bounds.height));
    if (left >= right or top >= bottom) return;
    const w: u32 = @intCast(right - left);
    const h: u32 = @intCast(bottom - top);
    const offset = @as(usize, rect.y) * stride + @as(usize, rect.x) * source.channels;

    var pixels = source.data[offset..];
    var pixel_stride = stride;
    if (dest.width == rect.width and dest.height == rect.height) {
        const skip = @as(usize, @intCast(top - dest.y)) * stride +
            @as(usize, @intCast(left - dest.x)) * source.channels;
        pixels = pixels[skip..];
    } else {
        try checkResizeScratch(rect, dest, w, h, source.channels);
        const output_len = try std.math.mul(usize, try std.math.mul(usize, w, h), source.channels);
        try scratch.sampled.ensureTotalCapacityPrecise(alloc, output_len);
        scratch.sampled.items.len = output_len;
        var context: ResizeContext = .{ .scratch = scratch, .alloc = alloc };
        var callbacks: stb.GhostelResizeScratch = .{
            .context = &context,
            .acquire = &ResizeContext.acquire,
        };
        const alpha: c_int = if (source.channels == 2 or source.channels == 4)
            @intCast(source.channels - 1)
        else
            stb.STBIR_ALPHA_CHANNEL_NONE;
        const ok = stb.stbir_resize_subpixel(
            pixels.ptr,
            std.math.cast(c_int, rect.width) orelse return error.ImageTooLarge,
            std.math.cast(c_int, rect.height) orelse return error.ImageTooLarge,
            std.math.cast(c_int, stride) orelse return error.ImageTooLarge,
            scratch.sampled.items.ptr,
            std.math.cast(c_int, w) orelse return error.ImageTooLarge,
            std.math.cast(c_int, h) orelse return error.ImageTooLarge,
            0,
            stb.STBIR_TYPE_UINT8,
            @intCast(source.channels),
            alpha,
            0,
            stb.STBIR_EDGE_CLAMP,
            stb.STBIR_EDGE_CLAMP,
            stb.STBIR_FILTER_TRIANGLE,
            stb.STBIR_FILTER_TRIANGLE,
            stb.STBIR_COLORSPACE_LINEAR,
            &callbacks,
            @as(f32, @floatFromInt(dest.width)) / @as(f32, @floatFromInt(rect.width)),
            @as(f32, @floatFromInt(dest.height)) / @as(f32, @floatFromInt(rect.height)),
            @floatFromInt(left - dest.x),
            @floatFromInt(top - dest.y),
        );
        if (context.failure) |err| return err;
        if (ok == 0) return error.ImageResizeFailed;
        pixels = scratch.sampled.items;
        pixel_stride = w * source.channels;
    }

    for (0..h) |y| {
        for (0..w) |x| {
            const src = pixels[y * pixel_stride + x * source.channels ..][0..source.channels];
            const dst_offset = ((@as(usize, @intCast(top)) + y) * width +
                @as(usize, @intCast(left)) + x) * 4;
            const a: u32 = if (source.channels == 2 or source.channels == 4) src[src.len - 1] else 255;
            if (a == 0) continue;
            const inv = 255 - a;
            for (0..3) |c| {
                const color: u32 = if (source.channels < 3) src[0] else src[c];
                canvas[dst_offset + c] = @intCast((color * a + @as(u32, canvas[dst_offset + c]) * inv + 127) / 255);
            }
            canvas[dst_offset + 3] = @intCast(a + (@as(u32, canvas[dst_offset + 3]) * inv + 127) / 255);
        }
    }
}

/// Conservative bound for stb's triangle-filter working buffers. In particular,
/// its vertical ring buffer grows with the downsampling ratio, not band height.
/// Keep calculations below its signed-int limits as well as our memory budget.
fn checkResizeScratch(rect: SourceRect, dest: Destination, width: u32, height: u32, channels: u32) !void {
    const ring_rows = (2 * @as(u64, rect.height) + dest.height - 1) / dest.height + 3;
    const ring_bytes = ring_rows * width * channels * @sizeOf(f32);
    // Covers contributor/coefficient arrays, the decode row (including filter
    // margins), horizontal work row, and encode row for the fixed triangle filter.
    const other_bytes = 128 * (@as(u64, rect.width) + rect.height + width + height);
    if (ring_bytes + other_bytes > max_scratch_bytes) return error.ImageTooLarge;
}

/// Bound individual scratch allocations independently of protocol image sizes.
pub fn byteLength(width: u32, height: u32) !usize {
    const bytes = try std.math.mul(usize, try std.math.mul(usize, width, height), 4);
    if (bytes > max_scratch_bytes) return error.ImageTooLarge;
    return bytes;
}

pub fn unpremultiply(pixels: []u8) void {
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        const a: u32 = pixels[i + 3];
        if (a == 0 or a == 255) continue;
        for (0..3) |c| pixels[i + c] = @intCast(@min(255, (@as(u32, pixels[i + c]) * 255 + a / 2) / a));
    }
}

pub fn cellVisible(pixels: []const u8, width: u32, height: u32, cell_width: u32, col: u32) bool {
    for (0..height) |y| {
        for (0..cell_width) |x| {
            if (pixels[(y * width + @as(usize, col) * cell_width + x) * 4 + 3] != 0) return true;
        }
    }
    return false;
}

const testing = std.testing;

test "source-over blends alpha and retains transparent padding" {
    var scratch: Scratch = .{};
    defer scratch.deinit(testing.allocator);
    var canvas: [12]u8 = @splat(0);
    const blue = [_]u8{ 0, 0, 255, 255 };
    const red = [_]u8{ 255, 0, 0, 128 };
    const rect: SourceRect = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    const dest: Destination = .{ .x = 1, .y = 0, .width = 1, .height = 1 };
    try draw(
        testing.allocator,
        &scratch,
        &canvas,
        3,
        1,
        .{ .data = &blue, .width = 1, .height = 1, .channels = 4 },
        rect,
        dest,
        null,
    );
    try draw(
        testing.allocator,
        &scratch,
        &canvas,
        3,
        1,
        .{ .data = &red, .width = 1, .height = 1, .channels = 4 },
        rect,
        dest,
        null,
    );
    try testing.expectEqualSlices(u8, &.{ 128, 0, 127, 255 }, canvas[4..8]);
    try testing.expect(!cellVisible(&canvas, 3, 1, 1, 0));
    try testing.expect(cellVisible(&canvas, 3, 1, 1, 1));
    try testing.expect(!cellVisible(&canvas, 3, 1, 1, 2));
}

test "partial alpha survives composition and PNG encoding" {
    const png = @import("png.zig");
    var scratch: Scratch = .{};
    defer scratch.deinit(testing.allocator);
    const data = [_]u8{ 255, 0, 0, 1, 0, 255, 0, 128, 0, 0, 255, 254 };
    var canvas: [data.len]u8 = @splat(0);
    try draw(
        testing.allocator,
        &scratch,
        &canvas,
        3,
        1,
        .{ .data = &data, .width = 3, .height = 1, .channels = 4 },
        .{ .x = 0, .y = 0, .width = 3, .height = 1 },
        .{ .x = 0, .y = 0, .width = 3, .height = 1 },
        null,
    );
    unpremultiply(&canvas);
    const encoded = try png.encode(testing.allocator, &canvas, 3, 1, 12);
    defer testing.allocator.free(encoded);
    const decoded = try png.decode(testing.allocator, encoded);
    defer testing.allocator.free(decoded.data);
    try testing.expectEqualSlices(u8, &data, decoded.data);
}

test "cropping and clipping preserve source offsets" {
    var scratch: Scratch = .{};
    defer scratch.deinit(testing.allocator);
    const data = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255 };
    var canvas: [4]u8 = @splat(0);
    try draw(
        testing.allocator,
        &scratch,
        &canvas,
        1,
        1,
        .{ .data = &data, .width = 3, .height = 1, .channels = 3 },
        .{ .x = 1, .y = 0, .width = 2, .height = 1 },
        .{ .x = -1, .y = 0, .width = 2, .height = 1 },
        null,
    );
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, &canvas);
}

test "band sampling matches a full placement without seams" {
    var scratch: Scratch = .{};
    defer scratch.deinit(testing.allocator);
    const data = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 255, 255, 255, 0 };
    var cropped: [20 * 28 * 4]u8 = undefined;
    for (0..28) |y| {
        for (0..20) |x| {
            cropped[(y * 20 + x) * 4 ..][0..4].* = .{
                @intCast((x * 17 + y * 13) % 256),
                @intCast((x * 31 + y * 7) % 256),
                @intCast((x * 11 + y * 37) % 256),
                @intCast(1 + (x * 19 + y * 23) % 255),
            };
        }
    }
    const cases = [_]struct { source: Source, rect: SourceRect }{
        .{
            .source = .{ .data = &data, .width = 2, .height = 2, .channels = 4 },
            .rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        },
        .{
            .source = .{ .data = &cropped, .width = 20, .height = 28, .channels = 4 },
            .rect = .{ .x = 2, .y = 3, .width = 16, .height = 24 },
        },
    };
    for (cases) |case| {
        var full: [6 * 8 * 4]u8 = @splat(0);
        try draw(testing.allocator, &scratch, &full, 6, 8, case.source, case.rect, .{ .x = 0, .y = 0, .width = 6, .height = 8 }, null);
        var band: [6 * 2 * 4]u8 = @splat(0);
        for (0..4) |i| {
            @memset(&band, 0);
            try draw(
                testing.allocator,
                &scratch,
                &band,
                6,
                2,
                case.source,
                case.rect,
                .{ .x = 0, .y = -@as(i64, @intCast(i * 2)), .width = 6, .height = 8 },
                null,
            );
            for (band, full[i * band.len ..][0..band.len]) |actual, expected|
                try testing.expect(@abs(@as(i16, actual) - expected) <= 1);
        }
    }
}

test "transparent source colors do not bleed into scaled edges" {
    var scratch: Scratch = .{};
    defer scratch.deinit(testing.allocator);
    const data = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 0 };
    var canvas: [16]u8 = @splat(0);
    try draw(
        testing.allocator,
        &scratch,
        &canvas,
        4,
        1,
        .{ .data = &data, .width = 2, .height = 1, .channels = 4 },
        .{ .x = 0, .y = 0, .width = 2, .height = 1 },
        .{ .x = 0, .y = 0, .width = 4, .height = 1 },
        null,
    );
    for (0..4) |i| try testing.expectEqual(@as(u8, 0), canvas[i * 4 + 1]);
    unpremultiply(&canvas);
    try testing.expectEqual(@as(u8, 255), canvas[0]);
}

test "resizing reuses sampled pixels and stb working memory after warmup" {
    var scratch: Scratch = .{};
    defer scratch.deinit(testing.allocator);
    const data = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 255, 255, 255, 0 };
    const source: Source = .{ .data = &data, .width = 2, .height = 2, .channels = 4 };
    const rect: SourceRect = .{ .x = 0, .y = 0, .width = 2, .height = 2 };
    const cases = [_]Destination{
        .{ .x = 0, .y = 0, .width = 64, .height = 8 },
        .{ .x = -3, .y = -1, .width = 32, .height = 4 },
        .{ .x = 0, .y = 0, .width = 64, .height = 1 },
        .{ .x = 0, .y = 0, .width = 1, .height = 8 },
    };
    var expected: [cases.len][64 * 8 * 4]u8 = undefined;
    for (cases, &expected) |dest, *canvas| {
        @memset(canvas, 0);
        try draw(testing.allocator, &scratch, canvas, 64, 8, source, rect, dest, null);
    }
    try testing.expect(scratch.sampled.capacity > 0);
    try testing.expect(scratch.working.capacity > 0);
    var rejecting = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    for (cases, expected) |dest, pixels| {
        var canvas: [64 * 8 * 4]u8 = @splat(0);
        try draw(rejecting.allocator(), &scratch, &canvas, 64, 8, source, rect, dest, null);
        try testing.expectEqualSlices(u8, &pixels, &canvas);
    }
    try testing.expect(!rejecting.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), rejecting.allocations);
    try testing.expectEqual(@as(usize, 0), rejecting.resize_index);
}

test "sample and stb scratch allocation failures propagate and allow reuse" {
    const data = [_]u8{ 255, 0, 0, 255 };
    const source: Source = .{ .data = &data, .width = 1, .height = 1, .channels = 4 };
    const rect: SourceRect = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    const dest: Destination = .{ .x = 0, .y = 0, .width = 8, .height = 1 };
    for (0..2) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const alloc = failing.allocator();
        var scratch: Scratch = .{};
        defer scratch.deinit(alloc);
        var canvas: [8 * 4]u8 = @splat(7);
        try testing.expectError(error.OutOfMemory, draw(alloc, &scratch, &canvas, 8, 1, source, rect, dest, null));
        try testing.expect(failing.has_induced_failure);
        try testing.expectEqualSlices(u8, &@as([8 * 4]u8, @splat(7)), &canvas);

        failing.fail_index = std.math.maxInt(usize);
        try draw(alloc, &scratch, &canvas, 8, 1, source, rect, dest, null);
        for (0..8) |pixel| try testing.expectEqualSlices(u8, &data, canvas[pixel * 4 ..][0..4]);
    }
}

test "stb working memory rejects an over-budget request without allocating" {
    var rejecting = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var scratch: Scratch = .{};
    defer scratch.deinit(testing.allocator);
    var context: ResizeContext = .{ .scratch = &scratch, .alloc = rejecting.allocator() };
    try testing.expect(ResizeContext.acquire(&context, max_scratch_bytes + 1) == null);
    try testing.expectEqual(error.ImageTooLarge, context.failure.?);
    try testing.expect(!rejecting.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), scratch.working.capacity);
}

test "extreme vertical downsampling is bounded before invoking stb" {
    try testing.expectError(error.ImageTooLarge, checkResizeScratch(
        .{ .x = 0, .y = 0, .width = 1, .height = 10000 },
        .{ .x = 0, .y = 0, .width = 800, .height = 1 },
        800,
        1,
        4,
    ));
}

test "oversized canvases fail before allocation" {
    try testing.expectError(error.ImageTooLarge, byteLength(std.math.maxInt(u32), 2));
}
