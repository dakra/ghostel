/// Terminal state management wrapping libghostty-vt.
///
/// Holds the resources for a single instance of a Ghostel terminal
///
const std = @import("std");
const Allocator = std.mem.Allocator;

const emacs = @import("emacs.zig");
const gt = @import("ghostty-vt");
const GhostelHandler = @import("GhostelHandler.zig");
const Renderer = @import("Renderer.zig");
const input = @import("input.zig");
const kitty_graphics = @import("kitty_graphics.zig");
const utils = @import("utils.zig");
const parseHexColor = utils.parseHexColor;
const parseHexByte = utils.parseHexByte;

const Self = @This();

/// Allocator used for all owned allocations; injected at init time.
alloc: Allocator,

/// The libghostty Terminal.
terminal: gt.Terminal,

/// The libghostty Stream, wrapped in our `GhostelHandler` so we can
/// intercept OSC actions (PWD, clipboard, notifications, color queries,
/// semantic prompt) without re-parsing the bytes ourselves.
stream: gt.Stream(GhostelHandler),

/// True iff the last byte of the previous `fnWriteInput` input was
/// `\r`. Carries the bare-LF detection state across write-input calls
/// so that a CR at the tail of one write and an LF at the head of the
/// next don't get normalized into an extra `\r` (producing `\r\r\n`).
///
/// Named after the input stream rather than what was fed to libghostty
/// because the two only differ in that the normalizer may insert a
/// `\r` before a bare LF — it never drops or rewrites a trailing CR.
/// Reset by `resize` since a reflow means the stream is effectively
/// new.
last_input_was_cr: bool = false,

renderer: Renderer,

/// Create a new terminal with the given dimensions and scrollback.
pub fn init(alloc: Allocator, cols: u16, rows: u16, max_scrollback: usize, effects: gt.TerminalStream.Handler.Effects) !*Self {
    if (cols == 0 or rows == 0) return error.InvalidSize;

    const opts = gt.Terminal.Options{
        .cols = cols,
        .rows = rows,
        .max_scrollback = max_scrollback,
        // Enable grapheme clustering since that is how Emacs will render it anyway
        .default_modes = .{
            .grapheme_cluster = true,
        },
    };

    const term = try alloc.create(Self);
    errdefer alloc.destroy(term);

    term.* = Self{
        .alloc = alloc,
        .terminal = try .init(alloc, opts),
        .renderer = undefined,
        .stream = undefined,
    };
    errdefer term.terminal.deinit(alloc);

    var handler = GhostelHandler.init(&term.terminal);
    handler.inner.effects = effects;
    term.stream = .initAlloc(alloc, handler);
    errdefer term.stream.deinit();

    term.renderer = try .init(alloc, &term.terminal);

    return term;
}

/// Free all ghostty resources.
pub fn deinit(self: *Self) void {
    self.renderer.deinit(self.alloc);
    self.stream.deinit();
    self.terminal.deinit(self.alloc);
    self.alloc.destroy(self);
}

/// Set default foreground color.
pub fn setColorForeground(self: *Self, color: gt.color.RGB) void {
    self.terminal.colors.foreground.default = color;
    self.terminal.flags.dirty.palette = true;
}

/// Set default background color.
pub fn setColorBackground(self: *Self, color: gt.color.RGB) void {
    self.terminal.colors.background.default = color;
    self.terminal.flags.dirty.palette = true;
}

/// Set the color palette (256 entries).
pub fn setColorPalette(self: *Self, palette: gt.color.Palette) void {
    self.terminal.colors.palette.changeDefault(palette);
    self.terminal.flags.dirty.palette = true;
}

