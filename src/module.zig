/// Ghostel — Emacs dynamic module entry point.
///
/// This is the top-level file compiled into ghostel-module.so/.dylib.
/// It exports emacs_module_init (the C entry point Emacs calls on load)
/// and registers all Elisp-callable functions.
const std = @import("std");
const emacs = @import("emacs.zig");
const Terminal = @import("terminal.zig");
const gt = @import("ghostty.zig");
const render = @import("render.zig");
const input = @import("input.zig");

const c = emacs.c;

/// Module version — keep in sync with ghostel.el and build.zig.zon.
const version = "0.4";

// ---------------------------------------------------------------------------
// Module entry point
// ---------------------------------------------------------------------------

/// Emacs calls this when loading the dynamic module.
export fn emacs_module_init(runtime: *c.struct_emacs_runtime) callconv(.c) c_int {
    if (runtime.size < @sizeOf(c.struct_emacs_runtime)) {
        return 1; // ABI mismatch
    }

    const raw_env = runtime.get_environment.?(runtime);
    const env = emacs.Env.init(raw_env);

    // Register functions
    env.bindFunction("ghostel--new", 2, 3, &fnNew, "Create a new ghostel terminal.\n\n(ghostel--new ROWS COLS &optional MAX-SCROLLBACK)");
    env.bindFunction("ghostel--write-input", 2, 2, &fnWriteInput, "Write raw bytes to the terminal.\n\n(ghostel--write-input TERM DATA)");
    env.bindFunction("ghostel--set-size", 3, 3, &fnSetSize, "Resize the terminal.\n\n(ghostel--set-size TERM ROWS COLS)");
    env.bindFunction("ghostel--get-title", 1, 1, &fnGetTitle, "Get the terminal title.\n\n(ghostel--get-title TERM)");
    env.bindFunction("ghostel--get-pwd", 1, 1, &fnGetPwd, "Get the terminal's working directory from OSC 7.\n\n(ghostel--get-pwd TERM)");
    env.bindFunction("ghostel--redraw", 1, 2, &fnRedraw, "Redraw the terminal into the current buffer.\n\n(ghostel--redraw TERM &optional FULL)");
    env.bindFunction("ghostel--scroll", 2, 2, &fnScroll, "Scroll the terminal viewport by DELTA lines.\n\n(ghostel--scroll TERM DELTA)");
    env.bindFunction("ghostel--scroll-top", 1, 1, &fnScrollTop, "Scroll the terminal viewport to the top of scrollback.\n\n(ghostel--scroll-top TERM)");
    env.bindFunction("ghostel--scroll-bottom", 1, 1, &fnScrollBottom, "Scroll the terminal viewport to the bottom.\n\n(ghostel--scroll-bottom TERM)");
    env.bindFunction("ghostel--encode-key", 3, 4, &fnEncodeKey, "Encode a key event using the terminal's key encoder.\n\n(ghostel--encode-key TERM KEY MODS &optional UTF8)");
    env.bindFunction("ghostel--mouse-event", 6, 6, &fnMouseEvent, "Send a mouse event to the terminal.\n\n(ghostel--mouse-event TERM ACTION BUTTON ROW COL MODS)");
    env.bindFunction("ghostel--focus-event", 2, 2, &fnFocusEvent, "Send a focus event to the terminal.\n\n(ghostel--focus-event TERM GAINED)");
    env.bindFunction("ghostel--set-palette", 2, 2, &fnSetPalette, "Set the ANSI color palette.\n\n(ghostel--set-palette TERM COLORS-STRING)");
    env.bindFunction("ghostel--set-default-colors", 3, 3, &fnSetDefaultColors, "Set default foreground and background colors.\n\n(ghostel--set-default-colors TERM FG-HEX BG-HEX)");
    env.bindFunction("ghostel--mode-enabled", 2, 2, &fnModeEnabled, "Return t if terminal DEC private MODE is enabled.\n\n(ghostel--mode-enabled TERM MODE)");
    env.bindFunction("ghostel--debug-state", 1, 1, &fnDebugState, "Return debug info about terminal/render state.\n\n(ghostel--debug-state TERM)");
    env.bindFunction("ghostel--debug-feed", 2, 2, &fnDebugFeed, "Feed STR to terminal and return first row + cursor.\n\n(ghostel--debug-feed TERM STR)");
    env.bindFunction("ghostel--module-version", 0, 0, &fnModuleVersion, "Return the native module version string.\n\n(ghostel--module-version)");

    emacs.initSymbols(env);
    env.provide("ghostel-module");
    return 0;
}

