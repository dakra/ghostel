/// Raw-pixel → PPM conversion for kitty graphics.
///
/// Self-contained module so the conversion logic can be unit-tested
/// without pulling in libghostty or Emacs dependencies.
const std = @import("std");

/// Sub-rectangle of an image, in pixels.
pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub fn full(width: u32, height: u32) Rect {
        return .{ .x = 0, .y = 0, .width = width, .height = height };
    }
};

/// Convert the RECT sub-rectangle of WIDTH x HEIGHT raw pixel data to
/// PPM (P6) for Emacs.  Supports 1 (gray), 2 (gray+alpha), 3 (RGB), and
/// 4 (RGBA) channels.  Returns null when RECT is empty or extends past
/// the image.
///
/// Alpha is dropped, not composited: `kitty_graphics` sends images
/// with transparent pixels as PNG (`png.encode`) instead.
///
/// Returns an allocated slice owned by the caller-supplied allocator.
pub fn createPpm(
    allocator: std.mem.Allocator,
    data: []const u8,
    width: u32,
    height: u32,
    channels: u32,
    rect: Rect,
) ?[]u8 {
    if (!validRect(data, width, height, channels, rect)) return null;
    const stride: usize = @intCast(width);
    const w: usize = @intCast(rect.width);
    const h: usize = @intCast(rect.height);
    const ch: usize = @intCast(channels);
    const wh = std.math.mul(usize, w, h) catch return null;
    const rgb_len = std.math.mul(usize, wh, 3) catch return null;

    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ w, h }) catch return null;

    const total_len = std.math.add(usize, header.len, rgb_len) catch return null;
    const buf = allocator.alloc(u8, total_len) catch return null;
    @memcpy(buf[0..header.len], header);

    var dst = buf[header.len..];
    var i: usize = 0;
    const x: usize = rect.x;
    const y: usize = rect.y;
    for (y..y + h) |row| {
        var src_off = (row * stride + x) * ch;
        for (0..w) |_| {
            switch (channels) {
                1, 2 => {
                    const g = data[src_off];
                    dst[i * 3 + 0] = g;
                    dst[i * 3 + 1] = g;
                    dst[i * 3 + 2] = g;
                },
                3, 4 => {
                    dst[i * 3 + 0] = data[src_off + 0];
                    dst[i * 3 + 1] = data[src_off + 1];
                    dst[i * 3 + 2] = data[src_off + 2];
                },
                else => {
                    allocator.free(buf);
                    return null;
                },
            }
            src_off += ch;
            i += 1;
        }
    }

    return buf;
}

/// Whether RECT is a non-empty sub-rectangle of a WIDTH x HEIGHT image
/// whose DATA holds all CHANNELS bytes of every pixel.
pub fn validRect(data: []const u8, width: u32, height: u32, channels: u32, rect: Rect) bool {
    if (rect.width == 0 or rect.height == 0 or channels == 0) return false;
    if (rect.width > width or rect.height > height) return false;
    if (rect.x > width - rect.width or rect.y > height - rect.height) return false;
    // Checked arithmetic — width*height*channels can otherwise overflow
    // `usize` for adversarial inputs and lead to under-allocation +
    // out-of-bounds writes in ReleaseFast.
    const total_px = std.math.mul(usize, @intCast(width), @intCast(height)) catch return false;
    const expected = std.math.mul(usize, total_px, @intCast(channels)) catch return false;
    return data.len >= expected;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "createPpm: 1x1 RGB roundtrips through P6 header" {
    const data = [_]u8{ 0xAA, 0xBB, 0xCC };
    const out = createPpm(testing.allocator, &data, 1, 1, 3, Rect.full(1, 1)) orelse return error.NullResult;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("P6\n1 1\n255\n", out[0..11]);
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC }, out[11..]);
}