/// Enable kitty graphics protocol with the given storage limit (bytes).
///
/// `medium_file`/`medium_temp_file`/`medium_shared_mem` open additional
/// image-loading paths beyond the default direct (base64-encoded inline)
/// medium.  These extra mediums let a remote program instruct ghostel
/// to read arbitrary local files or shared-memory regions, so leave
/// them disabled unless the caller explicitly opts in.
///
/// Passing `&storage_limit_u64` and `&yes` (stack locals) is safe:
/// libghostty's terminal_set dereferences the pointer and copies the
/// value into the screen's image_limits before returning — it never
/// retains the caller's pointer.  The header declares the storage
/// limit as `uint64_t*`, so the local is widened to `u64` even when
/// `usize` happens to be 64 bits on the host (the explicit cast keeps
/// the ABI contract stable across 32-bit targets).
pub fn enableKittyGraphics(
    self: *Self,
    storage_limit: usize,
    medium_file: bool,
    medium_temp_file: bool,
    medium_shared_mem: bool,
) !void {
    var it = self.terminal.screens.all.iterator();
    while (it.next()) |entry| {
        const screen = entry.value.*;
        try screen.kitty_images.setLimit(screen.alloc, screen, storage_limit);
        screen.kitty_images.image_limits.file = medium_file;
        screen.kitty_images.image_limits.temporary_file = medium_temp_file;
        screen.kitty_images.image_limits.shared_memory = medium_shared_mem;
    }
}

/// Feed VT data from the PTY into the terminal.
pub fn vtWrite(self: *Self, data: []const u8) void {
    self.stream.nextSlice(data);
}

/// Resize the terminal. The col/row size gets committed on next redraw in order
/// to ensure that the we fully render the very latest state in case any rows
/// get promoted to scrollback due to vertical shrinking of the viewport.
pub fn resize(self: *Self, cols: u16, rows: u16, cell_w: u32, cell_h: u32) void {
    self.renderer.resize(cols, rows, cell_w, cell_h);
}

var module_alloc: Allocator = undefined;

pub fn initModule(allocator: Allocator, env: emacs.Env) void {
    module_alloc = allocator;
    env.registerFunctions(&emacs_functions);
}

fn terminalFinalize(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const term: *Self = @ptrCast(@alignCast(p));
        term.deinit();
    }
}

/// Called when the terminal needs to write response data back to the PTY.
fn writePtyCallback(_: *gt.TerminalStream.Handler, data: [:0]const u8) void {
    const env = emacs.current_env orelse return;
    if (data.len == 0) return;
    _ = env.f("ghostel--flush-output", .{data});
}

/// Called when the terminal receives BEL.
fn bellCallback(_: *gt.TerminalStream.Handler) void {
    const env = emacs.current_env orelse return;
    _ = env.f("ding", .{});
}

// TODO: DeviceAttributes is not exported from ghostty-vt for some reason.
//       We should file an issue.
const DeviceAttributesFn = @typeInfo(
    @typeInfo(
        @FieldType(gt.TerminalStream.Handler.Effects, "device_attributes"),
    ).optional.child,
).pointer.child;
const DeviceAttributes = @typeInfo(DeviceAttributesFn).@"fn".return_type.?;

/// Called when the terminal receives a device attributes query (DA1/DA2/DA3).
/// Reports as a VT220-compatible terminal with ANSI color support.
fn deviceAttributesCallback(_: *gt.TerminalStream.Handler) DeviceAttributes {
    return .{
        .primary = .{
            .conformance_level = .vt220,
            .features = &.{.ansi_color},
        },
        .secondary = .{
            .device_type = .vt220,
            .firmware_version = 1,
            .rom_cartridge = 0,
        },
        .tertiary = .{
            .unit_id = 0,
        },
    };
}

/// Called for XTWINOPS size queries (CSI 14/16/18 t).
fn sizeCallback(handler: *gt.TerminalStream.Handler) ?gt.size_report.Size {
    const term: *Self = @fieldParentPtr("terminal", handler.terminal);
    return .{
        .rows = term.terminal.rows,
        .columns = term.terminal.cols,
        .cell_width = term.terminal.width_px / term.terminal.cols,
        .cell_height = term.terminal.height_px / term.terminal.rows,
    };
}

