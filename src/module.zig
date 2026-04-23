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
const version = "0.17.0";

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
    env.bindFunction("ghostel--scroll-bottom", 1, 1, &fnScrollBottom, "Scroll the terminal viewport to the bottom.\n\n(ghostel--scroll-bottom TERM)");
    env.bindFunction("ghostel--encode-key", 3, 4, &fnEncodeKey, "Encode a key event using the terminal's key encoder.\n\n(ghostel--encode-key TERM KEY MODS &optional UTF8)");
    env.bindFunction("ghostel--mouse-event", 6, 6, &fnMouseEvent, "Send a mouse event to the terminal.\n\n(ghostel--mouse-event TERM ACTION BUTTON ROW COL MODS)");
    env.bindFunction("ghostel--focus-event", 2, 2, &fnFocusEvent, "Send a focus event to the terminal.\n\n(ghostel--focus-event TERM GAINED)");
    env.bindFunction("ghostel--set-palette", 2, 2, &fnSetPalette, "Set the ANSI color palette.\n\n(ghostel--set-palette TERM COLORS-STRING)");
    env.bindFunction("ghostel--set-default-colors", 3, 3, &fnSetDefaultColors, "Set default foreground and background colors.\n\n(ghostel--set-default-colors TERM FG-HEX BG-HEX)");
    env.bindFunction("ghostel--mode-enabled", 2, 2, &fnModeEnabled, "Return t if terminal DEC private MODE is enabled.\n\n(ghostel--mode-enabled TERM MODE)");
    env.bindFunction("ghostel--alt-screen-p", 1, 1, &fnAltScreen, "Return t if terminal is on the alternate screen buffer.\n\n(ghostel--alt-screen-p TERM)");
    env.bindFunction("ghostel--cursor-position", 1, 1, &fnCursorPosition, "Return terminal cursor position as (COL . ROW), 0-indexed.\n\n(ghostel--cursor-position TERM)");
    env.bindFunction("ghostel--cursor-pending-wrap-p", 1, 1, &fnCursorPendingWrap, "Return t if the cursor is in pending-wrap state.\n\n(ghostel--cursor-pending-wrap-p TERM)");
    env.bindFunction("ghostel--cursor-on-empty-row-p", 1, 1, &fnCursorOnEmptyRow, "Return t if the cursor row has no written cells or styled cells.\n\n(ghostel--cursor-on-empty-row-p TERM)");
    env.bindFunction("ghostel--debug-state", 1, 1, &fnDebugState, "Return debug info about terminal/render state.\n\n(ghostel--debug-state TERM)");
    env.bindFunction("ghostel--debug-feed", 2, 2, &fnDebugFeed, "Feed STR to terminal and return first row + cursor.\n\n(ghostel--debug-feed TERM STR)");
    env.bindFunction("ghostel--copy-all-text", 1, 1, &fnCopyAllText, "Return entire scrollback as plain text string.\n\n(ghostel--copy-all-text TERM)");
    env.bindFunction("ghostel--module-version", 0, 0, &fnModuleVersion, "Return the native module version string.\n\n(ghostel--module-version)");
    env.bindFunction("ghostel--enable-vt-log", 0, 0, &fnEnableVtLog, "Enable libghostty internal log routing to *ghostel-debug*.\n\n(ghostel--enable-vt-log)");
    env.bindFunction("ghostel--disable-vt-log", 0, 0, &fnDisableVtLog, "Disable libghostty internal log routing.\n\n(ghostel--disable-vt-log)");

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
        5 * 1024 * 1024; // ~5 MB, roughly 5k rows on an 80-column terminal

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

    // Stash env for callbacks (and for the VT log callback)
    term.env = env;
    defer term.env = null;
    if (vt_log_active) {
        vt_log_env = env;
        defer vt_log_env = null;
    }

    const raw = data.?;

    // Respond to OSC 4/10/11 color queries BEFORE feeding libghostty.
    // libghostty will synchronously emit responses for other queries in
    // the same write (e.g. CSI 6n cursor-position report) via the
    // write_pty callback, and termenv-based programs read only the first
    // response chunk — so the color reply must be on the wire first or
    // the program discards our reply as noise.
    extractOscColorQueries(env, term, raw);

    // Normalize CRLF by streaming directly into libghostty's parser.
    // Emacs PTYs lack ONLCR, so bare \n arrives without \r — insert
    // one before each bare \n by feeding the preceding segment verbatim
    // and then "\r\n".  libghostty's VT state machine handles arbitrary
    // chunking (that's how the process filter already works), so no
    // scratch buffer, no allocation, no truncation fallback.
    //
    // `prev_was_cr` is seeded from `term.last_input_was_cr` so a CRLF
    // pair split across two writes — chunk A ending with \r, chunk B
    // starting with \n — is not mis-normalized into \r\r\n.  The final
    // value is persisted back for the next call. An empty input

    // round-trips the flag unchanged.
    var seg_start: usize = 0;
    var prev_was_cr: bool = term.last_input_was_cr;
    for (raw, 0..) |ch, i| {
        if (ch == '\n' and !prev_was_cr) {
            if (i > seg_start) term.vtWrite(raw[seg_start..i]);
            term.vtWrite("\r\n");
            seg_start = i + 1;
            prev_was_cr = false;
        } else {
            prev_was_cr = (ch == '\r');
        }
    }
    if (seg_start < raw.len) {
        term.vtWrite(raw[seg_start..]);
    }
    term.last_input_was_cr = prev_was_cr;

    // Detect CSI 3 J (erase scrollback). libghostty processes it and clears
    // its scrollback, but provides no notification. Set rebuild_pending so the
    // next redraw erases the Emacs buffer and re-fetches from libghostty.
    // The flag is necessary because CSI 3 J followed by enough new output to
    // restore the same scrollback depth is undetectable by count or hash alone.
    //
    // This is a stateless substring scan over a single write, so it misses:
    // (1) sequences split across two writes (ESC in one, "[3J" in the next);
    // (2) non-canonical forms — parameter padding like `\x1B[03J`, or the
    //     8-bit C1 form `\x9B3J`.
    // libghostty's stateful VT parser still clears its scrollback in those
    // cases, so the `libghostty_sb < scrollback_in_buffer` shrink check in
    // redraw() is the fallback that catches them.
    if (std.mem.indexOf(u8, raw, "\x1B[3J") != null) {
        term.rebuild_pending = true;
    }

    // Scan for OSC sequences that libghostty-vt discards (7, 51, 52, 133).
    // One pass, dispatched by code in document order.
    dispatchPostWriteOscs(env, term, raw);

    return env.nil();
}

