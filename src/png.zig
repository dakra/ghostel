/// PNG decode via vendored stb_image, in a Zig-allocator-friendly form,
/// and an uncompressed PNG encoder for images with transparency.
///
/// Self-contained so the decode logic can be unit-tested without
/// libghostty's allocator interface.  `sys.zig` wraps this for the
/// libghostty `decode_png` callback contract.
const std = @import("std");
const gt = @import("ghostty-vt");
const stb = @import("stb_image_c");
const ppm = @import("ppm.zig");

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

/// Whether the RECT sub-rectangle of WIDTH x HEIGHT pixel data with
/// CHANNELS channels has a pixel that is not fully opaque.  Only 2
/// (gray+alpha) and 4 (RGBA) carry alpha; an invalid RECT reports false.
pub fn hasTransparency(data: []const u8, width: u32, height: u32, channels: u32, rect: ppm.Rect) bool {
    if (channels != 2 and channels != 4) return false;
    if (!ppm.validRect(data, width, height, channels, rect)) return false;
    const stride: usize = @intCast(width);
    const ch: usize = @intCast(channels);
    const x0: usize = rect.x;
    const y0: usize = rect.y;
    const w: usize = rect.width;
    for (y0..y0 + rect.height) |row| {
        var off = (row * stride + x0) * ch + ch - 1;
        for (0..w) |_| {
            if (data[off] != 0xFF) return true;
            off += ch;
        }
    }
    return false;
}

/// Encode the RECT sub-rectangle of WIDTH x HEIGHT gray+alpha (CHANNELS
/// 2) or RGBA (CHANNELS 4) pixel data as an 8-bit RGBA PNG.
///
/// PPM has no alpha, so `ppm.createPpm` turns transparent pixels black;
/// this keeps them, and Emacs draws the face background through.  The
/// zlib stream uses stored (uncompressed) deflate blocks: the bytes are
/// handed straight to Emacs, so compressing them would only cost time.
///
/// Returns null for another channel count or an invalid RECT.  The
/// result is owned by ALLOCATOR.
pub fn encode(
    allocator: std.mem.Allocator,
    data: []const u8,
    width: u32,
    height: u32,
    channels: u32,
    rect: ppm.Rect,
) ?[]u8 {
    if (channels != 2 and channels != 4) return null;
    if (!ppm.validRect(data, width, height, channels, rect)) return null;
    const stride: usize = @intCast(width);
    const ch: usize = @intCast(channels);
    const w: usize = @intCast(rect.width);
    const h: usize = @intCast(rect.height);
    const x0: usize = rect.x;
    const y0: usize = rect.y;

    // Scanlines: a filter byte (0, none) then w RGBA pixels.
    const row_bytes = std.math.mul(usize, w, 4) catch return null;
    const line = std.math.add(usize, row_bytes, 1) catch return null;
    const raw_len = std.math.mul(usize, line, h) catch return null;
    const raw = allocator.alloc(u8, raw_len) catch return null;
    defer allocator.free(raw);
    var o: usize = 0;
    for (y0..y0 + h) |row| {
        raw[o] = 0;
        o += 1;
        var src = (row * stride + x0) * ch;
        for (0..w) |_| {
            if (ch == 4) {
                @memcpy(raw[o .. o + 4], data[src .. src + 4]);
            } else {
                @memset(raw[o .. o + 3], data[src]);
                raw[o + 3] = data[src + 1];
            }
            o += 4;
            src += ch;
        }
    }

    const max_block: usize = 0xFFFF;
    const blocks = (raw_len + max_block - 1) / max_block;
    // zlib header (2) + per-block header (5) + data + Adler-32 (4).
    const idat_len = std.math.add(usize, raw_len, 2 + 5 * blocks + 4) catch return null;
    const idat_len32 = std.math.cast(u32, idat_len) orelse return null;
    // Signature, IHDR, IDAT and IEND: each chunk adds 12 bytes.
    const total = std.math.add(usize, idat_len, 8 + (12 + 13) + 12 + 12) catch return null;
    const out = allocator.alloc(u8, total) catch return null;

    var p: usize = 0;
    @memcpy(out[0..8], "\x89PNG\r\n\x1a\n");
    p = 8;

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], rect.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], rect.height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: RGBA
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // no interlace
    p = writeChunk(out, p, "IHDR", &ihdr);

    std.mem.writeInt(u32, out[p..][0..4], idat_len32, .big);
    const idat_start = p + 4;
    @memcpy(out[idat_start .. idat_start + 4], "IDAT");
    p = idat_start + 4;
    out[p] = 0x78; // deflate, 32K window
    out[p + 1] = 0x01; // no dictionary, fastest; (0x7801 % 31 == 0)
    p += 2;
    var left = raw_len;
    var r: usize = 0;
    while (left > 0) {
        const n = @min(left, max_block);
        out[p] = if (n == left) 1 else 0; // BFINAL, BTYPE=00 (stored)
        std.mem.writeInt(u16, out[p + 1 ..][0..2], @intCast(n), .little);
        std.mem.writeInt(u16, out[p + 3 ..][0..2], ~@as(u16, @intCast(n)), .little);
        p += 5;
        @memcpy(out[p .. p + n], raw[r .. r + n]);
        p += n;
        r += n;
        left -= n;
    }
    std.mem.writeInt(u32, out[p..][0..4], std.hash.Adler32.hash(raw), .big);
    p += 4;
    std.mem.writeInt(u32, out[p..][0..4], std.hash.Crc32.hash(out[idat_start..p]), .big);
    p += 4;

    p = writeChunk(out, p, "IEND", "");
    std.debug.assert(p == total);
    return out;
}

