const std = @import("std");
const gt = @import("ghostty-vt");

const emacs = @import("emacs.zig");

/// Classify an OSC 11 default background using the convention from Neovim's
/// terminal background detection: ITU-R BT.601 luma split at the 0.5 midpoint.
/// https://github.com/neovim/neovim/blob/2fbc82820b5168b0da4e918c192c05832dfd6211/runtime/lua/vim/_core/defaults.lua
///
/// Ghostel has no separate light/dark appearance state. Instead, CSI 996/997
/// classifies the `ghostel-default` background most recently seeded by
/// `ghostel-sync-theme`. Theme changes trigger that sync automatically; direct
/// face changes require an explicit sync. An unset background is treated as dark
/// (libghostty's seed).
pub fn backgroundIsLight(rgb: ?gt.color.RGB) bool {
    const c = rgb orelse return false;
    const y = @as(u32, c.r) * 299 + @as(u32, c.g) * 587 + @as(u32, c.b) * 114;
    return y >= 127_500;
}

test backgroundIsLight {
    try std.testing.expect(!backgroundIsLight(null));
    try std.testing.expect(!backgroundIsLight(.{ .r = 127, .g = 127, .b = 127 }));
    try std.testing.expect(backgroundIsLight(.{ .r = 128, .g = 128, .b = 127 }));
}

pub fn cellCharCount(page: *gt.Page, cell: *gt.Cell) usize {
    if (cell.wide == .spacer_head or cell.wide == .spacer_tail) {
        return 0;
    }

    var count: usize = 1;
    if (cell.hasGrapheme()) {
        if (page.lookupGrapheme(cell)) |g| count += g.len;
    }
    return count;
}

pub fn rowCharOffset(pin: gt.Pin) usize {
    var char_count: usize = 0;
    var cells = pin.cells(.left);
    cells.len -= 1;
    for (cells) |*cell| char_count += cellCharCount(pin.node.page(), cell);
    return char_count;
}

pub fn advanceByCharOffset(pin: gt.Pin, offset: usize) ?gt.Pin {
    var char_count: usize = 0;
    var it = pin.cellIterator(.right_down, null);
    while (it.next()) |p| {
        if (char_count >= offset) return p;
        char_count += cellCharCount(p.node.page(), p.rowAndCell().cell);
    }

    return null;
}

pub fn bufferPosToPin(screen: *gt.Screen, env: emacs.Env, pos: usize) ?gt.Pin {
    const saved_point = env.f("point", .{});
    defer _ = env.f("goto-char", .{saved_point});

    _ = env.f("goto-char", .{pos});
    const row = env.cast(u32, env.f("line-number-at-pos", .{})) - 1;
    const row_pin = screen.pages.pin(.{ .screen = .{ .y = @intCast(row) } });
    if (row_pin == null) return null;

    const point = env.cast(usize, env.f("point", .{}));
    const row_start_pos = env.cast(usize, env.f("pos-bol", .{}));
    const char_offset = point - row_start_pos;

    return advanceByCharOffset(row_pin.?, char_offset);
}

pub fn pinToBufferPos(screen: *gt.Screen, env: emacs.Env, pin: gt.Pin) ?usize {
    const saved_point = env.f("point", .{});
    defer _ = env.f("goto-char", .{saved_point});

    const opt_point = screen.pages.pointFromPin(.screen, pin);
    if (opt_point == null) return null;
    const point = opt_point.?.screen;
    _ = env.f("goto-char", .{1});
    _ = env.f("forward-line", .{point.y});
    _ = env.f("goto-char", .{env.cast(usize, env.f("point", .{})) + rowCharOffset(pin)});
    return env.cast(usize, env.f("point", .{}));
}
