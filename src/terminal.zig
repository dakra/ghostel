/// Terminal state management wrapping libghostty-vt.
///
/// Holds the resources for a single instance of a Ghostel terminal
///
const std = @import("std");

const emacs = @import("emacs.zig");
const gt = @import("ghostty.zig");
const Renderer = @import("Renderer.zig");

const Self = @This();

/// The libghostty terminal handle.
terminal: gt.Terminal,

/// Key encoder for translating key events to escape sequences.
key_encoder: gt.c.GhosttyKeyEncoder,

/// Mouse encoder for translating mouse events to escape sequences.
mouse_encoder: gt.c.GhosttyMouseEncoder,

/// Cell pixel dimensions, used to answer XTWINOPS CSI 14/16/18 t
/// queries.  Updated on every resize.  Initialized to 1x1 — apps
/// querying before the first resize will get a degenerate answer
/// rather than zero (which some apps treat as "no support").
cell_width_px: u32 = 1,
cell_height_px: u32 = 1,

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

/// Cached Emacs env pointer — only valid during a callback from Emacs.
env: ?emacs.Env = null,

/// Create a new terminal with the given dimensions and scrollback.
pub fn init(cols: u16, rows: u16, max_scrollback: usize) !Self {
    var terminal: gt.Terminal = undefined;
    const opts = gt.TerminalOptions{
        .cols = cols,
        .rows = rows,
        .max_scrollback = max_scrollback,
    };

    if (gt.c.ghostty_terminal_new(null, &terminal, opts) != gt.SUCCESS) {
        return error.TerminalCreateFailed;
    }
    errdefer gt.c.ghostty_terminal_free(terminal);

    var key_encoder: gt.c.GhosttyKeyEncoder = undefined;
    if (gt.c.ghostty_key_encoder_new(null, &key_encoder) != gt.SUCCESS) {
        return error.KeyEncoderCreateFailed;
    }
    errdefer gt.c.ghostty_key_encoder_free(key_encoder);

    var mouse_encoder: gt.c.GhosttyMouseEncoder = undefined;
    if (gt.c.ghostty_mouse_encoder_new(null, &mouse_encoder) != gt.SUCCESS) {
        return error.MouseEncoderCreateFailed;
    }
    errdefer gt.c.ghostty_mouse_encoder_free(mouse_encoder);

    // Enable grapheme clustering since that is how Emacs will render it anyway
    const mode_grapheme = gt.c.ghostty_mode_new(@as(c_int, 2027), false);
    if (gt.c.ghostty_terminal_mode_set(terminal, mode_grapheme, true) != gt.SUCCESS) {
        return error.EnableGraphemeClusteringFailed;
    }

    return .{
        .terminal = terminal,
        .key_encoder = key_encoder,
        .mouse_encoder = mouse_encoder,
        .renderer = try .init(cols, rows),
    };
}

/// Free all ghostty resources.
pub fn deinit(self: *Self) void {
    self.renderer.deinit();
    gt.c.ghostty_mouse_encoder_free(self.mouse_encoder);
    gt.c.ghostty_key_encoder_free(self.key_encoder);
    gt.c.ghostty_terminal_free(self.terminal);
}

/// Helper to call ghostty_terminal_set and check the return code.
fn terminalSet(self: *Self, opt: gt.c.GhosttyTerminalOption, value: ?*const anyopaque) !void {
    if (gt.c.ghostty_terminal_set(self.terminal, opt, value) != gt.SUCCESS) {
        return error.TerminalSetFailed;
    }
}

/// Register the userdata pointer for callbacks.
pub fn setUserdata(self: *Self, userdata: ?*anyopaque) !void {
    try self.terminalSet(gt.OPT_USERDATA, userdata);
}

/// Register the write_pty callback.
pub fn setWritePty(self: *Self, cb: gt.WritePtyFn) !void {
    try self.terminalSet(gt.OPT_WRITE_PTY, @ptrCast(cb));
}

/// Register the bell callback.
pub fn setBell(self: *Self, cb: gt.BellFn) !void {
    try self.terminalSet(gt.OPT_BELL, @ptrCast(cb));
}

/// Register the title_changed callback.
pub fn setTitleChanged(self: *Self, cb: gt.TitleChangedFn) !void {
    try self.terminalSet(gt.OPT_TITLE_CHANGED, @ptrCast(cb));
}

/// Register the device_attributes callback.
pub fn setDeviceAttributes(self: *Self, cb: gt.DeviceAttributesFn) !void {
    try self.terminalSet(gt.OPT_DEVICE_ATTRIBUTES, @ptrCast(cb));
}

/// Register the size-report callback (XTWINOPS CSI 14/16/18 t).
pub fn setSize(self: *Self, cb: gt.SizeFn) !void {
    try self.terminalSet(gt.OPT_SIZE, @ptrCast(cb));
}

/// Set default foreground color.
pub fn setColorForeground(self: *Self, color: *const gt.ColorRgb) !void {
    try self.terminalSet(gt.OPT_COLOR_FOREGROUND, color);
}

/// Set default background color.
pub fn setColorBackground(self: *Self, color: *const gt.ColorRgb) !void {
    try self.terminalSet(gt.OPT_COLOR_BACKGROUND, color);
}

