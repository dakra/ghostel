/// Key input encoding using GhosttyKeyEncoder.
///
/// Translates Emacs key events into terminal escape sequences
/// using libghostty-vt's key encoder, which respects terminal modes
/// (application cursor keys, Kitty keyboard protocol, etc.).
const std = @import("std");
const gt = @import("ghostty.zig");
const emacs = @import("emacs.zig");
const Terminal = @import("terminal.zig");

const Key = gt.c.GhosttyKey;
const Mods = gt.c.GhosttyMods;

/// Encode a key event and send the result to the PTY via Elisp callback.
/// Returns true if bytes were sent, false if the key produces no output (not an error).
pub fn encodeAndSend(env: emacs.Env, term: *Terminal, key: Key, mods: Mods, utf8: ?[]const u8) !bool {
    // Sync encoder options from terminal state (cursor key mode, kitty flags, etc.)
    gt.c.ghostty_key_encoder_setopt_from_terminal(term.key_encoder, term.terminal);

    // Create key event
    var event: gt.c.GhosttyKeyEvent = undefined;
    try gt.toError(gt.c.ghostty_key_event_new(null, &event));
    defer gt.c.ghostty_key_event_free(event);

    gt.c.ghostty_key_event_set_action(event, gt.c.GHOSTTY_KEY_ACTION_PRESS);
    gt.c.ghostty_key_event_set_key(event, key);
    gt.c.ghostty_key_event_set_mods(event, mods);

    if (utf8) |text| {
        gt.c.ghostty_key_event_set_utf8(event, text.ptr, text.len);
    }

    // Encode
    var buf: [128]u8 = undefined;
    var written: usize = 0;
    try gt.toError(gt.c.ghostty_key_encoder_encode(
        term.key_encoder,
        event,
        &buf,
        buf.len,
        &written,
    ));

    if (written == 0) return false;

    // Send encoded bytes to the PTY via Elisp
    _ = env.f("ghostel--flush-output", .{buf[0..written]});

    return true;
}

/// Encode a mouse event and send the result to the PTY.
/// Returns true if bytes were sent, false if the event produces no output (not an error).
pub fn encodeAndSendMouse(env: emacs.Env, term: *Terminal, action: i64, button: i64, row: i64, col: i64, mods_val: i64) !bool {
    // Sync encoder options (tracking mode, format) from terminal
    gt.c.ghostty_mouse_encoder_setopt_from_terminal(term.mouse_encoder, term.terminal);

    // Set size: 1 pixel = 1 cell so Emacs cell coords map directly
    var size: gt.c.GhosttyMouseEncoderSize = .{
        .size = @sizeOf(gt.c.GhosttyMouseEncoderSize),
        .screen_width = term.renderer.size.cols,
        .screen_height = term.renderer.size.rows,
        .cell_width = 1,
        .cell_height = 1,
        .padding_top = 0,
        .padding_bottom = 0,
        .padding_right = 0,
        .padding_left = 0,
    };
    gt.c.ghostty_mouse_encoder_setopt(term.mouse_encoder, gt.c.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);

    // Create event
    var event: gt.c.GhosttyMouseEvent = undefined;
    try gt.toError(gt.c.ghostty_mouse_event_new(null, &event));
    defer gt.c.ghostty_mouse_event_free(event);

    gt.c.ghostty_mouse_event_set_action(event, @intCast(action));

    if (button > 0) {
        gt.c.ghostty_mouse_event_set_button(event, @intCast(button));
    } else {
        gt.c.ghostty_mouse_event_clear_button(event);
    }

    gt.c.ghostty_mouse_event_set_mods(event, @intCast(mods_val));
    gt.c.ghostty_mouse_event_set_position(event, .{
        .x = @floatFromInt(col),
        .y = @floatFromInt(row),
    });

    // Encode
    var buf: [128]u8 = undefined;
    var written: usize = 0;
    try gt.toError(gt.c.ghostty_mouse_encoder_encode(
        term.mouse_encoder,
        event,
        &buf,
        buf.len,
        &written,
    ));

    if (written == 0) return false;

    // Send to PTY
    _ = env.f("ghostel--flush-output", .{buf[0..written]});
    return true;
}

