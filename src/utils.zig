const std = @import("std");

const gt = @import("ghostty-vt");

const emacs = @import("emacs.zig");

pub fn parseHexByte(hi: u8, lo: u8) !u8 {
    const h = try hexDigit(hi);
    const l = try hexDigit(lo);
    return (h << 4) | l;
}

pub fn hexDigit(ch: u8) !u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return error.InvalidHexDigit;
}

/// Parse a "#RRGGBB" hex color string into a ColorRgb.
pub fn parseHexColor(s: []const u8) !gt.color.RGB {
    if (s.len < 7 or s[0] != '#') return error.InvalidHexColorLength;
    const r = try parseHexByte(s[1], s[2]);
    const g = try parseHexByte(s[3], s[4]);
    const b = try parseHexByte(s[5], s[6]);
    return .{ .r = r, .g = g, .b = b };
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
    const page = &pin.node.data;
    var char_count: usize = 0;
    var cells = pin.cells(.left);
    cells.len -= 1;
    for (cells) |*cell| char_count += cellCharCount(page, cell);
    return char_count;
}

pub fn advanceByCharOffset(pin: gt.Pin, offset: usize) ?gt.Pin {
    var char_count: usize = 0;
    var it = pin.cellIterator(.right_down, null);
    while (it.next()) |p| {
        if (char_count >= offset) return p;
        char_count += cellCharCount(&p.node.data, p.rowAndCell().cell);
    }

    return null;
}

pub fn bufferPosToPin(screen: *gt.Screen, env: emacs.Env, pos: usize) ?gt.Pin {
    const saved_point = env.point();
    defer env.gotoChar(saved_point);

    env.gotoChar(pos);
    const row = env.cast(u32, env.f("line-number-at-pos", .{})) - 1;
    const row_pin = screen.pages.pin(.{ .screen = .{ .y = @intCast(row) } });
    if (row_pin == null) return null;

    const point = env.cast(usize, env.point());
    const row_start_pos = env.cast(usize, env.f("pos-bol", .{}));
    const char_offset = point - row_start_pos;

    return advanceByCharOffset(row_pin.?, char_offset);
}

pub fn pinToBufferPos(screen: *gt.Screen, env: emacs.Env, pin: gt.Pin) ?usize {
    const saved_point = env.point();
    defer env.gotoChar(saved_point);

    const opt_point = screen.pages.pointFromPin(.screen, pin);
    if (opt_point == null) return null;
    const point = opt_point.?.screen;
    _ = env.f("goto-char", .{1});
    _ = env.f("forward-line", .{point.y});
    _ = env.f("goto-char", .{env.cast(usize, env.point()) + rowCharOffset(pin)});
    return env.cast(usize, env.point());
}
