/// Terminal state management wrapping libghostty-vt.
///
/// Holds the resources for one Ghostel terminal, including rendering state
/// and, for native PTY sessions, the process reader.
const std = @import("std");
const Allocator = std.mem.Allocator;

const emacs = @import("emacs.zig");
const gt = @import("ghostty-vt");
const GhostelHandler = @import("handler.zig").GhostelHandler;
const Renderer = @import("Renderer.zig");
const input = @import("input.zig");
const kitty_graphics = @import("kitty_graphics.zig");
const utils = @import("utils.zig");
const parseHexColor = utils.parseHexColor;
const NativeProcess = @import("NativeProcess.zig");
const ChannelFd = NativeProcess.ChannelFd;
const ProcessParams = NativeProcess.ProcessParams;
const ProcessPid = i64;
const pty_utils = @import("pty_utils.zig");

const Self = @This();

alloc: Allocator,
terminal: gt.Terminal,
stream: gt.Stream(GhostelHandler(*Self)),
string_buffer: ?[]u8 = null,
renderer: Renderer,
process: ?*NativeProcess = null,

/// Create a new terminal with the given dimensions and scrollback.
pub fn init(alloc: Allocator, env: emacs.Env, cols: u16, rows: u16, max_scrollback: usize) !*Self {
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

    term.stream = .initAlloc(alloc, .init(term, &term.terminal));
    errdefer term.stream.deinit();

    term.renderer = try .init(alloc, env, &term.terminal);

    return term;
}

/// Free all ghostty resources.
pub fn deinit(self: *Self) void {
    if (self.process) |process| {
        process.deinit();
        self.alloc.destroy(process);
    }

    self.renderer.deinit();
    self.stream.deinit();
    self.terminal.deinit(self.alloc);
    if (self.string_buffer) |buf| self.alloc.free(buf);
    self.alloc.destroy(self);
}