/// Map an Emacs key name to a GhosttyKey.
/// Returns GHOSTTY_KEY_UNIDENTIFIED for unknown keys.
pub fn mapKey(key_name: []const u8) Key {
    // Single character keys
    if (key_name.len == 1) {
        const ch = key_name[0];
        return switch (ch) {
            'a'...'z' => @intCast(@as(u32, gt.c.GHOSTTY_KEY_A) + (ch - 'a')),
            'A'...'Z' => @intCast(@as(u32, gt.c.GHOSTTY_KEY_A) + (ch - 'A')),
            '0'...'9' => @intCast(@as(u32, gt.c.GHOSTTY_KEY_DIGIT_0) + (ch - '0')),
            ' ' => gt.c.GHOSTTY_KEY_SPACE,
            '-' => gt.c.GHOSTTY_KEY_MINUS,
            '=' => gt.c.GHOSTTY_KEY_EQUAL,
            '[' => gt.c.GHOSTTY_KEY_BRACKET_LEFT,
            ']' => gt.c.GHOSTTY_KEY_BRACKET_RIGHT,
            '\\' => gt.c.GHOSTTY_KEY_BACKSLASH,
            ';' => gt.c.GHOSTTY_KEY_SEMICOLON,
            '\'' => gt.c.GHOSTTY_KEY_QUOTE,
            '`' => gt.c.GHOSTTY_KEY_BACKQUOTE,
            ',' => gt.c.GHOSTTY_KEY_COMMA,
            '.' => gt.c.GHOSTTY_KEY_PERIOD,
            '/' => gt.c.GHOSTTY_KEY_SLASH,
            else => gt.c.GHOSTTY_KEY_UNIDENTIFIED,
        };
    }

    // Named keys
    const eql = std.mem.eql;
    if (eql(u8, key_name, "return")) return gt.c.GHOSTTY_KEY_ENTER;
    if (eql(u8, key_name, "tab")) return gt.c.GHOSTTY_KEY_TAB;
    if (eql(u8, key_name, "backspace")) return gt.c.GHOSTTY_KEY_BACKSPACE;
    if (eql(u8, key_name, "escape")) return gt.c.GHOSTTY_KEY_ESCAPE;
    if (eql(u8, key_name, "delete")) return gt.c.GHOSTTY_KEY_DELETE;
    if (eql(u8, key_name, "insert")) return gt.c.GHOSTTY_KEY_INSERT;
    if (eql(u8, key_name, "home")) return gt.c.GHOSTTY_KEY_HOME;
    if (eql(u8, key_name, "end")) return gt.c.GHOSTTY_KEY_END;
    if (eql(u8, key_name, "prior")) return gt.c.GHOSTTY_KEY_PAGE_UP;
    if (eql(u8, key_name, "next")) return gt.c.GHOSTTY_KEY_PAGE_DOWN;
    if (eql(u8, key_name, "up")) return gt.c.GHOSTTY_KEY_ARROW_UP;
    if (eql(u8, key_name, "down")) return gt.c.GHOSTTY_KEY_ARROW_DOWN;
    if (eql(u8, key_name, "left")) return gt.c.GHOSTTY_KEY_ARROW_LEFT;
    if (eql(u8, key_name, "right")) return gt.c.GHOSTTY_KEY_ARROW_RIGHT;
    if (eql(u8, key_name, "f1")) return gt.c.GHOSTTY_KEY_F1;
    if (eql(u8, key_name, "f2")) return gt.c.GHOSTTY_KEY_F2;
    if (eql(u8, key_name, "f3")) return gt.c.GHOSTTY_KEY_F3;
    if (eql(u8, key_name, "f4")) return gt.c.GHOSTTY_KEY_F4;
    if (eql(u8, key_name, "f5")) return gt.c.GHOSTTY_KEY_F5;
    if (eql(u8, key_name, "f6")) return gt.c.GHOSTTY_KEY_F6;
    if (eql(u8, key_name, "f7")) return gt.c.GHOSTTY_KEY_F7;
    if (eql(u8, key_name, "f8")) return gt.c.GHOSTTY_KEY_F8;
    if (eql(u8, key_name, "f9")) return gt.c.GHOSTTY_KEY_F9;
    if (eql(u8, key_name, "f10")) return gt.c.GHOSTTY_KEY_F10;
    if (eql(u8, key_name, "f11")) return gt.c.GHOSTTY_KEY_F11;
    if (eql(u8, key_name, "f12")) return gt.c.GHOSTTY_KEY_F12;
    if (eql(u8, key_name, "space")) return gt.c.GHOSTTY_KEY_SPACE;

    return gt.c.GHOSTTY_KEY_UNIDENTIFIED;
}

/// Parse Emacs modifier flags from a modifier string.
/// The string format is comma-separated: "shift,ctrl,meta"
pub fn parseMods(mod_str: []const u8) Mods {
    var mods: Mods = 0;
    var iter = std.mem.splitSequence(u8, mod_str, ",");
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (std.mem.eql(u8, trimmed, "shift")) {
            mods |= gt.c.GHOSTTY_MODS_SHIFT;
        } else if (std.mem.eql(u8, trimmed, "ctrl") or std.mem.eql(u8, trimmed, "control")) {
            mods |= gt.c.GHOSTTY_MODS_CTRL;
        } else if (std.mem.eql(u8, trimmed, "meta") or std.mem.eql(u8, trimmed, "alt")) {
            mods |= gt.c.GHOSTTY_MODS_ALT;
        } else if (std.mem.eql(u8, trimmed, "super") or std.mem.eql(u8, trimmed, "hyper")) {
            mods |= gt.c.GHOSTTY_MODS_SUPER;
        }
    }
    return mods;
}