// ---------------------------------------------------------------------------
// OSC sequence helpers
// ---------------------------------------------------------------------------

/// An OSC sequence extracted by `OscIterator`.
const OscEntry = struct {
    /// Decimal OSC code (e.g. 4, 7, 10, 11, 51, 52, 133).
    code: u32,
    /// Payload bytes between the code's trailing `;` and the terminator.
    payload: []const u8,
    /// Terminator bytes (BEL or ESC \) — forwarded back on replies.
    terminator: []const u8,
};

/// Single-pass iterator over well-formed OSC sequences in a byte slice.
/// Advances past `ESC ]`, parses the decimal code up to `;`, locates the
/// BEL/ST terminator, and yields `(code, payload, terminator)`.
///
/// An OSC payload is bounded by a real terminator (BEL or ESC \) OR by
/// the next OSC introducer (ESC ]).  Stopping at a following introducer
/// handles malformed input where one OSC is missing its terminator
/// before the next begins — otherwise the partial OSC would cannibalize
/// the following OSC's bytes (including its terminator) as its own
/// payload, producing a garbage dispatch AND starving the next OSC.
/// On partial detection we advance past the current introducer and let
/// iteration continue, so well-formed OSCs later in the same buffer
/// still dispatch.
const OscIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *OscIterator) ?OscEntry {
        while (self.pos < self.data.len) {
            const intro = std.mem.indexOfPos(u8, self.data, self.pos, "\x1b]") orelse {
                self.pos = self.data.len;
                return null;
            };
            const code_start = intro + 2;

            // Decimal code up to the first `;`.
            var code_end = code_start;
            while (code_end < self.data.len and self.data[code_end] >= '0' and self.data[code_end] <= '9') {
                code_end += 1;
            }
            if (code_end == code_start or code_end >= self.data.len or self.data[code_end] != ';') {
                self.pos = code_start;
                continue;
            }
            const payload_start = code_end + 1;

            // Scan for a terminator (BEL or ESC \) or the next OSC
            // introducer (ESC ]), whichever comes first. An intervening
            // introducer means the current OSC is partial.
            var end = payload_start;
            var term_len: usize = 0;
            while (end < self.data.len) : (end += 1) {
                const ch = self.data[end];
                if (ch == 0x07) {
                    term_len = 1;
                    break;
                }
                if (ch == 0x1b and end + 1 < self.data.len) {
                    const next_ch = self.data[end + 1];
                    if (next_ch == '\\') {
                        term_len = 2;
                        break;
                    }
                    if (next_ch == ']') {
                        // Next introducer — current OSC is partial.
                        break;
                    }
                }
            }
            if (term_len == 0) {
                // Partial OSC: skip past the current introducer (which
                // we already parsed) and resume scanning. If `end` is
                // still `self.data.len` there were no more introducers,
                // and the next indexOfPos call will terminate iteration.
                self.pos = if (end > code_start) end else code_start;
                continue;
            }

            self.pos = end + term_len;
            const code = std.fmt.parseInt(u32, self.data[code_start..code_end], 10) catch continue;
            return .{
                .code = code,
                .payload = self.data[payload_start..end],
                .terminator = self.data[end .. end + term_len],
            };
        }
        return null;
    }
};

