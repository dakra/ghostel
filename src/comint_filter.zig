/// Stream filter for `comint-preoutput-filter-functions`.
///
/// Owns a libghostty `gt.Stream(Handler)` configured as a stream
/// transformer - no Terminal, no 2D grid.  Bytes go in via `feed`,
/// propertized text comes out: SGR sequences become face text
/// properties, OSC 8 hyperlinks become `mouse-face` + `help-echo`
/// (URI) + a keymap, OSC 7 PWD fires an Elisp callback, and
/// everything else (cursor movement, erases, mode sets, DCS, APC,
/// …) is silently dropped.
///
/// SGR state persists across `feed` calls so e.g. a `\e[31m` chunk
/// followed by a `red\n` chunk styles `red` correctly.
const std = @import("std");
const Allocator = std.mem.Allocator;

const gt = @import("ghostty-vt");

const emacs = @import("emacs.zig");
const style_face = @import("style_face.zig");

const Self = @This();

const log = std.log.scoped(.comint_filter);

/// One styled run within the output buffer.  Hyperlink URIs are owned
/// by the run and freed on run-list reset.
///
/// Positions are *character* offsets (codepoints), not byte offsets:
/// Emacs string positions are character-indexed for multibyte strings,
/// and `put-text-property` would error or corrupt props if given byte
/// offsets that don't fall on character boundaries.
const Run = struct {
    start: usize, // character offset in the output string
    end: usize,
    style: gt.Style,
    hyperlink: ?[]u8 = null,
};

