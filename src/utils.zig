const gt = @import("ghostty-vt");

const emacs = @import("emacs.zig");

/// Mapping from terminal rows to the host buffer's lines.
///
/// Whole-buffer terminals render into the buffer from line 1, so the zero
/// defaults apply.  An embedded terminal owns a region further down the
/// host buffer, whose first row starts on line `row_base` (zero-based) at
/// buffer position `base_pos` (a line start).
pub const RowMap = struct {
    row_base: usize = 0,
    base_pos: usize = 1,
};

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

pub fn bufferPosToPin(screen: *gt.Screen, env: emacs.Env, pos: usize, map: RowMap) ?gt.Pin {
    const saved_point = env.f("point", .{});
    defer _ = env.f("goto-char", .{saved_point});

    _ = env.f("goto-char", .{pos});
    const line = env.cast(usize, env.f("line-number-at-pos", .{}));
    // Positions above the terminal's region do not correspond to any row.
    if (line <= map.row_base) return null;
    const row: u32 = @intCast(line - 1 - map.row_base);
    const row_pin = screen.pages.pin(.{ .screen = .{ .y = row } });
    if (row_pin == null) return null;

    const point = env.cast(usize, env.f("point", .{}));
    const row_start_pos = env.cast(usize, env.f("pos-bol", .{}));
    const char_offset = point - row_start_pos;

    return advanceByCharOffset(row_pin.?, char_offset);
}

pub fn pinToBufferPos(screen: *gt.Screen, env: emacs.Env, pin: gt.Pin, map: RowMap) ?usize {
    const saved_point = env.f("point", .{});
    defer _ = env.f("goto-char", .{saved_point});

    const opt_point = screen.pages.pointFromPin(.screen, pin);
    if (opt_point == null) return null;
    const point = opt_point.?.screen;
    _ = env.f("goto-char", .{map.base_pos});
    _ = env.f("forward-line", .{point.y});
    _ = env.f("goto-char", .{env.cast(usize, env.f("point", .{})) + rowCharOffset(pin)});
    return env.cast(usize, env.f("point", .{}));
}