/// Write one PNG chunk (length, TYPE, BODY, CRC) at OUT[P..]; returns
/// the offset just past it.
fn writeChunk(out: []u8, p: usize, comptime kind: *const [4]u8, body: []const u8) usize {
    std.mem.writeInt(u32, out[p..][0..4], @intCast(body.len), .big);
    const start = p + 4;
    @memcpy(out[start .. start + 4], kind);
    @memcpy(out[start + 4 .. start + 4 + body.len], body);
    const end = start + 4 + body.len;
    std.mem.writeInt(u32, out[end..][0..4], std.hash.Crc32.hash(out[start..end]), .big);
    return end + 4;
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

test "encode: RGBA roundtrips through decode, alpha kept" {
    const px = [_]u8{
        0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x80,
        0x00, 0xFF, 0x00, 0x00, 0x10, 0x20, 0x30, 0xFF,
    };
    const out = encode(testing.allocator, &px, 2, 2, 4, ppm.Rect.full(2, 2)) orelse return error.EncodeFailed;
    defer testing.allocator.free(out);
    const back = try decode(testing.allocator, out);
    defer testing.allocator.free(back.data);
    try testing.expectEqual(@as(u32, 2), back.width);
    try testing.expectEqualSlices(u8, &px, back.data);
}

test "encode: gray+alpha expands to RGBA" {
    const px = [_]u8{ 0x40, 0x00, 0xC0, 0xFF };
    const out = encode(testing.allocator, &px, 2, 1, 2, ppm.Rect.full(2, 1)) orelse return error.EncodeFailed;
    defer testing.allocator.free(out);
    const back = try decode(testing.allocator, out);
    defer testing.allocator.free(back.data);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x40, 0x40, 0x00, 0xC0, 0xC0, 0xC0, 0xFF }, back.data);
}

test "encode: sub-rectangle and multi-block stored deflate" {
    // 200x100 RGBA = 80,000 raw bytes + filter bytes: two stored blocks.
    const w = 200;
    const h = 100;
    const px = try testing.allocator.alloc(u8, w * h * 4);
    defer testing.allocator.free(px);
    for (px, 0..) |*b, i| b.* = @truncate(i *% 7);
    const rect: ppm.Rect = .{ .x = 10, .y = 5, .width = 190, .height = 90 };
    const out = encode(testing.allocator, px, w, h, 4, rect) orelse return error.EncodeFailed;
    defer testing.allocator.free(out);
    const back = try decode(testing.allocator, out);
    defer testing.allocator.free(back.data);
    try testing.expectEqual(@as(u32, 190), back.width);
    try testing.expectEqual(@as(u32, 90), back.height);
    const src_off = (5 * w + 10) * 4;
    try testing.expectEqualSlices(u8, px[src_off .. src_off + 190 * 4], back.data[0 .. 190 * 4]);
}

test "encode: rejects RGB and an out-of-bounds rect" {
    const px = [_]u8{ 1, 2, 3, 4 };
    try testing.expect(encode(testing.allocator, &px, 1, 1, 3, ppm.Rect.full(1, 1)) == null);
    try testing.expect(encode(testing.allocator, &px, 1, 1, 4, ppm.Rect.full(2, 1)) == null);
}

test "hasTransparency: only for non-opaque alpha" {
    const opaque_px = [_]u8{ 1, 2, 3, 0xFF, 4, 5, 6, 0xFF };
    const clear_px = [_]u8{ 1, 2, 3, 0xFF, 4, 5, 6, 0x00 };
    try testing.expect(!hasTransparency(&opaque_px, 2, 1, 4, ppm.Rect.full(2, 1)));
    try testing.expect(hasTransparency(&clear_px, 2, 1, 4, ppm.Rect.full(2, 1)));
    try testing.expect(!hasTransparency(&clear_px, 2, 1, 4, .{ .x = 0, .y = 0, .width = 1, .height = 1 }));
    try testing.expect(!hasTransparency(opaque_px[0..3], 1, 1, 3, ppm.Rect.full(1, 1)));
}