/// Dispatch OSC 7 / 51 / 52 / 133 from `data` in document order.
/// These are the post-vtWrite sequences that libghostty-vt discards,
/// so ghostel has to scan for them itself.  All four used to scan the
/// buffer independently; one unified pass is strictly less work for
/// bulk output and preserves source-order dispatch.  (OSC 4/10/11
/// color queries use the same iterator but run before vtWrite — see
/// `extractOscColorQueries`.)
///
/// Runs AFTER `vtWrite` so libghostty has already seen the bytes —
/// OSC 7 calls back into libghostty (`setPwd`) and the others call
/// Elisp.
fn dispatchPostWriteOscs(env: emacs.Env, term: *Terminal, data: []const u8) void {
    var it = OscIterator{ .data = data };
    while (it.next()) |osc| {
        switch (osc.code) {
            // OSC 7: working directory as a file:// URL.
            7 => {
                if (osc.payload.len == 0) continue;
                const gs = gt.GhosttyString{ .ptr = osc.payload.ptr, .len = osc.payload.len };
                term.setPwd(&gs) catch {};
            },
            // OSC 51;E: whitelisted Elisp eval (ghostel extension).
            51 => {
                if (osc.payload.len < 2 or osc.payload[0] != 'E') continue;
                _ = env.call1(
                    emacs.sym.@"ghostel--osc51-eval",
                    env.makeString(osc.payload[1..]),
                );
            },
            // OSC 52: clipboard set.  Queries ("?") are ignored.
            52 => {
                const semi = std.mem.indexOfScalar(u8, osc.payload, ';') orelse continue;
                const selection = osc.payload[0..semi];
                const b64 = osc.payload[semi + 1 ..];
                if (b64.len == 0) continue;
                if (b64.len == 1 and b64[0] == '?') continue;
                _ = env.call2(
                    emacs.sym.@"ghostel--osc52-handle",
                    env.makeString(selection),
                    env.makeString(b64),
                );
            },
            // OSC 133: semantic prompt markers (A/B/C/D).
            133 => {
                if (osc.payload.len == 0) continue;
                const marker_type = osc.payload[0];
                if (marker_type != 'A' and marker_type != 'B' and marker_type != 'C' and marker_type != 'D') continue;
                const has_param = osc.payload.len > 1 and osc.payload[1] == ';';
                const param_data = if (has_param) osc.payload[2..] else &[_]u8{};
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
            },
            // OSC 9: iTerm2 desktop notification, with ConEmu sub-codes
            // carved out (see `dispatchOsc9`).
            9 => dispatchOsc9(env, term, osc.payload),
            // OSC 777: rxvt "notify" extension — `notify;TITLE;BODY`.
            777 => dispatchOsc777(env, osc.payload),
            else => {},
        }
    }
}