pub fn redraw(self: *Self, force_full: bool, force_sync: bool) !bool {
    self.lockTerm();
    defer self.unlockTerm();

    const env = emacs.current_env orelse return false;
    const pre_size = .{ self.terminal.cols, self.terminal.rows };
    if (!try self.renderer.redraw(env, force_full, force_sync)) return false;

    _ = env.f("ghostel--kitty-clear", .{});
    try kitty_graphics.emitPlacements(env, self);
    const post_size = .{ self.terminal.cols, self.terminal.rows };

    if (self.isProcessLive() and !std.meta.eql(pre_size, post_size)) {
        if (self.process) |proc| {
            try proc.resizePty(post_size[0], post_size[1]);
        } else {
            _ = env.f(
                "set-process-window-size",
                .{ env.symbolValue("ghostel--process"), post_size[1], post_size[0] },
            );
        }
    }
    return true;
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

pub fn vtWrite(self: *Self, data: []const u8) void {
    self.lockTerm();
    self.stream.nextSlice(data);
    self.unlockTerm();
}

pub fn ptyWrite(self: *Self, data: []const u8) !void {
    if (!self.isProcessLive()) return;

    const env = emacs.current_env orelse return error.MissingEmacsEnv;
    if (self.process) |proc| {
        try proc.ptyWrite(env, data);
    } else {
        _ = env.f(
            "process-send-string",
            .{ env.symbolValue("ghostel--process"), data },
        );
    }
}

pub fn ptyWriteFromTerminal(_: *Self, data: []const u8) void {
    if (emacs.current_env) |env| {
        _ = env.f(
            "process-send-string",
            .{ env.symbolValue("ghostel--process"), data },
        );
    }
}

pub fn effect(_: *Self, comptime func: []const u8, args: anytype) void {
    if (emacs.current_env) |env| {
        _ = env.f(
            "ghostel--defer",
            &(env.makeValues(.{@field(emacs.sym, func)}) ++ env.makeValues(args)),
        );
    }
}

pub fn encode(
    self: *Self,
    buf: []u8,
    key: gt.input.Key,
    mods: gt.input.KeyMods,
    utf8: ?[]const u8,
) !?[]const u8 {
    const options = gt.input.KeyEncodeOptions.fromTerminal(&self.terminal);
    var event = gt.input.KeyEvent{ .action = .press, .key = key, .mods = mods };
    if (utf8) |text| {
        event.utf8 = text;
    }

    // Encode
    var writer = std.io.Writer.fixed(buf);
    try gt.input.encodeKey(&writer, event, options);
    const encoded = writer.buffered();

    if (encoded.len == 0) return null;
    try self.ptyWrite(encoded);
    return encoded;
}

pub fn encodeMouse(
    self: *Self,
    action: i64,
    button: i64,
    row: i64,
    col: i64,
    mods_val: i64,
) !bool {
    const options = gt.input.MouseEncodeOptions.fromTerminal(&self.terminal, .{
        .screen = .{
            .width = self.terminal.cols,
            .height = self.terminal.rows,
        },
        .cell = .{ .width = 1, .height = 1 },
        .padding = .{ .top = 0, .bottom = 0, .right = 0, .left = 0 },
    });

    const event = gt.input.MouseEncodeEvent{
        .action = @enumFromInt(action),
        .button = @enumFromInt(button),
        .mods = @bitCast(@as(i16, @truncate(mods_val))),
        .pos = .{ .x = @floatFromInt(col), .y = @floatFromInt(row) },
    };

    // Encode
    var buf: [128]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    try gt.input.encodeMouse(&writer, event, options);
    const encoded = writer.buffered();

    if (encoded.len == 0) return false;
    try self.ptyWrite(encoded);
    return true;
}

pub fn encodeFocus(self: *Self, gained: bool) !bool {
    const event = if (gained) gt.input.FocusEvent.gained else gt.input.FocusEvent.lost;
    var buf: [8]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    gt.input.encodeFocus(&writer, event) catch return false;
    const encoded = writer.buffered();
    if (encoded.len == 0) return false;
    try self.ptyWrite(encoded);
    return true;
}

pub fn encodePaste(self: *Self, data: []u8) !bool {
    const slices = gt.input.encodePaste(
        data,
        gt.input.PasteOptions.fromTerminal(&self.terminal),
    );

    var wrote = false;
    for (slices) |slice| {
        if (slice.len == 0) continue;
        try self.ptyWrite(slice);
        wrote = true;
    }
    return wrote;
}

/// Resize the terminal. The col/row size gets committed on next redraw in order
/// to ensure that the we fully render the very latest state in case any rows
/// get promoted to scrollback due to vertical shrinking of the viewport.
pub fn resize(self: *Self, cols: u16, rows: u16, cell_w: u16, cell_h: u16) !void {
    self.lockTerm();
    defer self.unlockTerm();
    try self.renderer.resize(cols, rows, cell_w, cell_h);
}

pub fn lockTerm(self: *Self) void {
    if (self.process) |process| process.lockTerm();
}

pub fn unlockTerm(self: *Self) void {
    if (self.process) |handler| handler.unlockTerm();
}

pub fn spawnNativeProcess(
    self: *Self,
    command: [][:0]const u8,
    env: *const std.process.EnvMap,
    cwd: [:0]const u8,
    event_fd: ChannelFd,
) !ProcessPid {
    if (command.len == 0) return error.InvalidCommand;

    const process = try self.alloc.create(NativeProcess);
    errdefer self.alloc.destroy(process);
    try process.init(
        self.alloc,
        self.terminal.cols,
        self.terminal.rows,
        ProcessParams{ .file = command[0], .args = command, .env = env, .cwd = cwd },
        &self.terminal,
        event_fd,
    );
    self.process = process;
    return process.pidValue();
}

pub fn killNativeProcess(self: *Self) void {
    if (self.process) |process| {
        process.deinit();
        self.alloc.destroy(process);
        self.process = null;
    }
}

pub fn isProcessLive(self: *Self) bool {
    if (self.process) |process| {
        return process.isBackendAlive();
    } else if (emacs.current_env) |env| {
        return env.isNotNil(env.f("process-live-p", .{env.symbolValue("ghostel--process")}));
    }

    return false;
}

pub fn isPasswordMode(self: *Self) !bool {
    if (!self.isProcessLive()) return false;

    if (self.process) |process| {
        return pty_utils.isPasswordMode(process.replicaName());
    } else if (emacs.current_env) |env| {
        const tty_name_val = env.f(
            "process-tty-name",
            .{env.symbolValue("ghostel--process")},
        );
        if (env.isNil(tty_name_val)) return false;
        const tty_name = try env.extractStringAlloc(
            self.alloc,
            tty_name_val,
            &self.string_buffer,
        );
        return pty_utils.isPasswordMode(tty_name);
    }

    return false;
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

fn getProcessEnvironment(alloc: Allocator, env: emacs.Env) !std.process.EnvMap {
    var buf: ?[]u8 = null;
    defer if (buf) |b| alloc.free(b);

    var env_map = std.process.EnvMap.init(alloc);
    errdefer env_map.deinit();

    var display_explicit = false;
    var penv = env.f("reverse", .{env.symbolValue("process-environment")});
    while (!env.isNil(penv)) : (penv = env.f("cdr", .{penv})) {
        const item = env.f("car", .{penv});
        const str = try env.extractStringAlloc(alloc, item, &buf);
        const key, const value = if (std.mem.indexOfScalar(u8, str, '=')) |pos|
            .{ str[0..pos], str[(pos + 1)..str.len] }
        else
            .{ str, null };
        if (std.mem.eql(u8, key, "DISPLAY")) display_explicit = true;
        if (value) |v| {
            try env_map.put(key, v);
        } else {
            env_map.remove(key);
        }
    }

    if (!display_explicit and env.isNotNil(env.f("display-graphic-p", .{}))) {
        const display = env.f("getenv", .{env.makeString("DISPLAY")});
        if (env.isNotNil(display)) {
            try env_map.put("DISPLAY", try env.extractStringAlloc(alloc, display, &buf));
        }
    }

    return env_map;
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
        \\
        \\The returned handle is buffer-affine: `ghostel--new' initializes
        \\renderer-owned buffer-local state in the current buffer, and later
        \\GhostelTerm operations must be called with that same buffer current.
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, nargs: isize, args: [*c]emacs.Value) !emacs.Value {
                // Reject out-of-range row/col counts rather than wrapping/panicking.
                const rows = std.math.cast(u16, env.cast(i64, args[0])) orelse {
                    return error.OutOfRange;
                };
                const cols = std.math.cast(u16, env.cast(i64, args[1])) orelse {
                    return error.OutOfRange;
                };
                const max_scrollback: usize = if (nargs > 2 and env.isNotNil(args[2]))
                    (std.math.cast(usize, env.cast(i64, args[2])) orelse {
                        return error.OutOfRange;
                    })
                else
                    5 * 1024 * 1024; // ~5 MB, roughly 5k rows on an 80-column terminal
                // Default 320 MiB; explicit 0 disables kitty graphics entirely
                // (skips the storage allocation in libghostty's screen state).
                const kitty_storage_limit: usize = if (nargs > 3 and env.isNotNil(args[3]))
                    (std.math.cast(usize, env.cast(i64, args[3])) orelse {
                        return error.OutOfRange;
                    })
                else
                    320 * 1024 * 1024;
                // Bit 0 = file medium, bit 1 = temp_file, bit 2 = shared_mem.
                // Default 0 — only the direct medium (base64 inline) is enabled.
                // The other mediums let a remote program instruct ghostel to read
                // arbitrary local files / SHM regions, so opt-in only.
                const kitty_mediums: u32 = if (nargs > 4 and env.isNotNil(args[4]))
                    (std.math.cast(u32, env.cast(i64, args[4])) orelse 0)
                else
                    0;
                const term = try init(module_alloc, env, cols, rows, max_scrollback);
                errdefer term.deinit();
                // Seed protocol defaults for OSC 10/11.  The renderer does
                // not paint these as cell faces; default text inherits the
                // buffer's `ghostel-default' remap instead.
                term.terminal.colors.foreground.default = .{ .r = 204, .g = 204, .b = 204 };
                term.terminal.colors.background.default = .{ .r = 0, .g = 0, .b = 0 };
                // Enable kitty graphics protocol if storage limit > 0.
                if (kitty_storage_limit > 0) {
                    try term.enableKittyGraphics(
                        kitty_storage_limit,
                        (kitty_mediums & 0x1) != 0,
                        (kitty_mediums & 0x2) != 0,
                        (kitty_mediums & 0x4) != 0,
                    );
                }
                return env.makeUserPtr(terminalFinalize, term);
            }
        },
    },
    .{
        .name = "ghostel--write-vt",
        .arity = .{ 2, 2 },
        .doc =
        \\Write raw bytes to the terminal.
        \\
        \\(ghostel--write-vt TERM DATA)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const raw = try env.extractStringAlloc(module_alloc, args[1], &term.string_buffer);
                term.vtWrite(raw);
                return env.nil();
            }
        },
    },
    .{
        .name = "ghostel--write-pty",
        .arity = .{ 2, 2 },
        .doc =
        \\Write raw bytes to TERM's PTY.
        \\
        \\DATA is sent to the native PTY process when TERM owns one, or to
        \\the buffer-local Emacs process for Emacs-managed PTY sessions.
        \\
        \\(ghostel--write-pty TERM DATA)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                if (env.isNil(args[0])) return env.nil();
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const raw = try env.extractStringAlloc(module_alloc, args[1], &term.string_buffer);
                try term.ptyWrite(raw);
                return env.t();
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
            pub fn call(env: emacs.Env, nargs: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const rows = std.math.cast(u16, env.cast(i64, args[1])) orelse {
                    return error.OutOfRange;
                };
                const cols = std.math.cast(u16, env.cast(i64, args[2])) orelse {
                    return error.OutOfRange;
                };
                // Clamp cell dimensions to at least 1.  A zero (or negative,
                // pre-cast) value would propagate into the OPT_SIZE answer, and
                // some apps treat zero cell sizes as "kitty graphics not
                // supported" and fall back to half-block rendering.
                const cell_w: u16 = if (nargs > 3 and env.isNotNil(args[3])) blk: {
                    const raw = env.cast(i64, args[3]);
                    if (raw < 1) break :blk 1;
                    break :blk std.math.cast(u16, raw) orelse 1;
                } else 1;
                const cell_h: u16 = if (nargs > 4 and env.isNotNil(args[4])) blk: {
                    const raw = env.cast(i64, args[4]);
                    if (raw < 1) break :blk 1;
                    break :blk std.math.cast(u16, raw) orelse 1;
                } else 1;
                try term.resize(cols, rows, cell_w, cell_h);
                return env.nil();
            }
        },
    },
    .{
        .name = "ghostel--redraw",
        .arity = .{ 1, 3 },
        .doc =
        \\Redraw the terminal into the current buffer.
        \\
        \\(ghostel--redraw TERM &optional FULL FORCE-SYNC)
        \\
        \\Return non-nil when rendering completed.  Unless FORCE-SYNC is
        \\non-nil, return nil without rendering during synchronized output.
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, nargs: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const force_full = nargs > 1 and env.isNotNil(args[1]);
                const force_sync = nargs > 2 and env.isNotNil(args[2]);
                return env.makeValue(try term.redraw(force_full, force_sync));
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
        \\
        \\Writes the encoded bytes to the PTY and returns them as a unibyte
        \\string, or nil when the encoder produced no output.
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, nargs: isize, args: [*c]emacs.Value) !emacs.Value {
                if (env.isNil(args[0])) return env.nil();
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                var key_buf: [64]u8 = undefined;
                const key_name = env.extractString(args[1], &key_buf) catch return env.nil();
                var mod_buf: [64]u8 = undefined;
                const mod_str = env.extractString(args[2], &mod_buf) catch "";
                var utf8_buf: [32]u8 = undefined;
                const utf8: ?[]const u8 = if (nargs > 3 and env.isNotNil(args[3]))
                    env.extractString(args[3], &utf8_buf) catch null
                else
                    null;
                const key = input.mapKey(key_name);
                const mods = input.parseMods(mod_str);
                var encode_buf: [128]u8 = undefined;
                const sent = try term.encode(&encode_buf, key, mods, utf8);
                return if (sent) |bytes|
                    env.makeUnibyteString(bytes) orelse env.t()
                else
                    env.nil();
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
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                if (env.isNil(args[0])) return env.nil();
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const action = env.cast(i64, args[1]);
                const button = env.cast(i64, args[2]);
                const row = env.cast(i64, args[3]);
                const col = env.cast(i64, args[4]);
                const mods = env.cast(i64, args[5]);
                const sent = try term.encodeMouse(action, button, row, col, mods);
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
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                if (env.isNil(args[0])) return env.nil();
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                if (!term.terminal.modes.get(gt.modes.Mode.focus_event)) {
                    return env.nil();
                }
                const gained = env.isNotNil(args[1]);
                return if (try term.encodeFocus(gained)) env.t() else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--encode-paste",
        .arity = .{ 2, 2 },
        .doc =
        \\Encode paste text using the terminal's paste encoder and write it to the PTY.
        \\
        \\(ghostel--encode-paste TERM DATA)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                if (env.isNil(args[0])) return env.nil();
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const data = try env.extractStringAlloc(module_alloc, args[1], &term.string_buffer);
                return if (try term.encodePaste(data)) env.t() else env.nil();
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
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                var str_buf: [2048]u8 = undefined;
                const colors_str = try env.extractString(args[1], &str_buf);
                if (colors_str.len < 16 * 7) return error.InvalidPaletteLength;
                term.lockTerm();
                defer term.unlockTerm();
                var palette = term.terminal.colors.palette.current;
                var idx: usize = 0;
                while (idx < 16) : (idx += 1) {
                    const pos = idx * 7;
                    palette[idx] = try gt.color.RGB.parse(colors_str[pos .. pos + 7]);
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
        \\Set protocol default foreground and background colors.
        \\
        \\These defaults are used for OSC 10/11 replies and terminal dynamic
        \\color state.  The renderer intentionally does not emit them as
        \\default-cell face properties.
        \\
        \\(ghostel--set-default-colors TERM FG-HEX BG-HEX)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                var fg_buf: [16]u8 = undefined;
                var bg_buf: [16]u8 = undefined;
                const fg_str = try env.extractString(args[1], &fg_buf);
                const bg_str = try env.extractString(args[2], &bg_buf);
                term.lockTerm();
                defer term.unlockTerm();
                term.terminal.colors.foreground.default = try gt.color.RGB.parse(fg_str);
                term.terminal.colors.background.default = try gt.color.RGB.parse(bg_str);
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
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const val = args[1];
                if (env.isNil(val)) {
                    term.renderer.bold_config = null;
                } else if (env.eq(val, emacs.sym.bright)) {
                    term.renderer.bold_config = .bright;
                } else {
                    var hex_buf: [16]u8 = undefined;
                    const hex = try env.extractString(val, &hex_buf);
                    term.renderer.bold_config = .{ .color = try gt.color.RGB.parse(hex) };
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
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const raw_int = env.cast(i64, args[1]);
                const mode_int = std.math.cast(u16, raw_int) orelse {
                    return error.InvalidModeValue;
                };
                const mode = std.meta.intToEnum(gt.modes.Mode, mode_int) catch {
                    return error.InvalidModeValue;
                };
                term.lockTerm();
                defer term.unlockTerm();
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
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                term.lockTerm();
                defer term.unlockTerm();
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
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const options = gt.formatter.Options{
                    .emit = .plain,
                    .unwrap = true,
                    .trim = true,
                };
                term.lockTerm();
                defer term.unlockTerm();
                var formatter = gt.formatter.TerminalFormatter.init(&term.terminal, options);
                var writer = std.io.Writer.Allocating.init(module_alloc);
                defer writer.deinit();
                try formatter.format(&writer.writer);
                const written = writer.written();
                if (written.len == 0) return env.nil();
                return env.makeString(written);
            }
        },
    },
    .{
        .name = "ghostel--spawn-native-process",
        .arity = .{ 3, 3 },
        .doc =
        \\Spawn COMMAND for TERM using the native PTY reader.
        \\
        \\COMMAND is a list of argv strings.  PIPE is an Emacs pipe process
        \\that acts as the Emacs-side process handle.  The native reader writes
        \\Lisp event forms to it, and the native reaper writes a final numeric
        \\exit status before closing it.
        \\
        \\(ghostel--spawn-native-process TERM COMMAND PIPE)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                var cmd_list = args[1];
                const pipe_val = args[2];
                var cmd: std.ArrayList([:0]const u8) = .empty;
                defer {
                    for (cmd.items) |item| module_alloc.free(item);
                    cmd.deinit(module_alloc);
                }
                var buf: ?[]u8 = null;
                defer if (buf) |b| module_alloc.free(b);
                while (env.isNotNil(cmd_list)) : (cmd_list = env.f("cdr", .{cmd_list})) {
                    const arg = env.f("car", .{cmd_list});
                    try cmd.append(
                        module_alloc,
                        try module_alloc.dupeZ(u8, try env.extractStringAlloc(module_alloc, arg, &buf)),
                    );
                }
                var process_env = try getProcessEnvironment(module_alloc, env);
                defer process_env.deinit();
                const cwd = try module_alloc.dupeZ(u8, try env.extractStringAlloc(
                    module_alloc,
                    env.f("expand-file-name", .{env.symbolValue("default-directory")}),
                    &buf,
                ));
                defer module_alloc.free(cwd);
                const pid = try term.spawnNativeProcess(
                    cmd.items,
                    &process_env,
                    cwd,
                    env.openChannel(pipe_val),
                );
                return env.makeInteger(pid);
            }
        },
    },
    .{
        .name = "ghostel--kill-native-process",
        .arity = .{ 1, 1 },
        .doc =
        \\Stop TERM's native PTY reader without waiting for child exit.
        \\
        \\This closes the PTY and stops the reader; it does not send SIGKILL.
        \\The detached native reaper waits for the child asynchronously and
        \\signals completion through the event pipe.  No-op when TERM is not
        \\using the native PTY path.
        \\
        \\(ghostel--kill-native-process TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                term.killNativeProcess();
                return env.nil();
            }
        },
    },
    .{
        .name = "ghostel--pty-password-input-p",
        .arity = .{ 1, 1 },
        .doc =
        \\Return t when TERM's foreground PTY appears to be reading a password.
        \\
        \\This checks the active PTY's terminal attributes and returns nil when
        \\there is no live process or the PTY is not in canonical no-echo mode.
        \\
        \\(ghostel--pty-password-input-p TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                if (env.isNil(args[0])) return env.nil();
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                return if (try term.isPasswordMode()) env.t() else env.nil();
            }
        },
    },
};
