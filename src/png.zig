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