/// Dispatch OSC 9.  The iTerm2 form is `9;<body>` with no title; ConEmu
/// overloads the same code with `9;<subcode>[;...]` for unrelated things
/// (progress, tab titles, env vars, etc.).  Ghostel implements two of the
/// sub-codes — `9;4` progress reports (routed to `ghostel--osc-progress`)
/// and `9;9` CWD reporting (routed through libghostty's `setPwd`, same as
/// OSC 7).  Other recognised ConEmu sub-codes are silently dropped so
/// stray control sequences don't pop spurious notifications.  Anything
/// that isn't a valid ConEmu sub-code falls through to
/// `ghostel--handle-notification` as an iTerm2 notification.  The
/// validation rules here mirror ghostty-vt's osc9.zig so ghostel's
/// drop/route/notify split stays consistent with upstream's parse.
fn dispatchOsc9(env: emacs.Env, term: *Terminal, payload: []const u8) void {
    if (payload.len == 0) return;

    const first = payload[0];
    if (first >= '0' and first <= '9') {
        // Parse the leading digit run.
        var i: usize = 0;
        while (i < payload.len and payload[i] >= '0' and payload[i] <= '9') : (i += 1) {}
        const subcode_str = payload[0..i];
        const rest = payload[i..];
        const subcode = std.fmt.parseInt(u16, subcode_str, 10) catch {
            dispatchOsc9Notification(env, payload);
            return;
        };

        // OSC 9;4: progress report.  Valid forms start with `;<digit>`;
        // anything else falls through to the iTerm2 notification path.
        if (subcode == 4 and rest.len >= 2 and rest[0] == ';') {
            if (dispatchOsc9Progress(env, rest[1..])) return;
        }

        // OSC 9;9: ConEmu CWD reporting — same payload shape as OSC 7,
        // so we route it through `term.setPwd` (libghostty-vt discards
        // OSC 9, so this is the one place it gets picked up).
        if (subcode == 9 and rest.len >= 2 and rest[0] == ';') {
            const path = rest[1..];
            if (path.len > 0) {
                const gs = gt.GhosttyString{ .ptr = path.ptr, .len = path.len };
                term.setPwd(&gs) catch {};
            }
            return;
        }

        // Other recognised ConEmu sub-codes — silently dropped.  Each
        // check mirrors ghostty-vt's parser closely enough that payloads
        // it would reject fall through to the notification path below
        // (with two deliberate divergences — 9;5 and 9;12, see below).
        const is_conemu = switch (subcode) {
            1, 2, 3, 6, 7, 8, 11 => rest.len >= 1 and rest[0] == ';',
            // `9;5` (wait-input) and `9;12` (prompt start) take no
            // arguments.  ghostty-vt happens to consume trailing bytes
            // too, but matching that would swallow iTerm2 notifications
            // whose body starts with "5" or "12" (e.g. "5 minutes left")
            // — a realistic UX footgun — so we only treat these as
            // ConEmu when nothing follows the subcode.
            5, 12 => rest.len == 0,
            // `9;10` (bare) or `9;10;0..3[...]` → ConEmu xterm
            // emulation.  Anything else (`9;10;4`, `9;10;`, `9;10;abc`)
            // is invalid per ghostty-vt and must notify.  Matches
            // upstream's lax treatment of trailing bytes after a valid
            // first arg digit (e.g. `9;10;01`, `9;10;3x` → emulation).
            10 => rest.len == 0 or
                (rest.len >= 2 and rest[0] == ';' and
                    rest[1] >= '0' and rest[1] <= '3'),
            else => false,
        };
        if (is_conemu) return;
    }

    // Unrecognised `9;<digit>...` payloads fall through as iTerm2
    // notifications with the raw body (digit run included).  That's
    // intentional: the iTerm2 form has no sub-code namespace, so the
    // body is whatever follows the `9;`.
    dispatchOsc9Notification(env, payload);
}