// ---------------------------------------------------------------------------
// Plugin version — required by Emacs >= 27
// ---------------------------------------------------------------------------

export const plugin_is_GPL_compatible: c_int = 0;

// ---------------------------------------------------------------------------
// Exported Elisp functions
// ---------------------------------------------------------------------------

/// (ghostel--new ROWS COLS &optional MAX-SCROLLBACK)
fn fnNew(raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const rows: u16 = @intCast(env.extractInteger(args[0]));
    const cols: u16 = @intCast(env.extractInteger(args[1]));
    const max_scrollback: usize = if (nargs > 2 and env.isNotNil(args[2]))
        @intCast(env.extractInteger(args[2]))
    else
        10000;

    const term = std.heap.c_allocator.create(Terminal) catch {
        env.signalError("ghostel: out of memory");
        return env.nil();
    };

    term.* = Terminal.init(cols, rows, max_scrollback) catch {
        std.heap.c_allocator.destroy(term);
        env.signalError("ghostel: failed to create terminal");
        return env.nil();
    };

    // Register callbacks — clean up on failure to avoid leaking the terminal.
    const setup_ok = blk: {
        term.setUserdata(term) catch break :blk false;
        term.setWritePty(&writePtyCallback) catch break :blk false;
        term.setBell(&bellCallback) catch break :blk false;
        term.setTitleChanged(&titleChangedCallback) catch break :blk false;
        term.setDeviceAttributes(&deviceAttributesCallback) catch break :blk false;
        break :blk true;
    };
    if (!setup_ok) {
        term.deinit();
        std.heap.c_allocator.destroy(term);
        env.signalError("ghostel: failed to configure terminal callbacks");
        return env.nil();
    }

    // Set default colors (light gray on black)
    const default_fg = gt.ColorRgb{ .r = 204, .g = 204, .b = 204 };
    const default_bg = gt.ColorRgb{ .r = 0, .g = 0, .b = 0 };
    term.setColorForeground(&default_fg) catch {};
    term.setColorBackground(&default_bg) catch {};

    return env.makeUserPtr(&Terminal.emacsFinalize, term);
}

/// (ghostel--write-input TERM DATA)
fn fnWriteInput(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse {
        env.signalError("ghostel: invalid terminal handle");
        return env.nil();
    };

    // Extract string data — try stack buffer first, fall back to alloc
    var stack_buf: [65536]u8 = undefined;
    var heap_buf: ?[]const u8 = null;
    defer if (heap_buf) |hb| std.heap.c_allocator.free(hb);

    const data = env.extractString(args[1], &stack_buf) orelse blk: {
        heap_buf = env.extractStringAlloc(args[1], std.heap.c_allocator);
        break :blk heap_buf;
    };

    if (data == null) {
        return env.nil();
    }

    // Stash env for callbacks
    term.env = env;
    defer term.env = null;

    // Normalize CRLF: Emacs PTYs lack ONLCR, so bare \n arrives
    // without \r.  Insert \r before every bare \n.
    // Done here in Zig to avoid Elisp unibyte→multibyte corruption.
    const raw = data.?;

    // Count bare \n to determine output size.
    var extra_cr: usize = 0;
    for (0..raw.len) |i| {
        if (raw[i] == '\n' and (i == 0 or raw[i - 1] != '\r')) {
            extra_cr += 1;
        }
    }

    if (extra_cr == 0) {
        // No normalization needed — feed raw data directly.
        term.vtWrite(raw);
    } else {
        // Need to insert \r before bare \n.
        const out_len = raw.len + extra_cr;
        var norm_stack: [131072]u8 = undefined;
        var norm_heap: ?[]u8 = null;
        defer if (norm_heap) |nh| std.heap.c_allocator.free(nh);

        const norm_buf: []u8 = if (out_len <= norm_stack.len)
            &norm_stack
        else blk: {
            norm_heap = std.heap.c_allocator.alloc(u8, out_len) catch {
                // Fall back to stack buffer, truncating if needed.
                break :blk &norm_stack;
            };
            break :blk norm_heap.?;
        };

        var npos: usize = 0;
        for (0..raw.len) |i| {
            if (raw[i] == '\n' and (i == 0 or raw[i - 1] != '\r')) {
                norm_buf[npos] = '\r';
                npos += 1;
            }
            norm_buf[npos] = raw[i];
            npos += 1;
        }
        term.vtWrite(norm_buf[0..npos]);
    }

    // Scan for OSC sequences that libghostty-vt discards.
    extractAndSetPwd(term, raw);
    extractOsc51(env, raw);
    extractOsc52(env, raw);
    extractOsc133(env, raw);

    return env.nil();
}