/// Called when the terminal title changes.
fn titleChangedCallback(handler: *gt.TerminalStream.Handler) void {
    const term: *Self = @fieldParentPtr("terminal", handler.terminal);
    const env = emacs.current_env orelse return;
    const title = term.terminal.getTitle();
    if (title) |t| {
        _ = env.f("ghostel--set-title", .{t});
    }
}

// ---------------------------------------------------------------------------
// OSC 51 (ghostel extension) — elisp eval
// ---------------------------------------------------------------------------

// TODO: Ghostty's parser is a whitelist state machine and if a 5 is
//   followed by 1, the parser transitions to .invalid.
//   Replace this with either an upstream fix or change to OSC52;E
//   OSC 52 is the clipboard parser where only the "c, p, s, q, 0-7"
//   kinds are used.

/// Only OSC 51 (ghostel's elisp-eval extension) still needs a byte scan
/// because it is not a standard OSC that ghostty's parser knows about.
///
/// Dispatch each `ESC ] 51 ; E <payload> (BEL|ST)` in `data` to
/// `ghostel--osc51-eval`.  Other OSC 51 sub-codes (used by other
/// terminals for things unrelated to elisp eval) are ignored.
///
/// Single-pass scan: the `intermediate` introducer carries the literal
/// "E" so we can match the full prefix in one `indexOfPos`.  Limitation:
/// an OSC 51 split across two `ghostel--write-input` calls is dropped
/// entirely — we keep no carry-over state between calls.  Unlike
/// ghostty's `Parser`, which buffers an OSC body across chunks, this
/// scanner only sees one `data` slice at a time.  Adding carry-over
/// would require per-`GhostelTerm` state; not worth it until an
/// OSC 51 chunk-spanning case actually shows up.
fn dispatchOsc51(env: emacs.Env, data: []const u8) void {
    const intro = "\x1b]51;E";
    var pos: usize = 0;
    while (pos + intro.len <= data.len) {
        const start = std.mem.indexOfPos(u8, data, pos, intro) orelse return;
        const payload_start = start + intro.len;
        // Find BEL or ST terminator.  Stops at the next OSC introducer
        // too: a missing terminator on the current OSC should not
        // cannibalize the following one.
        var end = payload_start;
        var term_len: usize = 0;
        while (end < data.len) : (end += 1) {
            const ch = data[end];
            if (ch == 0x07) {
                term_len = 1;
                break;
            }
            if (ch == 0x1b and end + 1 < data.len) {
                const next_ch = data[end + 1];
                if (next_ch == '\\') {
                    term_len = 2;
                    break;
                }
                if (next_ch == ']') break; // next OSC — current is partial
            }
        }
        if (term_len == 0) {
            // Partial — skip past the introducer and resume.  If
            // nothing matched, the next `indexOfPos` terminates.
            pos = if (end > start) end else payload_start;
            continue;
        }
        if (end > payload_start) {
            _ = env.f("ghostel--osc51-eval", .{data[payload_start..end]});
        }
        pos = end + term_len;
    }
}

// ---------------------------------------------------------------------------
// Exported Elisp functions — GhostelTerm operations
// ---------------------------------------------------------------------------