fn dispatchOsc9Notification(env: emacs.Env, body: []const u8) void {
    _ = env.call2(
        emacs.sym.@"ghostel--handle-notification",
        env.makeString(""),
        env.makeString(body),
    );
}

/// Parse the payload that follows `9;4;` and dispatch to Elisp.  Returns
/// true if a progress event was emitted.
///
/// State semantics mirror ghostty-vt's parser at the protocol level:
///   - `set`  (1) defaults progress to 0 when unreported.
///   - `error` (2) / `pause` (4) accept an optional progress value.
///   - `remove` (0) / `indeterminate` (3) ignore any trailing progress.
///
/// Trailing-semicolon handling is slightly more forgiving than upstream:
/// `9;4;1;` and `9;4;1;50;` are treated the same as `9;4;1` and
/// `9;4;1;50`, whereas ghostty-vt's parseUnsigned returns null on the
/// trailing `;`.  Matters only for exotic emitters.
fn dispatchOsc9Progress(env: emacs.Env, data: []const u8) bool {
    if (data.len == 0) return false;
    const state_digit = data[0];
    const state_str: []const u8 = switch (state_digit) {
        '0' => "remove",
        '1' => "set",
        '2' => "error",
        '3' => "indeterminate",
        '4' => "pause",
        else => return false,
    };

    // Default progress: `set` starts at 0; all other states start nil.
    var progress_val = if (state_digit == '1') env.makeInteger(0) else env.nil();
    const accepts_progress = state_digit != '0' and state_digit != '3';

    if (accepts_progress and data.len >= 3 and data[1] == ';') {
        var tail = data[2..];
        // Trim trailing `;` so `9;4;0;` and similar don't fail to parse.
        while (tail.len > 0 and tail[tail.len - 1] == ';') tail.len -= 1;
        if (tail.len > 0) {
            // u64 is wide enough to absorb garbage like `99999999999`
            // without overflowing parseInt; the result is clamped to 100
            // regardless.
            if (std.fmt.parseInt(u64, tail, 10)) |n| {
                const clamped: i64 = @intCast(@min(n, 100));
                progress_val = env.makeInteger(clamped);
            } else |_| {}
        }
    }

    _ = env.call2(
        emacs.sym.@"ghostel--osc-progress",
        env.makeString(state_str),
        progress_val,
    );
    return true;
}

/// Dispatch OSC 777: `notify;TITLE;BODY`.  Any other extension is ignored
/// (rxvt defines `notify` as the only one we care about).
fn dispatchOsc777(env: emacs.Env, payload: []const u8) void {
    const first_semi = std.mem.indexOfScalar(u8, payload, ';') orelse return;
    if (!std.mem.eql(u8, payload[0..first_semi], "notify")) return;
    const after_ext = payload[first_semi + 1 ..];
    // Title and body are separated by the next `;`.  If no separator,
    // treat the whole remainder as body with empty title.
    const second_semi = std.mem.indexOfScalar(u8, after_ext, ';');
    const title = if (second_semi) |s| after_ext[0..s] else "";
    const body = if (second_semi) |s| after_ext[s + 1 ..] else after_ext;
    _ = env.call2(
        emacs.sym.@"ghostel--handle-notification",
        env.makeString(title),
        env.makeString(body),
    );
}