// ---------------------------------------------------------------------------
// OSC sequence helpers
// ---------------------------------------------------------------------------

/// Find the end of an OSC sequence payload starting at `start`.
/// Scans for the terminator: BEL (0x07) or ST (ESC \).
/// Returns the index of the first terminator byte, or data.len if none found.
fn findOscTerminator(data: []const u8, start: usize) usize {
    var pos = start;
    while (pos < data.len) {
        if (data[pos] == 0x07) return pos; // BEL
        if (data[pos] == 0x1b and pos + 1 < data.len and data[pos + 1] == '\\') return pos; // ST
        pos += 1;
    }
    return data.len;
}

/// Iterator-style scanner that yields successive OSC sequences matching `prefix`.
/// Each call to `next()` returns the payload slice (after the prefix, before the
/// terminator), or null when no more matches exist.
const OscScanner = struct {
    data: []const u8,
    prefix: []const u8,
    pos: usize = 0,

    const Match = struct {
        payload: []const u8,
        end: usize,
    };

    fn next(self: *OscScanner) ?Match {
        while (self.pos + self.prefix.len < self.data.len) {
            if (std.mem.startsWith(u8, self.data[self.pos..], self.prefix)) {
                const payload_start = self.pos + self.prefix.len;
                const payload_end = findOscTerminator(self.data, payload_start);
                self.pos = payload_end;
                return .{ .payload = self.data[payload_start..payload_end], .end = payload_end };
            } else {
                self.pos += 1;
            }
        }
        return null;
    }
};

/// Scan data for OSC 51;E elisp eval sequences.
/// OSC 51 format: ESC ] 51 ; E <quoted-args> (ST | BEL)
/// Passes the payload (after 'E') to ghostel--osc51-eval for dispatch.
fn extractOsc51(env: emacs.Env, data: []const u8) void {
    var scanner = OscScanner{ .data = data, .prefix = "\x1b]51;" };
    while (scanner.next()) |match| {
        const payload = match.payload;
        if (payload.len < 2) continue;
        // Sub-command must be 'E'
        if (payload[0] != 'E') continue;
        _ = env.call1(
            emacs.sym.@"ghostel--osc51-eval",
            env.makeString(payload[1..]),
        );
    }
}

/// Scan data for OSC 7 sequences and set the terminal PWD.
/// OSC 7 format: ESC ] 7 ; <url> (ST | BEL)
fn extractAndSetPwd(term: *Terminal, data: []const u8) void {
    var scanner = OscScanner{ .data = data, .prefix = "\x1b]7;" };
    while (scanner.next()) |match| {
        if (match.payload.len > 0) {
            const gs = gt.GhosttyString{ .ptr = match.payload.ptr, .len = match.payload.len };
            term.setPwd(&gs) catch {};
        }
    }
}

/// Scan data for OSC 52 clipboard sequences.
/// OSC 52 format: ESC ] 52 ; <selection> ; <base64-data> (ST | BEL)
/// Calls ghostel--osc52-handle with the selection and base64 data.
fn extractOsc52(env: emacs.Env, data: []const u8) void {
    var scanner = OscScanner{ .data = data, .prefix = "\x1b]52;" };
    while (scanner.next()) |match| {
        const payload = match.payload;
        // Find the ';' separating selection from data
        const semi = std.mem.indexOfScalar(u8, payload, ';') orelse continue;
        const selection = payload[0..semi];
        const b64 = payload[semi + 1 ..];
        if (b64.len == 0) continue;
        // Ignore clipboard queries ('?')
        if (b64.len == 1 and b64[0] == '?') continue;
        _ = env.call2(
            emacs.sym.@"ghostel--osc52-handle",
            env.makeString(selection),
            env.makeString(b64),
        );
    }
}