pub const emacs_functions = [_]emacs.FunctionEntry{
    .{
        .name = "ghostel--new",
        .arity = .{ 2, 5 },
        .doc =
        \\Create a new ghostel terminal.
        \\
        \\(ghostel--new ROWS COLS &optional MAX-SCROLLBACK KITTY-STORAGE-LIMIT KITTY-MEDIUMS)
        \\
        \\KITTY-STORAGE-LIMIT is the kitty graphics image storage cap in bytes (default 320 MiB);
        \\0 disables kitty graphics entirely.
        \\KITTY-MEDIUMS is a bitfield: bit 0 = file medium, bit 1 = temp-file medium,
        \\bit 2 = shared-memory medium (default 0 = direct only).
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, nargs: isize, args: [*c]emacs.Value) emacs.Value {
                // Reject out-of-range row/col counts rather than wrapping/panicking.
                const rows = std.math.cast(u16, env.extractInteger(args[0])) orelse {
                    env.signalError("rows out of range", .{});
                    return env.nil();
                };
                const cols = std.math.cast(u16, env.extractInteger(args[1])) orelse {
                    env.signalError("cols out of range", .{});
                    return env.nil();
                };
                const max_scrollback: usize = if (nargs > 2 and env.isNotNil(args[2]))
                    (std.math.cast(usize, env.extractInteger(args[2])) orelse {
                        env.signalError("max-scrollback out of range", .{});
                        return env.nil();
                    })
                else
                    5 * 1024 * 1024; // ~5 MB, roughly 5k rows on an 80-column terminal
                // Default 320 MiB; explicit 0 disables kitty graphics entirely
                // (skips the storage allocation in libghostty's screen state).
                const kitty_storage_limit: usize = if (nargs > 3 and env.isNotNil(args[3]))
                    (std.math.cast(usize, env.extractInteger(args[3])) orelse {
                        env.signalError("kitty-storage-limit out of range", .{});
                        return env.nil();
                    })
                else
                    320 * 1024 * 1024;
                // Bit 0 = file medium, bit 1 = temp_file, bit 2 = shared_mem.
                // Default 0 — only the direct medium (base64 inline) is enabled.
                // The other mediums let a remote program instruct ghostel to read
                // arbitrary local files / SHM regions, so opt-in only.
                const kitty_mediums: u32 = if (nargs > 4 and env.isNotNil(args[4]))
                    (std.math.cast(u32, env.extractInteger(args[4])) orelse 0)
                else
                    0;
                var effects: gt.TerminalStream.Handler.Effects = .readonly;
                effects.write_pty = &writePtyCallback;
                effects.bell = &bellCallback;
                effects.device_attributes = &deviceAttributesCallback;
                effects.title_changed = &titleChangedCallback;
                effects.size = &sizeCallback;
                const term = init(module_alloc, cols, rows, max_scrollback, effects) catch {
                    env.signalError("failed to create terminal", .{});
                    return env.nil();
                };
                // Set default colors (light gray on black)
                term.setColorForeground(.{ .r = 204, .g = 204, .b = 204 });
                term.setColorBackground(.{ .r = 0, .g = 0, .b = 0 });
                // Enable kitty graphics protocol if storage limit > 0.
                if (kitty_storage_limit > 0) {
                    term.enableKittyGraphics(
                        kitty_storage_limit,
                        (kitty_mediums & 0x1) != 0,
                        (kitty_mediums & 0x2) != 0,
                        (kitty_mediums & 0x4) != 0,
                    ) catch |err|
                        env.logError("enableKittyGraphics failed: %s", .{@errorName(err)});
                }
                return env.makeUserPtr(terminalFinalize, term);
            }
        },
    },
    .{
        .name = "ghostel--write-input",
        .arity = .{ 2, 2 },
        .doc =
        \\Write raw bytes to the terminal.
        \\
        \\(ghostel--write-input TERM DATA)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse {
                    env.signalError("invalid terminal handle", .{});
                    return env.nil();
                };
                // Extract string data — try stack buffer first, fall back to alloc
                var stack_buf: [65536]u8 = undefined;
                var heap_buf: ?[]const u8 = null;
                defer if (heap_buf) |hb| module_alloc.free(hb);
                const data = env.extractString(args[1], &stack_buf) orelse blk: {
                    heap_buf = env.extractStringAlloc(args[1], module_alloc);
                    break :blk heap_buf;
                };
                if (data == null) {
                    return env.nil();
                }
                const raw = data.?;
                if (term.terminal.screens.active_key == .alternate) {
                    term.vtWrite(raw);
                    if (raw.len > 0) term.last_input_was_cr = raw[raw.len - 1] == '\r';
                } else {
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
                }
                dispatchOsc51(env, raw);
                return env.nil();
            }
        },
    },
    .{
        .name = "ghostel--set-size",
        .arity = .{ 3, 5 },
        .doc =
        \\Resize the terminal.
        \\
        \\(ghostel--set-size TERM ROWS COLS &optional CELL-W CELL-H)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, nargs: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse {
                    env.signalError("invalid terminal handle", .{});
                    return env.nil();
                };
                const rows = std.math.cast(u16, env.extractInteger(args[1])) orelse {
                    env.signalError("rows out of range", .{});
                    return env.nil();
                };
                const cols = std.math.cast(u16, env.extractInteger(args[2])) orelse {
                    env.signalError("cols out of range", .{});
                    return env.nil();
                };
                // Clamp cell dimensions to at least 1.  A zero (or negative,
                // pre-cast) value would propagate into the OPT_SIZE answer, and
                // some apps treat zero cell sizes as "kitty graphics not
                // supported" and fall back to half-block rendering.
                const cell_w: u32 = if (nargs > 3 and env.isNotNil(args[3])) blk: {
                    const raw = env.extractInteger(args[3]);
                    if (raw < 1) break :blk 1;
                    break :blk std.math.cast(u32, raw) orelse 1;
                } else 1;
                const cell_h: u32 = if (nargs > 4 and env.isNotNil(args[4])) blk: {
                    const raw = env.extractInteger(args[4]);
                    if (raw < 1) break :blk 1;
                    break :blk std.math.cast(u32, raw) orelse 1;
                } else 1;
                term.resize(cols, rows, cell_w, cell_h);
                return env.nil();
            }
        },
    },
    .{
        .name = "ghostel--get-title",
        .arity = .{ 1, 1 },
        .doc =
        \\Get the terminal title.
        \\
        \\(ghostel--get-title TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                const title = term.terminal.getTitle();
                return if (title) |t| env.makeString(t) else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--get-pwd",
        .arity = .{ 1, 1 },
        .doc =
        \\Get the terminal's working directory from OSC 7.
        \\
        \\(ghostel--get-pwd TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                const pwd = term.terminal.getPwd();
                return if (pwd) |p| env.makeString(p) else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--redraw",
        .arity = .{ 1, 2 },
        .doc =
        \\Redraw the terminal into the current buffer.
        \\
        \\(ghostel--redraw TERM &optional FULL)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, nargs: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                const force_full = nargs > 1 and env.isNotNil(args[1]);
                term.renderer.redraw(term.alloc, env, force_full) catch |err| {
                    env.logStackTrace(@errorReturnTrace());
                    env.signalError("Redraw failed: %s", .{@errorName(err)});
                    return env.nil();
                };
                // Kitty placement queries report `viewport_row' relative to the current
                // viewport position.  `render()' scrolls the viewport to intermediate
                // page positions during rendering; reset it to the active area so
                // placement row offsets are computed correctly.
                term.terminal.scrollViewport(.bottom);
                // Clear viewport-region kitty overlays after redraw so the cleared
                // region boundary is computed against the updated `rows_in_buffer'
                // (which reflects any scrollback evicted during this redraw).
                // Running kitty-clear before redraw would use the stale value and
                // compute the wrong absolute row for the overlay boundary.
                _ = env.f("ghostel--kitty-clear", .{});
                kitty_graphics.emitPlacements(env, term) catch |err| {
                    env.logStackTrace(@errorReturnTrace());
                    env.logError("emitPlacements failed: %s", .{@errorName(err)});
                };
                return env.nil();
            }
        },
    },
    .{
        .name = "ghostel--encode-key",
        .arity = .{ 3, 4 },
        .doc =
        \\Encode a key event using the terminal's key encoder.
        \\
        \\(ghostel--encode-key TERM KEY MODS &optional UTF8)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, nargs: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                var key_buf: [64]u8 = undefined;
                const key_name = env.extractString(args[1], &key_buf) orelse return env.nil();
                var mod_buf: [64]u8 = undefined;
                const mod_str = env.extractString(args[2], &mod_buf) orelse "";
                var utf8_buf: [32]u8 = undefined;
                const utf8: ?[]const u8 = if (nargs > 3 and env.isNotNil(args[3]))
                    env.extractString(args[3], &utf8_buf)
                else
                    null;
                const key = input.mapKey(key_name);
                const mods = input.parseMods(mod_str);
                const sent = input.encodeAndSend(env, term, key, mods, utf8) catch |err| {
                    env.logStackTrace(@errorReturnTrace());
                    env.signalError("encodeAndSend failed: %s", .{@errorName(err)});
                    return env.nil();
                };
                return if (sent) env.t() else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--mouse-event",
        .arity = .{ 6, 6 },
        .doc =
        \\Send a mouse event to the terminal.
        \\
        \\(ghostel--mouse-event TERM ACTION BUTTON ROW COL MODS)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                const action = env.extractInteger(args[1]);
                const button = env.extractInteger(args[2]);
                const row = env.extractInteger(args[3]);
                const col = env.extractInteger(args[4]);
                const mods = env.extractInteger(args[5]);
                const sent = input.encodeAndSendMouse(env, term, action, button, row, col, mods) catch |err| {
                    env.logStackTrace(@errorReturnTrace());
                    env.signalError("encodeAndSendMouse failed: %s", .{@errorName(err)});
                    return env.nil();
                };
                return if (sent) env.t() else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--focus-event",
        .arity = .{ 2, 2 },
        .doc =
        \\Send a focus event to the terminal.
        \\
        \\(ghostel--focus-event TERM GAINED)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                if (!term.terminal.modes.get(gt.modes.Mode.focus_event)) {
                    return env.nil();
                }
                const gained = env.isNotNil(args[1]);
                const event = if (gained) gt.input.FocusEvent.gained else gt.input.FocusEvent.lost;
                var buf: [8]u8 = undefined;
                var writer = std.io.Writer.fixed(&buf);
                gt.input.encodeFocus(&writer, event) catch return env.nil();
                const encoded = writer.buffered();
                if (encoded.len == 0) return env.nil();
                emacs.current_env = env;
                defer emacs.current_env = null;
                _ = env.f("ghostel--flush-output", .{encoded});
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--set-palette",
        .arity = .{ 2, 2 },
        .doc =
        \\Set the ANSI color palette.
        \\
        \\(ghostel--set-palette TERM COLORS-STRING)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse {
                    env.signalError("invalid terminal handle", .{});
                    return env.nil();
                };
                var str_buf: [2048]u8 = undefined;
                const colors_str = env.extractString(args[1], &str_buf) orelse {
                    env.signalError("invalid palette string", .{});
                    return env.nil();
                };
                var palette = term.terminal.colors.palette.current;
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
                term.setColorPalette(palette);
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--set-default-colors",
        .arity = .{ 3, 3 },
        .doc =
        \\Set default foreground and background colors.
        \\
        \\(ghostel--set-default-colors TERM FG-HEX BG-HEX)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse {
                    env.signalError("invalid terminal handle", .{});
                    return env.nil();
                };
                var fg_buf: [16]u8 = undefined;
                var bg_buf: [16]u8 = undefined;
                const fg_str = env.extractString(args[1], &fg_buf) orelse {
                    env.signalError("invalid foreground color", .{});
                    return env.nil();
                };
                const bg_str = env.extractString(args[2], &bg_buf) orelse {
                    env.signalError("invalid background color", .{});
                    return env.nil();
                };
                const fg = parseHexColor(fg_str) orelse {
                    env.signalError("cannot parse foreground color", .{});
                    return env.nil();
                };
                const bg = parseHexColor(bg_str) orelse {
                    env.signalError("cannot parse background color", .{});
                    return env.nil();
                };
                term.setColorForeground(fg);
                term.setColorBackground(bg);
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--set-bold-config",
        .arity = .{ 2, 2 },
        .doc =
        \\Configure bold text coloring.
        \\
        \\CONFIG can be nil (none), 'bright, or a hex color string.
        \\
        \\(ghostel--set-bold-config TERM CONFIG)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                const val = args[1];
                if (env.isNil(val)) {
                    term.renderer.bold_config = null;
                } else if (env.eq(val, emacs.sym.bright)) {
                    term.renderer.bold_config = .bright;
                } else {
                    var hex_buf: [16]u8 = undefined;
                    const hex = env.extractString(val, &hex_buf) orelse {
                        env.signalError("invalid bold config value", .{});
                        return env.nil();
                    };
                    if (parseHexColor(hex)) |color| {
                        term.renderer.bold_config = .{ .color = color };
                    } else {
                        env.signalError("invalid bold color: %s", .{hex});
                        return env.nil();
                    }
                }
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--mode-enabled",
        .arity = .{ 2, 2 },
        .doc =
        \\Return t if terminal DEC private MODE is enabled.
        \\
        \\(ghostel--mode-enabled TERM MODE)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                const raw_int = env.extractInteger(args[1]);
                const mode_int = std.math.cast(u16, raw_int) orelse {
                    env.signalError("invalid mode value: %d", .{raw_int});
                    return env.nil();
                };
                const mode = std.meta.intToEnum(gt.modes.Mode, mode_int) catch {
                    env.signalError("invalid mode value: %d", .{raw_int});
                    return env.nil();
                };
                return if (term.terminal.modes.get(mode)) env.t() else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--alt-screen-p",
        .arity = .{ 1, 1 },
        .doc =
        \\Return t if terminal is on the alternate screen buffer.
        \\
        \\(ghostel--alt-screen-p TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                return if (term.terminal.screens.active_key == .alternate) env.t() else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--copy-all-text",
        .arity = .{ 1, 1 },
        .doc =
        \\Return entire scrollback as plain text string.
        \\
        \\(ghostel--copy-all-text TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                const options = gt.formatter.Options{
                    .emit = .plain,
                    .unwrap = true,
                    .trim = true,
                };
                var formatter = gt.formatter.TerminalFormatter.init(&term.terminal, options);
                var writer = std.io.Writer.Allocating.init(module_alloc);
                defer writer.deinit();
                formatter.format(&writer.writer) catch {
                    env.signalError("formatter failed", .{});
                    return env.nil();
                };
                const written = writer.written();
                if (written.len == 0) return env.nil();
                return env.makeString(written);
            }
        },
    },
    .{
        .name = "ghostel--native-uri-at",
        .arity = .{ 3, 3 },
        .doc =
        \\Get URI at ROW-from-bottom and COL.
        \\
        \\(ghostel--native-uri-at TERM ROW COL)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                const row_from_bottom = env.extractInteger(args[1]);
                const col = env.extractInteger(args[2]);
                const total_rows = term.terminal.screens.active.pages.total_rows;
                if (col < 0 or col >= term.terminal.cols) return env.nil();
                // The Emacs buffer always carries a trailing newline, so the line
                // immediately after the last content row produces row_from_bottom == 0.
                if (row_from_bottom <= 0 or row_from_bottom > total_rows) return env.nil();
                const row = total_rows - @as(usize, @intCast(row_from_bottom));
                const point = gt.Point{ .screen = .{
                    .x = @intCast(col),
                    .y = @intCast(row),
                } };
                const pin = term.terminal.screens.active.pages.pin(point) orelse return env.nil();
                const cell = pin.rowAndCell().cell;
                if (!cell.hyperlink) {
                    return env.nil();
                }
                const link_id = pin.node.data.lookupHyperlink(cell) orelse return env.nil();
                const entry = pin.node.data.hyperlink_set.get(pin.node.data.memory, link_id);
                const uri = entry.uri.slice(pin.node.data.memory);
                return env.makeString(uri);
            }
        },
    },
};
