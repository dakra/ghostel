/// Key input encoding using GhosttyKeyEncoder.
///
/// Translates Emacs key events into terminal escape sequences
/// using libghostty-vt's key encoder, which respects terminal modes
/// (application cursor keys, Kitty keyboard protocol, etc.).
const std = @import("std");
const gt = @import("ghostty-vt");
const emacs = @import("emacs.zig");
const GhostelTerm = @import("GhostelTerm.zig");

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