/// Scan data for OSC 133 semantic prompt markers.
/// OSC 133 format: ESC ] 133 ; <type> [; <param>] (ST | BEL)
/// type: A = prompt start, B = command start, C = output start, D = command finished
/// For type D, param is the exit status.
fn extractOsc133(env: emacs.Env, data: []const u8) void {
    var scanner = OscScanner{ .data = data, .prefix = "\x1b]133;" };
    while (scanner.next()) |match| {
        const payload = match.payload;
        if (payload.len == 0) continue;
        const marker_type = payload[0];

        // Only handle known types
        if (marker_type != 'A' and marker_type != 'B' and marker_type != 'C' and marker_type != 'D') continue;

        // Check for optional parameter after ';'
        const has_param = payload.len > 1 and payload[1] == ';';
        const param_data = if (has_param) payload[2..] else &[_]u8{};

        const type_str: [1]u8 = .{marker_type};
        const param_val = if (has_param and param_data.len > 0)
            env.makeString(param_data)
        else
            env.nil();

        _ = env.call2(
            emacs.sym.@"ghostel--osc133-marker",
            env.makeString(&type_str),
            param_val,
        );
    }
}

/// (ghostel--set-size TERM ROWS COLS)
fn fnSetSize(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse {
        env.signalError("ghostel: invalid terminal handle");
        return env.nil();
    };

    const rows: u16 = @intCast(env.extractInteger(args[1]));
    const cols: u16 = @intCast(env.extractInteger(args[2]));

    term.resize(cols, rows) catch {
        env.signalError("ghostel: resize failed");
        return env.nil();
    };

    return env.nil();
}

/// (ghostel--get-title TERM)
fn fnGetTitle(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();

    if (term.getTitle()) |title| {
        return env.makeString(title);
    }
    return env.nil();
}

/// (ghostel--get-pwd TERM)
fn fnGetPwd(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();

    if (term.getPwd()) |pwd| {
        return env.makeString(pwd);
    }
    return env.nil();
}

/// (ghostel--redraw TERM &optional FULL)
/// Reads the render state and updates the current Emacs buffer with styled text.
/// When FULL is non-nil, always perform a full redraw instead of incremental.
fn fnRedraw(raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();
    const force_full = nargs > 1 and env.isNotNil(args[1]);
    render.redraw(env, term, force_full);
    return env.nil();
}

/// (ghostel--scroll TERM DELTA)
fn fnScroll(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();

    const delta = env.extractInteger(args[1]);
    term.scrollViewport(gt.SCROLL_DELTA, @intCast(delta));

    return env.nil();
}

/// (ghostel--scroll-top TERM)
fn fnScrollTop(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();
    term.scrollViewport(gt.SCROLL_TOP, 0);
    return env.nil();
}

/// (ghostel--scroll-bottom TERM)
fn fnScrollBottom(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();
    term.scrollViewport(gt.SCROLL_BOTTOM, 0);
    return env.nil();
}

/// (ghostel--encode-key TERM KEY MODS &optional UTF8)
/// Encode a key event and send it to the PTY.
/// KEY is a key name string (e.g. "a", "return", "up", "f1").
/// MODS is a modifier string (e.g. "ctrl", "shift,ctrl", "").
/// UTF8 is optional text generated by the key (e.g. "a" for the 'a' key).
fn fnEncodeKey(raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();

    // Extract key name
    var key_buf: [64]u8 = undefined;
    const key_name = env.extractString(args[1], &key_buf) orelse return env.nil();

    // Extract modifiers
    var mod_buf: [64]u8 = undefined;
    const mod_str = env.extractString(args[2], &mod_buf) orelse "";

    // Extract optional UTF-8 text
    var utf8_buf: [32]u8 = undefined;
    const utf8: ?[]const u8 = if (nargs > 3 and env.isNotNil(args[3]))
        env.extractString(args[3], &utf8_buf)
    else
        null;

    const key = input.mapKey(key_name);
    const mods = input.parseMods(mod_str);

    if (input.encodeAndSend(env, term, key, mods, utf8)) {
        return env.t();
    }
    return env.nil();
}