const Handler = struct {
    alloc: Allocator,

    /// 256-color palette (initialised to libghostty's default).
    palette: gt.color.Palette = gt.color.default,

    /// Bold-as-bright remapping (matches ghostel-mode's default).
    bold_config: ?gt.Style.BoldColor = .bright,

    /// Cumulative SGR state.  Mutated by `.set_attribute`.
    style: gt.Style = .{},

    /// Current OSC 8 hyperlink URI (owned).  Null when no link is active.
    hyperlink: ?[]u8 = null,

    /// Output bytes accumulated during the current `feed` call.
    text: std.ArrayList(u8) = .empty,

    /// Character offset matching the end of `text`.  Tracked separately
    /// because multibyte codepoints occupy >1 byte but 1 char position.
    text_chars: usize = 0,

    /// Style runs accumulated during the current `feed` call.
    runs: std.ArrayList(Run) = .empty,

    /// Character offset where the pending run started.
    pending_start: usize = 0,

    /// Cached Emacs env, valid only during `feed`.  Used by `.report_pwd`.
    env: ?emacs.Env = null,

    pub fn deinit(self: *Handler) void {
        self.clearRuns();
        self.text.deinit(self.alloc);
        self.runs.deinit(self.alloc);
        if (self.hyperlink) |uri| self.alloc.free(uri);
        self.hyperlink = null;
    }

    /// Free per-run URIs and reset the runs list.
    fn clearRuns(self: *Handler) void {
        for (self.runs.items) |run| if (run.hyperlink) |link| self.alloc.free(link);
        self.runs.clearRetainingCapacity();
    }

    /// Push the pending run onto `runs` if it has content.
    ///
    /// Duplicate the active OSC 8 URI for stored runs because the active
    /// hyperlink can end before Emacs properties are applied.
    fn closePending(self: *Handler) !void {
        const here = self.text_chars;
        if (here > self.pending_start) {
            try self.runs.append(self.alloc, .{
                .start = self.pending_start,
                .end = here,
                .style = self.style,
                .hyperlink = if (self.hyperlink) |link|
                    try self.alloc.dupe(u8, link)
                else
                    null,
            });
        }
        self.pending_start = here;
    }

    fn appendCodepoint(self: *Handler, cp: u21) !void {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &buf);
        try self.text.appendSlice(self.alloc, buf[0..len]);
        self.text_chars += 1;
    }

    fn appendByte(self: *Handler, byte: u8) !void {
        try self.text.append(self.alloc, byte);
        self.text_chars += 1;
    }

    /// Apply an SGR attribute to the cumulative style.  Mirrors the
    /// subset of `Screen.setAttribute` that affects style.
    fn applyAttr(self: *Handler, attr: gt.sgr.Attribute) void {
        switch (attr) {
            .unset => self.style = .{},
            .unknown => {}, // unrecognized SGR — drop

            .bold => self.style.flags.bold = true,
            .reset_bold => {
                self.style.flags.bold = false;
                self.style.flags.faint = false;
            },

            .italic => self.style.flags.italic = true,
            .reset_italic => self.style.flags.italic = false,

            .faint => self.style.flags.faint = true,

            // SGR 24 (reset underline) parses as `underline = .none` —
            // there is no separate `reset_underline` tag in sgr.Attribute.
            .underline => |v| self.style.flags.underline = v,

            .underline_color => |rgb| self.style.underline_color = .{ .rgb = rgb },
            .@"256_underline_color" => |idx| self.style.underline_color = .{ .palette = idx },
            .reset_underline_color => self.style.underline_color = .none,

            .overline => self.style.flags.overline = true,
            .reset_overline => self.style.flags.overline = false,

            .blink => self.style.flags.blink = true,
            .reset_blink => self.style.flags.blink = false,

            .inverse => self.style.flags.inverse = true,
            .reset_inverse => self.style.flags.inverse = false,

            .invisible => self.style.flags.invisible = true,
            .reset_invisible => self.style.flags.invisible = false,

            .strikethrough => self.style.flags.strikethrough = true,
            .reset_strikethrough => self.style.flags.strikethrough = false,

            .direct_color_fg => |rgb| self.style.fg_color = .{ .rgb = rgb },
            .direct_color_bg => |rgb| self.style.bg_color = .{ .rgb = rgb },

            .@"8_fg" => |n| self.style.fg_color = .{ .palette = @intFromEnum(n) },
            .@"8_bg" => |n| self.style.bg_color = .{ .palette = @intFromEnum(n) },

            .reset_fg => self.style.fg_color = .none,
            .reset_bg => self.style.bg_color = .none,

            .@"8_bright_fg" => |n| self.style.fg_color = .{ .palette = @intFromEnum(n) },
            .@"8_bright_bg" => |n| self.style.bg_color = .{ .palette = @intFromEnum(n) },

            .@"256_fg" => |idx| self.style.fg_color = .{ .palette = idx },
            .@"256_bg" => |idx| self.style.bg_color = .{ .palette = idx },
        }
    }

    /// Stream-handler entry point.  Dispatched at comptime so unhandled
    /// arms compile to no-ops.
    ///
    /// `value` is typed per comptime branch via `Value(action)`; the
    /// `|capture|` form on a tag-enum switch would only re-bind the tag
    /// itself, not the union payload — so we read `value` directly.
    pub fn vt(
        self: *Handler,
        comptime action: gt.StreamAction.Tag,
        value: gt.StreamAction.Value(action),
    ) void {
        switch (action) {
            .print => self.appendCodepoint(value.cp) catch |err| {
                log.warn("appendCodepoint failed: {s}", .{@errorName(err)});
            },
            .print_slice => {
                for (value.cps) |cp| {
                    self.appendCodepoint(@intCast(cp)) catch |err| {
                        log.warn("appendCodepoint failed: {s}", .{@errorName(err)});
                        return;
                    };
                }
            },

            // C0 controls — pass through so comint's carriage-motion
            // filter can interpret them.
            .linefeed => self.appendByte('\n') catch |err| {
                log.warn("LF passthrough failed: {s}", .{@errorName(err)});
            },
            .carriage_return => self.appendByte('\r') catch |err| {
                log.warn("CR passthrough failed: {s}", .{@errorName(err)});
            },
            .backspace => self.appendByte(0x08) catch |err| {
                log.warn("BS passthrough failed: {s}", .{@errorName(err)});
            },
            .horizontal_tab => self.appendByte('\t') catch |err| {
                log.warn("TAB passthrough failed: {s}", .{@errorName(err)});
            },
            .bell => self.appendByte(0x07) catch |err| {
                log.warn("BEL passthrough failed: {s}", .{@errorName(err)});
            },

            .set_attribute => {
                self.closePending() catch |err| {
                    log.warn("closePending before start_hyperlink failed: {s}", .{@errorName(err)});
                    return;
                };
                self.applyAttr(value);
            },

            .start_hyperlink => {
                self.closePending() catch |err| {
                    log.warn("closePending before start_hyperlink failed: {s}", .{@errorName(err)});
                    return;
                };
                if (self.hyperlink) |old| self.alloc.free(old);
                self.hyperlink = self.alloc.dupe(u8, value.uri) catch |err| blk: {
                    log.warn("start_hyperlink dupe failed: {s}", .{@errorName(err)});
                    break :blk null;
                };
            },
            .end_hyperlink => {
                self.closePending() catch |err| {
                    log.warn("closePending before end_hyperlink failed: {s}", .{@errorName(err)});
                    return;
                };
                if (self.hyperlink) |old| self.alloc.free(old);
                self.hyperlink = null;
            },

            .report_pwd => {
                const e = self.env orelse return;
                _ = e.f("ghostel-comint--update-dir", .{value.url});
                if (e.nonLocalExitCheck() != .normal) {
                    e.nonLocalExitClear();
                    log.warn("ghostel-comint--update-dir signaled — exit cleared", .{});
                }
            },

            else => {},
        }
    }
};

alloc: Allocator,
stream: gt.Stream(Handler),
buffer: ?[]u8 = null,

pub fn create(alloc: Allocator) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .stream = .initAlloc(alloc, .{ .alloc = alloc }),
    };
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.buffer) |buf| self.alloc.free(buf);
    self.stream.deinit();
    self.alloc.destroy(self);
}

