const gt = @import("ghostty-vt");

const emacs = @import("emacs.zig");

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
