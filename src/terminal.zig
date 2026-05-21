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

/// Cached Emacs env pointer — only valid during a callback from Emacs.
env: ?emacs.Env = null,

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

/// Emacs finalizer — called when the user-ptr is garbage collected.
pub fn emacsFinalize(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const self: *Self = @ptrCast(@alignCast(p));
        self.deinit();
    }
}
