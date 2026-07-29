/// Key input encoding using GhosttyKeyEncoder.
///
/// Translates Emacs key events into terminal escape sequences
/// using libghostty-vt's key encoder, which respects terminal modes
/// (application cursor keys, Kitty keyboard protocol, etc.).
const std = @import("std");
const gt = @import("ghostty-vt");

/// Map an Emacs key name to a GhosttyKey.
/// Returns GHOSTTY_KEY_UNIDENTIFIED for unknown keys.
pub fn mapKey(key_name: []const u8) gt.input.Key {
    // Single character keys
    if (key_name.len == 1) {
        const ch = key_name[0];
        return switch (ch) {
            'a'...'z' => @enumFromInt(@intFromEnum(gt.input.Key.key_a) + (ch - 'a')),
            'A'...'Z' => @enumFromInt(@intFromEnum(gt.input.Key.key_a) + (ch - 'A')),
            '0'...'9' => @enumFromInt(@intFromEnum(gt.input.Key.digit_0) + (ch - '0')),
            ' ' => gt.input.Key.space,
            '-' => gt.input.Key.minus,
            '=' => gt.input.Key.equal,
            '[' => gt.input.Key.bracket_left,
            ']' => gt.input.Key.bracket_right,
            '\\' => gt.input.Key.backslash,
            ';' => gt.input.Key.semicolon,
            '\'' => gt.input.Key.quote,
            '`' => gt.input.Key.backquote,
            ',' => gt.input.Key.comma,
            '.' => gt.input.Key.period,
            '/' => gt.input.Key.slash,
            else => gt.input.Key.unidentified,
        };
    }

    // Named keys
    const eql = std.mem.eql;
    if (eql(u8, key_name, "return")) return gt.input.Key.enter;
    if (eql(u8, key_name, "tab")) return gt.input.Key.tab;
    if (eql(u8, key_name, "backspace")) return gt.input.Key.backspace;
    if (eql(u8, key_name, "escape")) return gt.input.Key.escape;
    if (eql(u8, key_name, "delete")) return gt.input.Key.delete;
    if (eql(u8, key_name, "insert")) return gt.input.Key.insert;
    if (eql(u8, key_name, "home")) return gt.input.Key.home;
    if (eql(u8, key_name, "end")) return gt.input.Key.end;
    if (eql(u8, key_name, "prior")) return gt.input.Key.page_up;
    if (eql(u8, key_name, "next")) return gt.input.Key.page_down;
    if (eql(u8, key_name, "up")) return gt.input.Key.arrow_up;
    if (eql(u8, key_name, "down")) return gt.input.Key.arrow_down;
    if (eql(u8, key_name, "left")) return gt.input.Key.arrow_left;
    if (eql(u8, key_name, "right")) return gt.input.Key.arrow_right;
    if (eql(u8, key_name, "f1")) return gt.input.Key.f1;
    if (eql(u8, key_name, "f2")) return gt.input.Key.f2;
    if (eql(u8, key_name, "f3")) return gt.input.Key.f3;
    if (eql(u8, key_name, "f4")) return gt.input.Key.f4;
    if (eql(u8, key_name, "f5")) return gt.input.Key.f5;
    if (eql(u8, key_name, "f6")) return gt.input.Key.f6;
    if (eql(u8, key_name, "f7")) return gt.input.Key.f7;
    if (eql(u8, key_name, "f8")) return gt.input.Key.f8;
    if (eql(u8, key_name, "f9")) return gt.input.Key.f9;
    if (eql(u8, key_name, "f10")) return gt.input.Key.f10;
    if (eql(u8, key_name, "f11")) return gt.input.Key.f11;
    if (eql(u8, key_name, "f12")) return gt.input.Key.f12;
    if (eql(u8, key_name, "space")) return gt.input.Key.space;

    return gt.input.Key.unidentified;
}

/// Parse Emacs modifier flags from a modifier string.
/// The string format is comma-separated: "shift,ctrl,meta"
pub fn parseMods(mod_str: []const u8) gt.input.KeyMods {
    var mods: gt.input.KeyMods = .{};
    var iter = std.mem.splitSequence(u8, mod_str, ",");
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (std.mem.eql(u8, trimmed, "shift")) {
            mods.shift = true;
        } else if (std.mem.eql(u8, trimmed, "ctrl") or std.mem.eql(u8, trimmed, "control")) {
            mods.ctrl = true;
        } else if (std.mem.eql(u8, trimmed, "meta") or std.mem.eql(u8, trimmed, "alt")) {
            mods.alt = true;
        } else if (std.mem.eql(u8, trimmed, "super") or std.mem.eql(u8, trimmed, "hyper")) {
            mods.super = true;
        }
    }
    return mods;
}