/// Send `OSC N;rgb:RRRR/GGGG/BBBB <term>` for a dynamic color (OSC 10/11).
fn sendDynamicColorReply(
    env: emacs.Env,
    osc_num: u8,
    color: gt.ColorRgb,
    term_bytes: []const u8,
) void {
    var buf: [64]u8 = undefined;
    const written = std.fmt.bufPrint(
        &buf,
        "\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}",
        .{
            osc_num,
            color.r, color.r,
            color.g, color.g,
            color.b, color.b,
            term_bytes,
        },
    ) catch return;
    _ = env.call1(emacs.sym.@"ghostel--flush-output", env.makeString(written));
}

/// Send `OSC 4;INDEX;rgb:RRRR/GGGG/BBBB <term>` for a palette entry.
fn sendPaletteColorReply(
    env: emacs.Env,
    index: u16,
    color: gt.ColorRgb,
    term_bytes: []const u8,
) void {
    var buf: [64]u8 = undefined;
    const written = std.fmt.bufPrint(
        &buf,
        "\x1b]4;{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}",
        .{
            index,
            color.r, color.r,
            color.g, color.g,
            color.b, color.b,
            term_bytes,
        },
    ) catch return;
    _ = env.call1(emacs.sym.@"ghostel--flush-output", env.makeString(written));
}

/// Scan data for OSC 4/10/11 color queries and emit responses in source
/// order.  libghostty applies OSC 4/10/11 **sets** internally but silently
/// drops the query form (`?` value), so ghostel scans the raw input and
/// replies itself.
///
/// Colors come from the terminal's currently effective state, which reflects
/// sets applied by earlier write-input calls — but NOT sets that appear
/// earlier in *this* input buffer, because this extractor runs before
/// `vtWrite` so the color reply is on the wire before any reply libghostty
/// generates itself (e.g. the CSI 6n cursor-position reply some programs
/// send in the same write).  Termenv-based readers consume the first chunk
/// off stdin, so ordering matters more than same-chunk freshness.
///
/// Only fully-terminated OSC sequences produce a reply: a query split
/// across two process-output chunks is ignored until a later call carries
/// the terminator.
fn extractOscColorQueries(env: emacs.Env, term: *Terminal, data: []const u8) void {
    var palette: [256]gt.ColorRgb = undefined;
    var palette_loaded = false;

    var it = OscIterator{ .data = data };
    while (it.next()) |osc| {
        switch (osc.code) {
            10 => {
                if (!std.mem.eql(u8, osc.payload, "?")) continue;
                var fg: gt.ColorRgb = undefined;
                if (!term.getColorForeground(&fg)) continue;
                sendDynamicColorReply(env, 10, fg, osc.terminator);
            },
            11 => {
                if (!std.mem.eql(u8, osc.payload, "?")) continue;
                var bg: gt.ColorRgb = undefined;
                if (!term.getColorBackground(&bg)) continue;
                sendDynamicColorReply(env, 11, bg, osc.terminator);
            },
            4 => {
                // Payload is a ';'-separated list of `index;value` pairs.
                // Reply only to pairs whose value is literally "?".
                var sub = std.mem.splitScalar(u8, osc.payload, ';');
                while (sub.next()) |index_tok| {
                    const value_tok = sub.next() orelse break;
                    if (!std.mem.eql(u8, value_tok, "?")) continue;
                    const idx = std.fmt.parseInt(u32, index_tok, 10) catch continue;
                    if (idx >= 256) continue;
                    if (!palette_loaded) {
                        if (!term.getColorPalette(&palette)) break;
                        palette_loaded = true;
                    }
                    sendPaletteColorReply(env, @intCast(idx), palette[idx], osc.terminator);
                }
            },
            else => {},
        }
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
    // Reflow invalidates the materialized scrollback — terminal.resize()
    // sets rebuild_pending so the next redraw() erases and rebuilds under
    // inhibit-redisplay, avoiding a visible blank frame.

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
    if (vt_log_active) {
        vt_log_env = env;
        defer vt_log_env = null;
    }
    render.redraw(env, term, force_full);
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

/// (ghostel--alt-screen-p TERM)
/// Return t if the terminal is on the alternate screen buffer.
fn fnAltScreen(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();
    return if (term.isAltScreen()) env.t() else env.nil();
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

/// (ghostel--cursor-position TERM)
/// Return the terminal cursor position as (COL . ROW), 0-indexed.
/// Returns nil when the cursor has no value (e.g. scrolled away).
fn fnCursorPosition(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();

    // Ensure render state is up to date
    _ = gt.c.ghostty_render_state_update(term.render_state, term.terminal);

    var cursor_has_value: bool = false;
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_HAS_VALUE, @ptrCast(&cursor_has_value));
    if (!cursor_has_value) return env.nil();

    var cx: u16 = 0;
    var cy: u16 = 0;
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_X, @ptrCast(&cx));
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_Y, @ptrCast(&cy));

    return env.call2(emacs.sym.cons, env.makeInteger(@as(i64, cx)), env.makeInteger(@as(i64, cy)));
}