/// Override the 16-color palette (indices 0-15).  Higher palette
/// entries are untouched.  Mirrors `ghostel--set-palette`.
pub fn setPalette16(self: *Self, palette16: [16]gt.color.RGB) void {
    for (palette16, 0..) |col, i| self.stream.handler.palette[i] = col;
}

/// Feed bytes; return a propertized Emacs string of everything emitted
/// during this call.  Persistent style state survives across calls.
pub fn feed(self: *Self, env: emacs.Env, data: []const u8) !emacs.Value {
    var h = &self.stream.handler;

    h.text.clearRetainingCapacity();
    h.text_chars = 0;
    h.clearRuns();
    h.pending_start = 0;

    h.env = env;
    defer h.env = null;

    self.stream.nextSlice(data);
    try h.closePending();

    const text_val = env.makeString(h.text.items);
    const s = &emacs.sym;

    for (h.runs.items) |*run| {
        const start_val = env.makeInteger(@intCast(run.start));
        const end_val = env.makeInteger(@intCast(run.end));

        const face = try style_face.buildFacePlist(env, &run.style, &h.palette, h.bold_config);
        if (face) |f| {
            _ = env.f("put-text-property", .{
                start_val,
                end_val,
                s.face,
                f,
                text_val,
            });
        }

        if (run.hyperlink) |link| {
            const uri_val = env.makeString(link);
            _ = env.f("put-text-property", .{
                start_val,
                end_val,
                s.@"help-echo",
                uri_val,
                text_val,
            });
            _ = env.f("put-text-property", .{
                start_val,
                end_val,
                s.@"mouse-face",
                s.highlight,
                text_val,
            });
            _ = env.f("put-text-property", .{
                start_val,
                end_val,
                s.keymap,
                env.symbolValue("ghostel-link-map"),
                text_val,
            });
        }
    }

    return text_val;
}

var module_alloc: Allocator = undefined;

pub fn initModule(allocator: Allocator, env: emacs.Env) void {
    module_alloc = allocator;
    env.registerFunctions(&emacs_functions);
}

// ---------------------------------------------------------------------------
// Comint stream filter — no Terminal, just gt.Stream(Handler) for
// `comint-preoutput-filter-functions' integration.
// ---------------------------------------------------------------------------

fn comintFinalize(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const filter: *Self = @ptrCast(@alignCast(p));
        filter.deinit();
    }
}

pub const emacs_functions = [_]emacs.FunctionEntry{
    .{
        .name = "ghostel--comint-make-state",
        .arity = .{ 0, 0 },
        .doc =
        \\Allocate a comint stream-filter state.
        \\
        \\Returns an opaque handle; pass it to `ghostel--comint-filter' to
        \\process bytes.  Freed automatically by the Emacs GC.
        \\
        \\(ghostel--comint-make-state)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, _: [*c]emacs.Value) !emacs.Value {
                const filter = try Self.create(module_alloc);
                return env.makeUserPtr(comintFinalize, filter);
            }
        },
    },
    .{
        .name = "ghostel--comint-filter",
        .arity = .{ 2, 2 },
        .doc =
        \\Feed bytes to a comint stream filter, returning propertized text.
        \\
        \\STATE must be a handle returned by `ghostel--comint-make-state'.
        \\DATA is a string of raw bytes (a chunk of process output).
        \\
        \\Returns a string with face / mouse-face / help-echo properties
        \\applied.  SGR state persists across calls.
        \\
        \\(ghostel--comint-filter STATE DATA)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const filter = env.getUserPtr(Self, args[0]) orelse return error.InvalidComintFilter;
                const data = try env.extractStringAlloc(module_alloc, args[1], &filter.buffer);
                return try filter.feed(env, data);
            }
        },
    },
    .{
        .name = "ghostel--comint-set-palette",
        .arity = .{ 2, 2 },
        .doc =
        \\Set the 16-color ANSI palette on a comint stream filter.
        \\
        \\STATE must be a handle returned by `ghostel--comint-make-state'.
        \\COLORS-STRING is the concatenated "#RRGGBB" form used by
        \\`ghostel--set-palette'.
        \\
        \\(ghostel--comint-set-palette STATE COLORS-STRING)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const filter = env.getUserPtr(Self, args[0]) orelse return error.InvalidComintFilter;
                var str_buf: [2048]u8 = undefined;
                const colors_str = try env.extractString(args[1], &str_buf);
                if (colors_str.len < 16 * 7) return error.InvalidPaletteLength;
                var palette16: [16]gt.color.RGB = @splat(.{});
                var idx: usize = 0;
                while (idx < 16) : (idx += 1) {
                    const pos = idx * 7;
                    palette16[idx] = try gt.color.RGB.parse(colors_str[pos .. pos + 7]);
                }
                filter.setPalette16(palette16);
                return env.t();
            }
        },
    },
};