/// Build a key event from an Emacs key name, modifier string, and
/// optional generated text.
///
/// Single printable-ASCII character keys carry their unshifted codepoint
/// and (unless UTF8 is given) the character as generated text; the
/// encoder needs both to produce CSI-u and alt-prefixed sequences.
/// Uppercase letters fold to the lowercase codepoint with shift added as
/// a consumed modifier.
pub fn keyEvent(key_name: []const u8, mod_str: []const u8, utf8: ?[]const u8) gt.input.KeyEvent {
    var event: gt.input.KeyEvent = .{
        .action = .press,
        .key = mapKey(key_name),
        .mods = parseMods(mod_str),
    };
    if (utf8) |text| event.utf8 = text;
    if (key_name.len == 1 and key_name[0] >= ' ' and key_name[0] <= '~') {
        const ch = key_name[0];
        if (std.ascii.isUpper(ch)) {
            event.mods.shift = true;
            event.consumed_mods.shift = true;
            event.unshifted_codepoint = std.ascii.toLower(ch);
        } else {
            event.unshifted_codepoint = ch;
        }
        if (event.utf8.len == 0) event.utf8 = key_name;
    }
    return event;
}

fn testEncode(buf: []u8, event: gt.input.KeyEvent, opts: gt.input.KeyEncodeOptions) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    try gt.input.encodeKey(&writer, event, opts);
    return writer.buffered();
}

const test_kitty_opts: gt.input.KeyEncodeOptions = .{
    .kitty_flags = .{ .disambiguate = true },
    .alt_esc_prefix = true,
    .macos_option_as_alt = .true,
};

const test_legacy_opts: gt.input.KeyEncodeOptions = .{
    .alt_esc_prefix = true,
    .macos_option_as_alt = .true,
};

test "kitty: modified character keys encode as CSI-u" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b[116;3u",
        try testEncode(&buf, keyEvent("t", "meta", null), test_kitty_opts),
    );
    try std.testing.expectEqualStrings(
        "\x1b[115;5u",
        try testEncode(&buf, keyEvent("s", "ctrl", null), test_kitty_opts),
    );
    try std.testing.expectEqualStrings(
        "\x1b[115;7u",
        try testEncode(&buf, keyEvent("s", "ctrl,meta", null), test_kitty_opts),
    );
    // Uppercase folds to the unshifted codepoint with shift reported.
    try std.testing.expectEqualStrings(
        "\x1b[116;4u",
        try testEncode(&buf, keyEvent("T", "meta", null), test_kitty_opts),
    );
    try std.testing.expectEqualStrings(
        "\x1b[116;6u",
        try testEncode(&buf, keyEvent("T", "shift,ctrl", null), test_kitty_opts),
    );
    // Unmapped punctuation uses the character itself as codepoint.
    try std.testing.expectEqualStrings(
        "\x1b[33;3u",
        try testEncode(&buf, keyEvent("!", "meta", null), test_kitty_opts),
    );
}

test "kitty: unmodified character keys stay plain text" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "t",
        try testEncode(&buf, keyEvent("t", "", null), test_kitty_opts),
    );
    try std.testing.expectEqualStrings(
        "T",
        try testEncode(&buf, keyEvent("T", "", null), test_kitty_opts),
    );
}

test "legacy: modified character keys keep legacy sequences" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1bt",
        try testEncode(&buf, keyEvent("t", "meta", null), test_legacy_opts),
    );
    try std.testing.expectEqualStrings(
        "\x1bT",
        try testEncode(&buf, keyEvent("T", "meta", null), test_legacy_opts),
    );
    try std.testing.expectEqualStrings(
        "\x13",
        try testEncode(&buf, keyEvent("s", "ctrl", null), test_legacy_opts),
    );
    // Ctrl+Meta keeps the meta bit as an ESC prefix on the C0 byte.
    try std.testing.expectEqualStrings(
        "\x1b\x13",
        try testEncode(&buf, keyEvent("s", "ctrl,meta", null), test_legacy_opts),
    );
    // Control punctuation resolves through the unshifted codepoint.
    try std.testing.expectEqualStrings(
        "\x00",
        try testEncode(&buf, keyEvent("@", "ctrl", null), test_legacy_opts),
    );
    // Fixterms: ctrl+i/m/[ encode as CSI-u to stay distinguishable from
    // tab/enter/escape.  `ghostel--send-event' maps the raw C0 bytes a
    // TTY delivers to the functional keys before they reach this path.
    try std.testing.expectEqualStrings(
        "\x1b[109;5u",
        try testEncode(&buf, keyEvent("m", "ctrl", null), test_legacy_opts),
    );
}