/// (ghostel--cursor-pending-wrap-p TERM)
/// Return t if the terminal's active cursor is in pending-wrap state
/// (i.e. the last printed character filled the rightmost column and the
/// next print will soft-wrap), nil otherwise.
fn fnCursorPendingWrap(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();

    var pending: bool = false;
    if (gt.c.ghostty_terminal_get(term.terminal, gt.DATA_CURSOR_PENDING_WRAP, @ptrCast(&pending)) != gt.SUCCESS) {
        return env.nil();
    }
    return if (pending) env.t() else env.nil();
}

/// (ghostel--cursor-on-empty-row-p TERM)
/// Return t if the row containing the active cursor has no written
/// cells and no cells with non-default style — i.e. the row renders to
/// an empty Emacs buffer line.  Used alongside pending-wrap by
/// `ghostel--anchor-window' to detect TUI CUP parks onto a trailing
/// empty row, which also land `point' at `point-max' on the last
/// visible row and would otherwise provoke a redisplay-induced scroll.
fn fnCursorOnEmptyRow(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();

    if (gt.c.ghostty_render_state_update(term.render_state, term.terminal) != gt.SUCCESS) return env.nil();

    // Use viewport-relative cursor Y so the row index matches the
    // viewport iterator `isRowEmptyAt' walks. Falls back to nil when
    // the cursor isn't visible in the current viewport (e.g. scrolled
    // into scrollback), which is also the safe answer for the clamp.
    var has_value: bool = false;
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_HAS_VALUE, @ptrCast(&has_value));
    if (!has_value) return env.nil();

    var cy: u16 = 0;
    if (gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_Y, @ptrCast(&cy)) != gt.SUCCESS) {
        return env.nil();
    }
    return if (render.isRowEmptyAt(term, cy)) env.t() else env.nil();
}