/// (ghostel--mouse-event TERM ACTION BUTTON ROW COL MODS)
/// ACTION: 0=press, 1=release, 2=motion
/// BUTTON: 0=none, 1=left, 2=right, 3=middle
/// ROW, COL: 0-based cell coordinates
/// MODS: modifier bitmask
fn fnMouseEvent(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();

    const action = env.extractInteger(args[1]);
    const button = env.extractInteger(args[2]);
    const row = env.extractInteger(args[3]);
    const col = env.extractInteger(args[4]);
    const mods = env.extractInteger(args[5]);

    if (input.encodeAndSendMouse(env, term, action, button, row, col, mods)) {
        return env.t();
    }
    return env.nil();
}

/// (ghostel--focus-event TERM GAINED)
/// Encode a focus gained/lost event and send to the PTY.
/// Only sends if the terminal has enabled focus reporting (DEC mode 1004).
fn fnFocusEvent(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();

    // Only send focus events if the terminal has enabled mode 1004
    // Construct mode value manually: DEC private mode 1004 = value & 0x7FFF, ansi=false (bit 15=0)
    const focus_mode: gt.c.GhosttyMode = 1004;
    if (!term.isModeEnabled(focus_mode)) {
        return env.nil();
    }

    const gained = env.isNotNil(args[1]);
    const event: gt.c.GhosttyFocusEvent = if (gained) gt.c.GHOSTTY_FOCUS_GAINED else gt.c.GHOSTTY_FOCUS_LOST;

    var buf: [8]u8 = undefined;
    var written: usize = 0;
    if (gt.c.ghostty_focus_encode(event, &buf, buf.len, &written) != gt.SUCCESS or written == 0) {
        return env.nil();
    }

    // Stash env for the flush callback
    term.env = env;
    defer term.env = null;

    _ = env.call1(emacs.sym.@"ghostel--flush-output", env.makeString(buf[0..written]));
    return env.t();
}

/// (ghostel--mode-enabled TERM MODE)
/// Return t if terminal DEC private MODE is enabled, nil otherwise.
fn fnModeEnabled(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();
    const mode: gt.c.GhosttyMode = @intCast(env.extractInteger(args[1]));
    return if (term.isModeEnabled(mode)) env.t() else env.nil();
}

/// (ghostel--set-palette TERM COLORS-STRING)
/// Set the 16 ANSI colors from a concatenated hex string like "#000000#aa0000...".
/// The remaining 240 palette entries are taken from the terminal's current palette.
fn fnSetPalette(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse {
        env.signalError("ghostel: invalid terminal handle");
        return env.nil();
    };

    var str_buf: [2048]u8 = undefined;
    const colors_str = env.extractString(args[1], &str_buf) orelse {
        env.signalError("ghostel: invalid palette string");
        return env.nil();
    };

    // Get current palette as base (keeps entries 16-255)
    var palette: [256]gt.ColorRgb = undefined;
    if (!term.getColorPalette(&palette)) {
        env.signalError("ghostel: failed to get current palette");
        return env.nil();
    }

    // Parse "#RRGGBB" entries — 7 chars each
    var idx: usize = 0;
    var pos: usize = 0;
    while (idx < 16 and pos + 7 <= colors_str.len) {
        if (colors_str[pos] != '#') {
            pos += 1;
            continue;
        }
        const r = parseHexByte(colors_str[pos + 1], colors_str[pos + 2]) orelse {
            pos += 7;
            idx += 1;
            continue;
        };
        const g = parseHexByte(colors_str[pos + 3], colors_str[pos + 4]) orelse {
            pos += 7;
            idx += 1;
            continue;
        };
        const b = parseHexByte(colors_str[pos + 5], colors_str[pos + 6]) orelse {
            pos += 7;
            idx += 1;
            continue;
        };
        palette[idx] = .{ .r = r, .g = g, .b = b };
        idx += 1;
        pos += 7;
    }

    term.setColorPalette(&palette) catch {
        env.signalError("ghostel: failed to set color palette");
        return env.nil();
    };
    return env.t();
}

fn parseHexByte(hi: u8, lo: u8) ?u8 {
    const h = hexDigit(hi) orelse return null;
    const l = hexDigit(lo) orelse return null;
    return (h << 4) | l;
}

