//! Opaque PPM encoding of already-composited, premultiplied RGBA rows.
const std = @import("std");
const pixels = @import("image_composition.zig");

pub fn encode(alloc: std.mem.Allocator, rgba: []const u8, width: u32, height: u32, background: [3]u8) ![]u8 {
    if (width == 0 or height == 0) return error.InvalidImage;
    const needed = try pixels.byteLength(width, height);
    if (rgba.len < needed) return error.InvalidImage;
    var header_buf: [32]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height });
    const result = try alloc.alloc(u8, try std.math.add(usize, header.len, needed / 4 * 3));
    @memcpy(result[0..header.len], header);
    for (0..needed / 4) |i| {
        const inv: u32 = 255 - @as(u32, rgba[i * 4 + 3]);
        for (background, 0..) |bg, c| {
            result[header.len + i * 3 + c] = @intCast(@min(255, @as(u32, rgba[i * 4 + c]) + (@as(u32, bg) * inv + 127) / 255));
        }
    }
    return result;
}

test "PPM flattens premultiplied alpha without changing the source" {
    const rgba = [_]u8{ 0, 0, 0, 0, 128, 0, 0, 128, 1, 2, 3, 255 };
    const result = try encode(std.testing.allocator, &rgba, 3, 1, .{ 20, 40, 60 });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("P6\n3 1\n255\n" ++ "\x14\x28\x3c\x8a\x14\x1e\x01\x02\x03", result);
}

test "PPM rejects invalid or excessive canvas dimensions" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidImage, encode(alloc, &.{}, 0, 1, .{ 0, 0, 0 }));
    try std.testing.expectError(error.InvalidImage, encode(alloc, &.{0}, 1, 1, .{ 0, 0, 0 }));
    try std.testing.expectError(error.ImageTooLarge, encode(alloc, &.{}, 100_000, 100_000, .{ 0, 0, 0 }));
}

test "PPM propagates output allocation failure" {
    const Case = struct {
        fn run(alloc: std.mem.Allocator) !void {
            const result = try encode(alloc, &.{ 255, 0, 0, 255 }, 1, 1, .{ 0, 0, 0 });
            defer alloc.free(result);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