/// (ghostel--copy-all-text TERM)
/// Return the entire scrollback as a plain text string using the formatter API.
fn fnCopyAllText(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(Terminal, args[0]) orelse return env.nil();

    var options: gt.FormatterTerminalOptions = std.mem.zeroes(gt.FormatterTerminalOptions);
    options.size = @sizeOf(gt.FormatterTerminalOptions);
    options.emit = gt.FORMATTER_PLAIN;
    options.unwrap = true;
    options.trim = true;
    // extra and selection stay zeroed (null)

    var formatter: gt.Formatter = undefined;
    if (gt.c.ghostty_formatter_terminal_new(null, &formatter, term.terminal, options) != gt.SUCCESS) {
        env.signalError("ghostel: failed to create formatter");
        return env.nil();
    }
    defer gt.c.ghostty_formatter_free(formatter);

    var ptr: [*c]u8 = undefined;
    var len: usize = 0;
    if (gt.c.ghostty_formatter_format_alloc(formatter, null, &ptr, &len) != gt.SUCCESS) {
        env.signalError("ghostel: formatter failed");
        return env.nil();
    }

    if (len == 0 or ptr == null) return env.nil();
    defer gt.c.ghostty_free(null, ptr, len);
    return env.makeString(ptr[0..len]);
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
    attrs.primary = std.mem.zeroes(@TypeOf(attrs.primary));
    attrs.primary.conformance_level = 62; // VT220
    attrs.primary.num_features = 1;
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

// ---------------------------------------------------------------------------
// libghostty log callback
// ---------------------------------------------------------------------------

/// Global Emacs env stashed during any Elisp→Zig call where logging is
/// active.  Only valid on the main thread while a Zig function is
/// executing; set to null at all other times.
///
/// Thread safety: the GhosttySysLogFn contract requires thread safety,
/// but ghostel only drives libghostty from Emacs's main thread, so the
/// callback always fires on the same thread that stashed the env.  If
/// libghostty ever uses background threads, this would need a mutex or
/// a lock-free message queue.
var vt_log_env: ?emacs.Env = null;

/// Log callback matching GhosttySysLogFn.  Formats the message and
/// forwards it to `ghostel--debug-log-vt' in Elisp.
fn vtLogCallback(
    _: ?*anyopaque,
    level: gt.c.GhosttySysLogLevel,
    scope: [*c]const u8,
    scope_len: usize,
    message: [*c]const u8,
    message_len: usize,
) callconv(.c) void {
    const env = vt_log_env orelse return;
    const level_str: []const u8 = switch (level) {
        gt.c.GHOSTTY_SYS_LOG_LEVEL_ERROR => "error",
        gt.c.GHOSTTY_SYS_LOG_LEVEL_WARNING => "warning",
        gt.c.GHOSTTY_SYS_LOG_LEVEL_INFO => "info",
        gt.c.GHOSTTY_SYS_LOG_LEVEL_DEBUG => "debug",
        else => "unknown",
    };
    const scope_slice: []const u8 = if (scope_len > 0) scope[0..scope_len] else "default";
    const msg_slice: []const u8 = if (message_len > 0) message[0..message_len] else "";

    _ = env.call3(
        emacs.sym.@"ghostel--debug-log-vt",
        env.makeString(level_str),
        env.makeString(scope_slice),
        env.makeString(msg_slice),
    );

    // If the Elisp call signaled an error (e.g. ghostel--debug-log-vt is
    // void-function because ghostel-debug.el isn't loaded), clear it so it
    // doesn't leak into the calling context and disable logging to prevent
    // repeated errors.
    if (env.nonLocalExitCheck() != c.emacs_funcall_exit_return) {
        env.nonLocalExitClear();
        _ = gt.c.ghostty_sys_set(gt.c.GHOSTTY_SYS_OPT_LOG, null);
        vt_log_active = false;
    }
}

/// Whether the VT log callback is installed.
var vt_log_active: bool = false;

/// (ghostel--enable-vt-log)
fn fnEnableVtLog(raw_env: ?*c.emacs_env, _: isize, _: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    if (!vt_log_active) {
        const cb: gt.c.GhosttySysLogFn = &vtLogCallback;
        _ = gt.c.ghostty_sys_set(gt.c.GHOSTTY_SYS_OPT_LOG, @ptrCast(cb));
        vt_log_active = true;
    }
    return env.t();
}

/// (ghostel--disable-vt-log)
fn fnDisableVtLog(raw_env: ?*c.emacs_env, _: isize, _: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    if (vt_log_active) {
        _ = gt.c.ghostty_sys_set(gt.c.GHOSTTY_SYS_OPT_LOG, null);
        vt_log_active = false;
    }
    return env.t();
}