fn hexDigit(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

/// Parse a "#RRGGBB" hex color string into a ColorRgb.
fn parseHexColor(s: []const u8) ?gt.ColorRgb {
    if (s.len < 7 or s[0] != '#') return null;
    const r = parseHexByte(s[1], s[2]) orelse return null;
    const g = parseHexByte(s[3], s[4]) orelse return null;
    const b = parseHexByte(s[5], s[6]) orelse return null;
    return .{ .r = r, .g = g, .b = b };
}

/// (ghostel--set-default-colors TERM FG-HEX BG-HEX)
/// Set the terminal's default foreground and background colors from "#RRGGBB" strings.
fn fnSetDefaultColors(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse {
        env.signalError("ghostel: invalid terminal handle");
        return env.nil();
    };

    var fg_buf: [16]u8 = undefined;
    var bg_buf: [16]u8 = undefined;
    const fg_str = env.extractString(args[1], &fg_buf) orelse {
        env.signalError("ghostel: invalid foreground color");
        return env.nil();
    };
    const bg_str = env.extractString(args[2], &bg_buf) orelse {
        env.signalError("ghostel: invalid background color");
        return env.nil();
    };

    const fg = parseHexColor(fg_str) orelse {
        env.signalError("ghostel: cannot parse foreground color");
        return env.nil();
    };
    const bg = parseHexColor(bg_str) orelse {
        env.signalError("ghostel: cannot parse background color");
        return env.nil();
    };

    term.setColorForeground(&fg) catch {
        env.signalError("ghostel: failed to set foreground color");
        return env.nil();
    };
    term.setColorBackground(&bg) catch {
        env.signalError("ghostel: failed to set background color");
        return env.nil();
    };
    return env.t();
}

/// (ghostel--debug-state TERM)
/// Returns a string with render state debug info.
fn fnDebugState(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    // Try update
    const update_result = gt.c.ghostty_render_state_update(term.render_state, term.terminal);
    pos += (std.fmt.bufPrint(buf[pos..], "update={d} ", .{update_result}) catch return env.nil()).len;

    // Read first row via iterator
    if (gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_ROW_ITERATOR, @ptrCast(&term.row_iterator)) != gt.SUCCESS) {
        pos += (std.fmt.bufPrint(buf[pos..], "iter=FAIL", .{}) catch return env.nil()).len;
        return env.makeString(buf[0..pos]);
    }

    var row_idx: usize = 0;
    while (gt.c.ghostty_render_state_row_iterator_next(term.row_iterator)) : (row_idx += 1) {
        if (row_idx >= 10) break;

        if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.RS_ROW_DATA_CELLS, @ptrCast(&term.row_cells)) != gt.SUCCESS) {
            pos += (std.fmt.bufPrint(buf[pos..], "row{d}=FAIL ", .{row_idx}) catch break).len;
            continue;
        }

        pos += (std.fmt.bufPrint(buf[pos..], "row{d}=\"", .{row_idx}) catch break).len;
        var col: usize = 0;
        while (gt.c.ghostty_render_state_row_cells_next(term.row_cells)) : (col += 1) {
            if (col >= 80) break;
            var graphemes_len: u32 = 0;
            if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_LEN, @ptrCast(&graphemes_len)) != gt.SUCCESS) continue;

            if (graphemes_len == 0) {
                if (pos < buf.len) {
                    buf[pos] = ' ';
                    pos += 1;
                }
                continue;
            }

            var codepoints: [4]u32 = undefined;
            if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_BUF, @ptrCast(&codepoints)) != gt.SUCCESS) continue;
            const cp: u21 = @intCast(codepoints[0]);
            const remaining = buf[pos..];
            if (remaining.len < 4) break;
            const enc_len = std.unicode.utf8Encode(cp, remaining) catch continue;
            pos += enc_len;
        }
        pos += (std.fmt.bufPrint(buf[pos..], "\" ", .{}) catch break).len;
    }

    return env.makeString(buf[0..pos]);
}