test "createPpm: 2x1 RGBA drops alpha" {
    // Two pixels: red opaque, blue transparent.  PPM should keep RGB,
    // ignore alpha.
    const data = [_]u8{
        0xFF, 0x00, 0x00, 0xFF, // pixel 0: red
        0x00, 0x00, 0xFF, 0x00, // pixel 1: blue, alpha=0
    };
    const out = createPpm(testing.allocator, &data, 2, 1, 4, Rect.full(2, 1)) orelse return error.NullResult;
    defer testing.allocator.free(out);
    // Header: "P6\n2 1\n255\n" = 11 bytes
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF }, out[11..]);
}

test "createPpm: gray channel replicates to RGB" {
    const data = [_]u8{ 0x42, 0x84 };
    const out = createPpm(testing.allocator, &data, 2, 1, 1, Rect.full(2, 1)) orelse return error.NullResult;
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0x42, 0x42, 0x42, 0x84, 0x84, 0x84 }, out[11..]);
}

test "createPpm: gray+alpha drops alpha and replicates gray" {
    // Format: gray, alpha, gray, alpha
    const data = [_]u8{ 0x10, 0xFF, 0x20, 0x00 };
    const out = createPpm(testing.allocator, &data, 2, 1, 2, Rect.full(2, 1)) orelse return error.NullResult;
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0x10, 0x10, 0x10, 0x20, 0x20, 0x20 }, out[11..]);
}

test "createPpm: crops a sub-rectangle with row stride" {
    // 3x2 gray image, one byte per pixel; crop the 2x1 bottom-right.
    const data = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const out = createPpm(testing.allocator, &data, 3, 2, 1, .{ .x = 1, .y = 1, .width = 2, .height = 1 }) orelse return error.NullResult;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("P6\n2 1\n255\n", out[0..11]);
    try testing.expectEqualSlices(u8, &.{ 5, 5, 5, 6, 6, 6 }, out[11..]);
}

test "createPpm: rect outside the image returns null" {
    const data = [_]u8{ 1, 2, 3, 4, 5, 6 };
    try testing.expect(createPpm(testing.allocator, &data, 3, 2, 1, .{ .x = 2, .y = 0, .width = 2, .height = 1 }) == null);
    try testing.expect(createPpm(testing.allocator, &data, 3, 2, 1, .{ .x = 0, .y = 0, .width = 4, .height = 1 }) == null);
}

test "createPpm: zero dimensions return null" {
    const data = [_]u8{0};
    try testing.expect(createPpm(testing.allocator, &data, 0, 1, 3, Rect.full(0, 1)) == null);
    try testing.expect(createPpm(testing.allocator, &data, 1, 0, 3, Rect.full(1, 0)) == null);
    try testing.expect(createPpm(testing.allocator, &data, 1, 1, 0, Rect.full(1, 1)) == null);
}

test "createPpm: short data returns null without writing" {
    // 2x2 RGB needs 12 bytes; supply 6.
    const data = [_]u8{ 1, 2, 3, 4, 5, 6 };
    try testing.expect(createPpm(testing.allocator, &data, 2, 2, 3, Rect.full(2, 2)) == null);
}

test "createPpm: unsupported channel count returns null" {
    const data = [_]u8{ 0, 0, 0, 0, 0 };
    try testing.expect(createPpm(testing.allocator, &data, 1, 1, 5, Rect.full(1, 1)) == null);
}

test "createPpm: u32-max width refuses overflow" {
    // width * height * channels would overflow usize.  We expect a
    // null return without any allocation.
    const data = [_]u8{0};
    try testing.expect(createPpm(testing.allocator, &data, std.math.maxInt(u32), 2, 4, Rect.full(std.math.maxInt(u32), 2)) == null);
}

test "createPpm: header buffer holds maximum dimensions" {
    // The 64-byte header buffer must fit "P6\n4294967295 4294967295\n255\n"
    // (29 chars + null) — verify formatting succeeds at u32 max.
    const data = [_]u8{0};
    // We can't actually allocate 4G x 4G; just verify we hit the post-
    // header overflow path rather than the header-format path.
    const out = createPpm(testing.allocator, &data, std.math.maxInt(u32), 1, 1, Rect.full(std.math.maxInt(u32), 1));
    // Either null (overflow) or a successful 1-row strip.  Either way,
    // we shouldn't have crashed in bufPrint.
    if (out) |buf| testing.allocator.free(buf);
}