/// Set the color palette (256 entries).
pub fn setColorPalette(self: *Self, palette: *const [256]gt.ColorRgb) !void {
    try self.terminalSet(gt.OPT_COLOR_PALETTE, palette);
}

/// Set the terminal's working directory (from OSC 7).
pub fn setPwd(self: *Self, pwd: *const gt.GhosttyString) !void {
    try self.terminalSet(gt.OPT_PWD, pwd);
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
    const storage_limit_u64: u64 = storage_limit;
    try self.terminalSet(gt.OPT_KITTY_IMAGE_STORAGE_LIMIT, @ptrCast(&storage_limit_u64));
    try self.terminalSet(gt.OPT_KITTY_IMAGE_MEDIUM_FILE, @ptrCast(&medium_file));
    try self.terminalSet(gt.OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, @ptrCast(&medium_temp_file));
    try self.terminalSet(gt.OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, @ptrCast(&medium_shared_mem));
}

/// Get the current color palette (256 entries).
pub fn getColorPalette(self: *Self) ![256]gt.ColorRgb {
    return gt.terminal_data.get([256]gt.ColorRgb, self.terminal, gt.DATA_COLOR_PALETTE);
}

/// Get the effective foreground color (honouring any OSC 10 override).
/// Returns null if no foreground color is configured (NO_VALUE).
pub fn getColorForeground(self: *Self) !?gt.ColorRgb {
    return gt.terminal_data.getOpt(gt.ColorRgb, self.terminal, gt.DATA_COLOR_FOREGROUND);
}

/// Get the effective background color (honouring any OSC 11 override).
/// Returns null if no background color is configured (NO_VALUE).
pub fn getColorBackground(self: *Self) !?gt.ColorRgb {
    return gt.terminal_data.getOpt(gt.ColorRgb, self.terminal, gt.DATA_COLOR_BACKGROUND);
}

/// Feed VT data from the PTY into the terminal.
pub fn vtWrite(self: *Self, data: []const u8) void {
    gt.c.ghostty_terminal_vt_write(self.terminal, data.ptr, data.len);
}

/// Resize the terminal. The col/row size gets committed on next redraw in order
/// to ensure that the we fully render the very latest state in case any rows
/// get promoted to scrollback due to vertical shrinking of the viewport.
pub fn resize(self: *Self, cols: u16, rows: u16, cell_w: u32, cell_h: u32) void {
    self.renderer.resize(cols, rows);
    self.cell_width_px = cell_w;
    self.cell_height_px = cell_h;
}

/// Scroll the viewport.
pub fn scrollViewport(self: *Self, tag: c_int, delta: isize) void {
    var behavior: gt.TerminalScrollViewport = undefined;
    behavior.tag = @intCast(tag);
    behavior.value.delta = delta;
    gt.c.ghostty_terminal_scroll_viewport(self.terminal, behavior);
}

/// Get the terminal title as a borrowed string. Returns null if not set.
pub fn getTitle(self: *Self) !?[]const u8 {
    const title = try gt.terminal_data.get(gt.GhosttyString, self.terminal, gt.DATA_TITLE);
    if (title.len == 0) return null;
    return title.ptr[0..title.len];
}

/// Get the terminal's current working directory (from OSC 7). Returns null if not set.
pub fn getPwd(self: *Self) !?[]const u8 {
    const pwd = try gt.terminal_data.get(gt.GhosttyString, self.terminal, gt.DATA_PWD);
    if (pwd.len == 0) return null;
    return pwd.ptr[0..pwd.len];
}

/// Check if a terminal mode is enabled. Error.InvalidValue means unknown mode.
pub fn isModeEnabled(self: *Self, mode: gt.c.GhosttyMode) !bool {
    return gt.terminalModeGet(self.terminal, mode);
}

/// Returns true if the terminal is on the alternate screen buffer
/// (DEC private modes 1049, 1047, or legacy 47 set).  Used to decide
/// whether full-screen apps (vim, htop, less) own the viewport.
pub fn isAltScreen(self: *Self) !bool {
    return try self.isModeEnabled(@as(gt.c.GhosttyMode, 1049)) or
        try self.isModeEnabled(@as(gt.c.GhosttyMode, 1047)) or
        try self.isModeEnabled(@as(gt.c.GhosttyMode, 47));
}

/// Get the total number of rows (scrollback + active screen).
pub fn getTotalRows(self: *Self) !usize {
    return gt.terminal_data.get(usize, self.terminal, gt.DATA_TOTAL_ROWS);
}

/// Get the number of scrollback rows.
pub fn getScrollbackRows(self: *Self) !usize {
    return gt.terminal_data.get(usize, self.terminal, gt.DATA_SCROLLBACK_ROWS);
}

/// Get the scrollbar state (total, offset, len).
pub fn getScrollbar(self: *Self) !gt.TerminalScrollbar {
    return gt.terminal_data.get(gt.TerminalScrollbar, self.terminal, gt.DATA_SCROLLBAR);
}

/// Emacs finalizer — called when the user-ptr is garbage collected.
pub fn emacsFinalize(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const self: *Self = @ptrCast(@alignCast(p));
        self.deinit();
        std.heap.c_allocator.destroy(self);
    }
}