/// (ghostel--debug-feed TERM STR)
/// Feed STR to the terminal, update render state, return first row.
fn fnDebugFeed(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();

    var stack_buf: [4096]u8 = undefined;
    const data = env.extractString(args[1], &stack_buf) orelse return env.nil();

    // Feed directly to terminal
    gt.c.ghostty_terminal_vt_write(term.terminal, data.ptr, data.len);

    // Update render state
    _ = gt.c.ghostty_render_state_update(term.render_state, term.terminal);

    // Read cursor position
    var cx: u16 = 0;
    var cy: u16 = 0;
    _ = gt.c.ghostty_terminal_get(term.terminal, gt.c.GHOSTTY_TERMINAL_DATA_CURSOR_X, @ptrCast(&cx));
    _ = gt.c.ghostty_terminal_get(term.terminal, gt.c.GHOSTTY_TERMINAL_DATA_CURSOR_Y, @ptrCast(&cy));

    // Read first row from render state
    if (gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_ROW_ITERATOR, @ptrCast(&term.row_iterator)) != gt.SUCCESS) {
        return env.makeString("iter-fail");
    }

    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    pos += (std.fmt.bufPrint(buf[pos..], "cur=({d},{d}) row0=\"", .{ cx, cy }) catch return env.nil()).len;

    if (gt.c.ghostty_render_state_row_iterator_next(term.row_iterator)) {
        if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.RS_ROW_DATA_CELLS, @ptrCast(&term.row_cells)) == gt.SUCCESS) {
            var col: usize = 0;
            while (gt.c.ghostty_render_state_row_cells_next(term.row_cells)) : (col += 1) {
                if (col >= 60) break;
                var gl: u32 = 0;
                if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_LEN, @ptrCast(&gl)) != gt.SUCCESS) continue;
                if (gl == 0) {
                    if (pos < buf.len) { buf[pos] = ' '; pos += 1; }
                    continue;
                }
                var cp: [4]u32 = undefined;
                if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_BUF, @ptrCast(&cp)) != gt.SUCCESS) continue;
                const c21: u21 = @intCast(cp[0]);
                const rem = buf[pos..];
                if (rem.len < 4) break;
                const el = std.unicode.utf8Encode(c21, rem) catch continue;
                pos += el;
            }
        }
    }
    pos += (std.fmt.bufPrint(buf[pos..], "\"", .{}) catch return env.nil()).len;

    return env.makeString(buf[0..pos]);
}

/// (ghostel--module-version)
fn fnModuleVersion(raw_env: ?*c.emacs_env, _: isize, _: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    return env.makeString(version);
}

// ---------------------------------------------------------------------------
// Ghostty callbacks — invoked synchronously during vtWrite
// ---------------------------------------------------------------------------

/// Called when the terminal needs to write response data back to the PTY.
fn writePtyCallback(_: gt.Terminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
    const term: *Terminal = @ptrCast(@alignCast(userdata));
    const env = term.env orelse return;

    if (len == 0) return;
    const str = env.makeString(data[0..len]);
    _ = env.call1(emacs.sym.@"ghostel--flush-output", str);
}

/// Called when the terminal receives BEL.
fn bellCallback(_: gt.Terminal, userdata: ?*anyopaque) callconv(.c) void {
    const term: *Terminal = @ptrCast(@alignCast(userdata));
    const env = term.env orelse return;

    _ = env.call0(emacs.sym.ding);
}

/// Called when the terminal receives a device attributes query (DA1/DA2/DA3).
/// Reports as a VT220-compatible terminal with ANSI color support.
fn deviceAttributesCallback(_: gt.Terminal, _: ?*anyopaque, out: [*c]gt.DeviceAttributes) callconv(.c) bool {
    const attrs: *allowzero gt.DeviceAttributes = &out[0];
    attrs.primary = .{
        .conformance_level = 62, // VT220
        .features = undefined,
        .num_features = 1,
    };
    attrs.primary.features[0] = 22; // ANSI color
    attrs.secondary = .{
        .device_type = 1, // VT220
        .firmware_version = 1,
        .rom_cartridge = 0,
    };
    attrs.tertiary = .{
        .unit_id = 0,
    };
    return true;
}

/// Called when the terminal title changes.
fn titleChangedCallback(_: gt.Terminal, userdata: ?*anyopaque) callconv(.c) void {
    const term: *Terminal = @ptrCast(@alignCast(userdata));
    const env = term.env orelse return;

    if (term.getTitle()) |title| {
        _ = env.call1(emacs.sym.@"ghostel--set-title", env.makeString(title));
    }
}
