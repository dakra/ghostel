/// Terminal state management wrapping libghostty-vt.
///
/// Holds the GhosttyTerminal, RenderState, and associated iterators.
/// All ghostty resources are created and destroyed together.
const std = @import("std");
const gt = @import("ghostty.zig");
const emacs = @import("emacs.zig");

const Self = @This();

/// The libghostty terminal handle.
terminal: gt.Terminal,

/// Render state for incremental screen updates.
render_state: gt.RenderState,

/// Reusable row iterator (populated during redraw).
row_iterator: gt.RenderStateRowIterator,

/// Reusable row cells handle (populated during redraw).
row_cells: gt.RenderStateRowCells,

/// Key encoder for translating key events to escape sequences.
key_encoder: gt.c.GhosttyKeyEncoder,

/// Mouse encoder for translating mouse events to escape sequences.
mouse_encoder: gt.c.GhosttyMouseEncoder,

/// Terminal dimensions.
cols: u16,
rows: u16,

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

    var render_state: gt.RenderState = undefined;
    if (gt.c.ghostty_render_state_new(null, &render_state) != gt.SUCCESS) {
        return error.RenderStateCreateFailed;
    }
    errdefer gt.c.ghostty_render_state_free(render_state);

    var row_iterator: gt.RenderStateRowIterator = undefined;
    if (gt.c.ghostty_render_state_row_iterator_new(null, &row_iterator) != gt.SUCCESS) {
        return error.RowIteratorCreateFailed;
    }
    errdefer gt.c.ghostty_render_state_row_iterator_free(row_iterator);

    var row_cells: gt.RenderStateRowCells = undefined;
    if (gt.c.ghostty_render_state_row_cells_new(null, &row_cells) != gt.SUCCESS) {
        return error.RowCellsCreateFailed;
    }
    errdefer gt.c.ghostty_render_state_row_cells_free(row_cells);

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

    return .{
        .terminal = terminal,
        .render_state = render_state,
        .row_iterator = row_iterator,
        .row_cells = row_cells,
        .key_encoder = key_encoder,
        .mouse_encoder = mouse_encoder,
        .cols = cols,
        .rows = rows,
    };
}

/// Free all ghostty resources.
pub fn deinit(self: *Self) void {
    gt.c.ghostty_mouse_encoder_free(self.mouse_encoder);
    gt.c.ghostty_key_encoder_free(self.key_encoder);
    gt.c.ghostty_render_state_row_cells_free(self.row_cells);
    gt.c.ghostty_render_state_row_iterator_free(self.row_iterator);
    gt.c.ghostty_render_state_free(self.render_state);
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

/// Get the current color palette (256 entries).
pub fn getColorPalette(self: *Self, palette: *[256]gt.ColorRgb) bool {
    return gt.c.ghostty_terminal_get(
        self.terminal,
        gt.DATA_COLOR_PALETTE,
        @ptrCast(palette),
    ) == gt.SUCCESS;
}

/// Feed VT data from the PTY into the terminal.
pub fn vtWrite(self: *Self, data: []const u8) void {
    gt.c.ghostty_terminal_vt_write(self.terminal, data.ptr, data.len);
}

/// Resize the terminal.
pub fn resize(self: *Self, cols: u16, rows: u16) !void {
    if (gt.c.ghostty_terminal_resize(self.terminal, cols, rows, 1, 1) != gt.SUCCESS) {
        return error.ResizeFailed;
    }
    self.cols = cols;
    self.rows = rows;
}

/// Scroll the viewport.
pub fn scrollViewport(self: *Self, tag: c_int, delta: isize) void {
    var behavior: gt.TerminalScrollViewport = undefined;
    behavior.tag = @intCast(tag);
    behavior.value.delta = delta;
    gt.c.ghostty_terminal_scroll_viewport(self.terminal, behavior);
}

/// Get the terminal title as a borrowed string.
pub fn getTitle(self: *Self) ?[]const u8 {
    var title: gt.GhosttyString = undefined;
    if (gt.c.ghostty_terminal_get(self.terminal, gt.DATA_TITLE, &title) != gt.SUCCESS) {
        return null;
    }
    if (title.len == 0) return null;
    return title.ptr[0..title.len];
}

/// Get the terminal's current working directory (from OSC 7).
pub fn getPwd(self: *Self) ?[]const u8 {
    var pwd: gt.GhosttyString = undefined;
    if (gt.c.ghostty_terminal_get(self.terminal, gt.DATA_PWD, &pwd) != gt.SUCCESS) {
        return null;
    }
    if (pwd.len == 0) return null;
    return pwd.ptr[0..pwd.len];
}

/// Check if a terminal mode is enabled.
pub fn isModeEnabled(self: *Self, mode: gt.c.GhosttyMode) bool {
    var enabled: bool = false;
    if (gt.c.ghostty_terminal_mode_get(self.terminal, mode, &enabled) != gt.SUCCESS) {
        return false;
    }
    return enabled;
}

/// Emacs finalizer — called when the user-ptr is garbage collected.
pub fn emacsFinalize(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const self: *Self = @ptrCast(@alignCast(p));
        self.deinit();
        std.heap.c_allocator.destroy(self);
    }
}
