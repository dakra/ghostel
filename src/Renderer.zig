const std = @import("std");
const Allocator = std.mem.Allocator;

const builtin = @import("builtin");

const gt = @import("ghostty-vt");

const GhostelTerm = @import("GhostelTerm.zig");
const GlyphMetricsCache = @import("GlyphMetricsCache.zig");
const SavedBufferMarkers = @import("saved_markers.zig").SavedBufferMarkers;
const emacs = @import("emacs.zig");
const utils = @import("utils.zig");

const style_face = @import("style_face.zig");
pub const CellProps = style_face.CellProps;
pub const LinkId = style_face.LinkId;
pub const Hyperlink = style_face.Hyperlink;
const formatColor = style_face.formatColor;

const Self = @This();

/// Set to true while rendering is in progress
is_rendering: bool = false,

/// Allocator used by renderer-owned state.
alloc: Allocator,

/// Terminal being rendered.
term: *gt.Terminal,

/// Tracked pin of which row to render down from.
active_pin: *gt.Pin,

/// Identity of the screen currently rendered into the buffer.
rendered_screen: ScreenId,

/// Pin of the last rendered cursor position
rendered_cursor: ?gt.Pin,

/// Number of libghostty rows already materialized into the Emacs buffer.
rows_in_buffer: usize = 0,

/// List of pages materialized in buffer
pages_in_buffer: std.DoublyLinkedList = .{},

/// Any pending resize as `.{cols, rows}`. Resizes are committed on next redraw.
pending_resize: ?ViewportSize = null,

/// Accumulates adjacent dirty rows before inserting them into Emacs.
span: SpanContent,

/// Cached font metrics and rendering parameters that affect glyph layout.
/// When any field changes between redraws the viewport is fully invalidated.
font_info: ?FontInfo = null,

/// Bold text coloring configuration.
bold_config: ?gt.Style.BoldColor = null,

/// Saved positions and pins for various buffer markers. Retained between
/// rendering passes to avoid allocations.
saved_markers: SavedBufferMarkers = .{},

const PageSerial = @FieldType(gt.PageList.List.Node, "serial");

const ScreenId = struct {
    key: gt.ScreenSet.Key,
    generation: usize,
};

const MaterializedPage = struct {
    node: std.DoublyLinkedList.Node = .{},
    serial: PageSerial,
    len: usize = 0,

    pub fn next(self: *@This()) ?*@This() {
        return if (self.node.next) |n|
            @fieldParentPtr("node", n)
        else
            null;
    }
};

const FontInfo = struct {
    width: u32,
    ascent: u32,
    descent: u32,
    coverage: u32,
    glyph_scale_floor: f64,
    metrics_cache: GlyphMetricsCache = .{},

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        self.metrics_cache.deinit(alloc);
    }
};

pub fn init(alloc: Allocator, env: emacs.Env, term: *gt.Terminal) !Self {
    const s = emacs.sym;

    env.defvarLocal("ghostel--query-font-cache", env.f("make-hash-table", .{
        s.@":test",
        s.eq,
    }));
    env.defvarLocal("ghostel--rendered-font", env.nil());

    var renderer = Self{
        .alloc = alloc,
        .term = term,
        .active_pin = try term.screens.active.pages.trackPin(
            term.screens.active.pages.getTopLeft(.screen),
        ),
        .rendered_screen = currentScreenId(term),
        .rendered_cursor = null,
        .pending_resize = .{ .cols = term.cols, .rows = term.rows, .cell_w = 1, .cell_h = 1 },
        .span = .{ .alloc = alloc },
    };
    try renderer.commitResize(env);
    return renderer;
}

pub fn deinit(self: *Self) void {
    self.saved_markers.deinit(self.alloc);
    self.span.deinit();
    self.clearPages();
    self.untrackActivePinIfLive();
    if (self.font_info) |*fi| fi.deinit(self.alloc);
}

fn currentScreenId(term: *gt.Terminal) ScreenId {
    return .{
        .key = term.screens.active_key,
        .generation = term.screens.generation(term.screens.active_key),
    };
}

fn untrackActivePinIfLive(self: *Self) void {
    if (self.term.screens.generation(self.rendered_screen.key) != self.rendered_screen.generation) {
        return;
    }

    const screen = self.term.screens.get(self.rendered_screen.key) orelse return;
    screen.pages.untrackPin(self.active_pin);
}

pub fn resize(self: *Self, cols: u16, rows: u16, cell_w: u32, cell_h: u32) !void {
    if (cols == 0 or rows == 0 or cell_w == 0 or cell_h == 0) {
        return error.InvalidSize;
    }

    self.pending_resize = .{
        .cols = cols,
        .rows = rows,
        .cell_w = cell_w,
        .cell_h = cell_h,
    };
}

pub fn redraw(self: *Self, env: emacs.Env, force_full: bool) !void {
    if (self.is_rendering) return error.ReentrantRedraw;
    self.is_rendering = true;
    defer self.is_rendering = false;

    const screen = self.term.screens.active;
    try self.saved_markers.save(self.alloc, env);
    defer self.saved_markers.restoreAndClear(screen, env);

    self.gotoActiveStart(env);

    if (force_full) try self.clear(env);
    try self.updateFontInfo(env);
    try self.commitResize(env);
    if (!std.meta.eql(self.rendered_screen, currentScreenId(self.term))) {
        try self.clear(env);
    }
    try self.invalidate(env);
    self.evictScrollback(env);

    try self.render(
        env,
        if (screen.no_scrollback)
            screen.pages.getTopLeft(.active)
        else
            self.active_pin.*,
    );

    try self.renderCursor(env);

    self.active_pin.* = screen.pages.getTopLeft(.active);
    self.rows_in_buffer = if (screen.no_scrollback)
        screen.pages.rows
    else
        screen.pages.total_rows;
}

fn invalidate(self: *Self, env: emacs.Env) !void {
    const scrollback_cleared = self.rows_in_buffer > self.term.rows and
        self.active_pin.eql(self.term.screens.active.pages.getTopLeft(.screen));

    if (scrollback_cleared) {
        try self.clear(env);
    }
}

fn updateFontInfo(self: *Self, env: emacs.Env) !void {
    const new_font = getDefaultFont(env);
    const current_font = env.symbolValue("ghostel--rendered-font");

    const raw_floor = env.symbolValue("ghostel-glyph-scale-floor");
    const floor = std.math.clamp(env.asFloat(raw_floor, 0.0), 0.0, 1.0);

    // Fast path: nothing changed since last redraw.
    if (env.eq(new_font, current_font) and
        (self.font_info == null or self.font_info.?.glyph_scale_floor == floor))
    {
        return;
    }

    _ = env.set("ghostel--rendered-font", new_font);

    if (self.font_info) |*fi| {
        fi.deinit(self.alloc);
        self.font_info = null;
    }

    if (env.isNotNil(new_font)) {
        const default_font_info = self.queryFont(env, new_font);
        // The value is a vector:
        // [ NAME FILENAME PIXEL-SIZE SIZE ASCENT DESCENT SPACE-WIDTH AVERAGE-WIDTH
        //   CAPABILITY ]
        const cell_ascent = env.cast(u32, env.vecGet(default_font_info, 4));
        const cell_descent = env.cast(u32, env.vecGet(default_font_info, 5));

        self.font_info = .{
            .width = env.cast(u32, env.vecGet(default_font_info, 6)),
            .ascent = cell_ascent,
            .descent = cell_descent,
            .coverage = probeCoverage(env, new_font),
            .glyph_scale_floor = floor,
        };
    }

    try self.clear(env);
}

fn getDefaultFont(env: emacs.Env) emacs.Value {
    const s = emacs.sym;

    const probe = env.f("propertize", .{ " ", s.face, s.default });
    const remapped_font = env.f("font-at", .{ 0, env.f("selected-window", .{}), probe });
    if (env.isNotNil(env.f("fontp", .{ remapped_font, s.@"font-object" }))) {
        return remapped_font;
    }

    const font = env.f("face-attribute", .{ s.default, s.@":font" });
    if (env.isNil(env.f("fontp", .{ font, s.@"font-object" }))) return env.nil();
    return font;
}

fn queryFont(_: *Self, env: emacs.Env, font: emacs.Value) emacs.Value {
    const cache = env.symbolValue("ghostel--query-font-cache");
    const cached = env.f("gethash", .{ font, cache });
    if (env.isNotNil(cached)) return cached;

    return env.f("puthash", .{
        font,
        env.f("query-font", .{font}),
        cache,
    });
}

fn probeCoverage(env: emacs.Env, font: emacs.Value) u32 {
    const start_probe: u32 = 0xFF;
    const max_probe: u32 = 0x300;
    for (start_probe..max_probe) |x| {
        const has_char = env.isNotNil(env.f("font-has-char-p", .{ font, x }));
        if (!has_char) return @intCast(x);
    }

    return max_probe;
}

const ViewportSize = struct { cols: u16, rows: u16, cell_w: u32, cell_h: u32 };

/// Resolve a page-local hyperlink id to the URI and stable link id we store
/// on Emacs text properties. Returned slices borrow from `page` memory; callers
/// must copy them into Emacs values during the current render pass.
fn resolveHyperlink(page: *const gt.page.Page, local_id: gt.size.HyperlinkCountInt) ?Hyperlink {
    if (local_id == 0) return null;

    const entry = page.hyperlink_set.get(page.memory, local_id);
    const link_id: LinkId = switch (entry.id) {
        .explicit => |slice| .{ .explicit = slice.slice(page.memory) },
        .implicit => |v| .{ .implicit = @intCast(v) },
    };

    return .{
        .id = link_id,
        .uri = entry.uri.slice(page.memory),
    };
}

/// Apply text properties to a region of the buffer.
fn applyProps(
    self: *Self,
    env: emacs.Env,
    start: usize,
    end: usize,
    node: *const gt.PageList.List.Node,
    prop_key: *const CellPropKey,
) !void {
    if (start >= end) return;
    const s = emacs.sym;

    const start_val = env.makeValue(start);
    const end_val = env.makeValue(end);

    if (try self.getFace(env, node, prop_key)) |face| {
        _ = env.f("put-text-property", .{
            start_val,
            end_val,
            s.face,
            face,
        });
    }

    const hyperlink = resolveHyperlink(&node.data, prop_key.hyperlink_id);
    if (hyperlink) |link| {
        _ = env.f("put-text-property", .{
            start_val,
            end_val,
            s.@"help-echo",
            env.makeString(link.uri),
        });
        _ = env.f(
            "put-text-property",
            .{
                start_val,
                end_val,
                s.@"mouse-face",
                s.highlight,
            },
        );
        _ = env.f(
            "put-text-property",
            .{
                start_val,
                end_val,
                s.keymap,
                env.symbolValue("ghostel-link-map"),
            },
        );

        // Stored as a string (explicit) or integer (implicit), so elisp `equal' returns true
        // only when both kind and value match. A user-supplied explicit id like "42" never
        // collides with an implicit counter of 42.
        const id_val: emacs.Value = switch (link.id) {
            .explicit => |str| env.makeString(str),
            .implicit => |n| env.makeInteger(@intCast(n)),
        };
        _ = env.f("put-text-property", .{
            start_val,
            end_val,
            s.@"ghostel-link-id",
            id_val,
        });
    }

    switch (prop_key.semantic_content) {
        .prompt => _ = env.f("put-text-property", .{
            start_val,
            end_val,
            s.@"ghostel-prompt",
            env.t(),
        }),
        .input => _ = env.f("put-text-property", .{
            start_val,
            end_val,
            s.@"ghostel-input",
            env.t(),
        }),
        else => {},
    }
}

fn getFace(
    self: *Self,
    env: emacs.Env,
    node: *const gt.PageList.List.Node,
    key: *const CellPropKey,
) !?emacs.Value {
    return if (key.style_id != 0)
        try style_face.buildFacePlist(
            env,
            node.data.styles.get(node.data.memory, key.style_id),
            &self.term.colors.palette.current,
            self.bold_config,
        )
    else if (key.bg_color != .none)
        try style_face.buildFacePlist(
            env,
            &gt.Style{ .bg_color = key.bg_color },
            &self.term.colors.palette.current,
            self.bold_config,
        )
    else
        null;
}

// TODO: Style ID type is not exported from ghostty-vt for some reason.
//       We should file an issue.
const StyleId = @FieldType(gt.page.Cell, "style_id");

/// Compact key for deciding where Emacs text-property runs begin and end.
const CellPropKey = struct {
    style_id: StyleId,
    hyperlink_id: gt.size.HyperlinkCountInt,
    semantic_content: gt.page.Cell.SemanticContent,
    bg_color: gt.Style.Color,

    fn create(page: *const gt.Page, cell: *const gt.page.Cell) ?CellPropKey {
        const hyperlink_id = if (cell.hyperlink) page.lookupHyperlink(cell) else null;
        const bg_color: gt.Style.Color = switch (cell.content_tag) {
            .bg_color_palette => .{ .palette = cell.content.color_palette },
            .bg_color_rgb => .{ .rgb = .{
                .r = cell.content.color_rgb.r,
                .g = cell.content.color_rgb.g,
                .b = cell.content.color_rgb.b,
            } },
            else => .none,
        };

        if (cell.style_id == 0 and
            hyperlink_id == null and
            cell.semantic_content == .output and
            bg_color == .none)
        {
            return null;
        }

        return .{
            .style_id = cell.style_id,
            .hyperlink_id = hyperlink_id orelse 0,
            .semantic_content = cell.semantic_content,
            .bg_color = bg_color,
        };
    }
};

pub const SpanContent = struct {
    const Run = struct {
        start_char: usize,
        end_char: usize,
        key: ?CellPropKey,
    };

    const CellInfo = struct {
        col: usize,
        char_start: usize,
        char_end: usize,
        text_start: usize,
        text_end: usize,
        wide: bool,
        page_serial: u64,
        style_id: StyleId,

        fn precedingByte(self: *const @This(), buf: []const u8) ?u8 {
            return if (self.text_start == 0) null else buf[self.text_start - 1];
        }

        fn followingByte(self: *const @This(), buf: []const u8) ?u8 {
            // -1, excluding newline
            return if (self.text_end < buf.len - 1) buf[self.text_end] else null;
        }

        fn metricsKey(self: *const @This(), buf: []const u8) GlyphMetricsCache.Key {
            return .{
                .page_serial = self.page_serial,
                .style_id = self.style_id,
                .utf8 = .{ .borrowed = buf[self.text_start..self.text_end] },
            };
        }
    };

    alloc: Allocator,

    /// UTF-8 text for the accumulated rows.
    text: std.ArrayList(u8) = .empty,

    /// The positions of any line wraps
    line_wraps: std.ArrayList(usize) = .empty,

    /// Cells whose glyph metrics need display-property adjustment.
    adjust_cells: std.ArrayList(CellInfo) = .empty,

    /// The number of codepoints (as opposed to bytes) in the text. Emacs
    /// treats each codepoint as a separate character for buffer positions, even
    /// if it doesn't necessarily render as such.
    char_len: usize = 0,

    /// A list of continuous property runs
    runs: std.ArrayList(Run) = .empty,

    /// The character position of the cursor
    cursor_char_pos: ?usize = null,

    /// The node this span comes from
    node: ?*const gt.PageList.List.Node = null,

    pub fn addRow(
        self: *SpanContent,
        renderer: *Self,
        row_pin: gt.Pin,
        adjustment_threshold: u32,
    ) !usize {
        if (self.node) |n| std.debug.assert(n == row_pin.node);
        self.node = row_pin.node;

        const term = renderer.term;
        const screen = term.screens.active;

        const row_start = self.char_len;
        // Position at the end of the last non-blank cell; final row length
        // is trimmed back to this. Any run of blank cells past the end is
        // discarded along with their default-style trailing padding.
        var trim_byte_len: usize = self.text.items.len;
        var trim_char_len: usize = self.char_len;

        const cursor_visible = term.modes.get(.cursor_visible);
        const cursor_col = if (cursor_visible and isSameRow(row_pin, screen.cursor.page_pin.*))
            screen.cursor.page_pin.x
        else
            null;

        const page = &row_pin.node.data;
        const row = row_pin.rowAndCell().row;
        var current_prop_key: ?CellPropKey = null;
        var first_cell = true;
        for (page.getCells(row), 0..) |*cell, col| {
            const has_cursor = @as(u16, @intCast(col)) == cursor_col;
            if (has_cursor) self.cursor_char_pos = self.char_len;

            if (cell.wide == .spacer_tail or cell.wide == .spacer_head) continue;

            // We use a "key" that holds a minimum set of values that are cheap to
            // compare to detect style run breaks.
            const prop_key = CellPropKey.create(&row_pin.node.data, cell);
            if (first_cell or !std.meta.eql(prop_key, current_prop_key)) {
                try self.runs.append(self.alloc, .{
                    .start_char = self.char_len,
                    .end_char = self.char_len,
                    .key = prop_key,
                });
                current_prop_key = prop_key;
                first_cell = false;
            }

            const byte_start = self.text.items.len;
            const char_start = self.char_len;

            const codepoint: u21 = if (cell.hasText()) cell.codepoint() else ' ';
            try self.appendCodepoints(&[1]u21{codepoint});
            if (cell.hasGrapheme()) {
                try self.appendCodepoints(page.lookupGrapheme(cell).?);
            }

            // If this is a grapheme cluster, or if the char is not covered by
            // the default font, we register it as needing font glyph adjustment
            // to fit into the monospace grid.
            if (cell.hasGrapheme() or codepoint >= adjustment_threshold) {
                try self.adjust_cells.append(self.alloc, .{
                    .col = @intCast(col),
                    .char_start = @intCast(char_start),
                    .char_end = @intCast(self.char_len),
                    .text_start = byte_start,
                    .text_end = self.text.items.len,
                    .wide = cell.wide == .wide,
                    .page_serial = row_pin.node.serial,
                    .style_id = if (current_prop_key) |key| key.style_id else 0,
                });
            }

            const last_run = &self.runs.items[self.runs.items.len - 1];
            last_run.end_char = self.char_len;

            // We trim cells that neither have content nor styling. A blank
            // cursor cell only requires enough whitespace to place point at
            // the cursor column, not an extra rendered space under it.
            if (cell.hasText() or last_run.key != null) {
                trim_byte_len = self.text.items.len;
                trim_char_len = self.char_len;
            } else if (has_cursor) {
                trim_byte_len = byte_start;
                trim_char_len = char_start;
            }
        }

        // Trim trailing blank cells. Style runs extending past the trim point
        // are clipped when properties are applied.
        self.text.shrinkRetainingCapacity(trim_byte_len);
        self.char_len = trim_char_len;
        self.runs.items[self.runs.items.len - 1].end_char = trim_char_len;

        if (row.wrap) try self.line_wraps.append(self.alloc, self.char_len);
        try self.appendCodepoints(&[1]u21{'\n'});

        return self.char_len - row_start;
    }

    fn appendCodepoints(self: *SpanContent, cluster: []const u21) !void {
        for (cluster) |cp| {
            const slice = try self.text.addManyAsSlice(
                self.alloc,
                try std.unicode.utf8CodepointSequenceLength(cp),
            );
            _ = try std.unicode.utf8Encode(cp, slice);
            self.char_len += 1;
        }
    }

    pub fn clear(self: *SpanContent) !void {
        self.text.clearRetainingCapacity();
        self.line_wraps.clearRetainingCapacity();
        self.adjust_cells.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
        self.char_len = 0;
        self.cursor_char_pos = null;
        self.node = null;
    }

    pub fn deinit(self: *SpanContent) void {
        self.text.deinit(self.alloc);
        self.line_wraps.deinit(self.alloc);
        self.adjust_cells.deinit(self.alloc);
        self.runs.deinit(self.alloc);
    }
};

fn adjustGlyphs(
    self: *Self,
    env: emacs.Env,
    span_start: usize,
) !void {
    if (self.span.adjust_cells.items.len == 0) return;
    if (self.font_info == null) return;
    const window = env.f("selected-window", .{});
    if (env.isNil(window)) return;

    for (self.span.adjust_cells.items) |*cell| {
        try self.adjustGlyph(env, window, span_start, cell);
    }
}

fn adjustGlyph(
    self: *Self,
    env: emacs.Env,
    window: emacs.Value,
    span_start: usize,
    cell: *const SpanContent.CellInfo,
) !void {
    const s = emacs.sym;
    const default_font_info = self.font_info.?;

    const start_val = env.makeValue(span_start + cell.char_start);
    const end_val = env.makeValue(span_start + cell.char_end);
    const metrics = try self.getGlyphMetrics(env, window, span_start, cell) orelse return;

    // Skip adjustments if size already matches perfectly
    const native_char_width: i64 = if (cell.wide) 2 else 1;
    const native_slot_width = default_font_info.width * native_char_width;
    if (metrics.width == native_slot_width and
        metrics.ascent == default_font_info.ascent and
        metrics.descent == default_font_info.descent) return;

    const char_width = self.adjustWidth(env, span_start, cell, metrics);
    const slot_width = default_font_info.width * char_width;

    // Height is clamped per side, not on the sum: the row realizes
    // max(ascent) + max(descent) across all glyphs sharing the baseline, so a
    // glyph grows the row if either its ascent exceeds the default ascent or
    // its descent exceeds the default descent.  Scaling by the sum ratio
    // (default_height / glyph_height) can leave one side over the line — e.g. a
    // glyph that is tall above the baseline but shallow below it.  Bounding
    // each side independently is the exact clamp.
    const scale_width = @as(f64, @floatFromInt(slot_width)) /
        @as(f64, @floatFromInt(metrics.width));
    const scale_ascent = @as(f64, @floatFromInt(default_font_info.ascent)) /
        @as(f64, @floatFromInt(metrics.ascent));
    const scale_descent = @as(f64, @floatFromInt(default_font_info.descent)) /
        @as(f64, @floatFromInt(metrics.descent));
    const computed_scale = @min(scale_width, @min(scale_ascent, scale_descent));
    const scale = @max(computed_scale, default_font_info.glyph_scale_floor);

    // Display height is applied as a scale to the pixel size of the font. In
    // order to not have it be rounded up by Emacs and have the cell overflow,
    // explicitly floor it.
    const pixel_size: f64 = @floatFromInt(metrics.pixel_size);
    const quantized_scale = @floor(pixel_size * scale) / pixel_size;

    const min_width_spec = env.list(.{ s.@"min-width", env.list(.{char_width}) });
    const scale_spec = env.list(.{ s.height, quantized_scale });
    const display_spec = env.list(.{ min_width_spec, scale_spec });
    _ = env.f("put-text-property", .{
        start_val,
        end_val,
        s.display,
        display_spec,
    });
}

fn adjustWidth(
    self: *Self,
    env: emacs.Env,
    span_start: usize,
    cell: *const SpanContent.CellInfo,
    metrics: GlyphMetricsCache.Metrics,
) i64 {
    const s = emacs.sym;
    const default_font_info = self.font_info.?;

    if (cell.wide) {
        // Cell is already wide
        return 2;
    }

    // Let's check if we can claim some space after the glyph to be able to render
    // it larger than the cell size while still maintaining alignment.
    const cell_aspect = @as(f64, @floatFromInt(default_font_info.width)) /
        @as(f64, @floatFromInt(default_font_info.ascent + default_font_info.descent));
    const glyph_aspect = @as(f64, @floatFromInt(metrics.width)) /
        @as(f64, @floatFromInt(metrics.ascent + metrics.descent));

    if (glyph_aspect < cell_aspect) {
        // We don't even need more space
        return 1;
    }

    if (cell.col + 1 >= self.term.cols) {
        // Can't claim out of bounds
        return 1;
    }

    // We don't let glyphs claim space unless it truly stands alone with space
    // on both sides since otherwise it leads to visually inconsistent sizing.
    // A newline is a span-local row boundary, equivalent to no neighboring cell.
    const preceding = cell.precedingByte(self.span.text.items);
    const following = cell.followingByte(self.span.text.items);
    const empty_before = preceding == null or preceding.? == ' ' or preceding.? == '\n';
    const empty_after = following == null or following.? == ' ' or following.? == '\n';
    if (!empty_before or !empty_after) return 1;

    // We can claim the space after, but if it's a space, we must first hide it.
    if (following) |c| {
        if (c == ' ') {
            const claim_pos = span_start + cell.char_end;
            _ = env.f("put-text-property", .{
                claim_pos,
                claim_pos + 1,
                s.display,
                env.cons(s.space, env.list(.{ s.@":width", 0 })),
            });
        }
    }

    return 2;
}

fn getGlyphMetrics(
    self: *Self,
    env: emacs.Env,
    window: emacs.Value,
    span_start: usize,
    cell: *const SpanContent.CellInfo,
) !?GlyphMetricsCache.Metrics {
    const key = cell.metricsKey(self.span.text.items);
    if (self.font_info) |*fi| {
        if (fi.metrics_cache.get(key)) |metrics| return metrics;
    }

    const gstring = findGlyphString(env, window, span_start, cell) orelse {
        return null;
    };
    // gstring is:
    // [HEADER ID GLYPH ...]
    const header = env.vecGet(gstring, 0);
    const glyph = env.vecGet(gstring, 2);

    // header is:
    // [FONT-OBJECT CHAR ...]
    const font = env.vecGet(header, 0);
    const font_info = self.queryFont(env, font);

    // font_info is:
    // [ NAME FILENAME PIXEL-SIZE SIZE ASCENT DESCENT SPACE-WIDTH AVERAGE-WIDTH
    //   CAPABILITY ]
    // Keep ascent and descent separate: the line height is max(ascent) +
    // max(descent) over the row, so a glyph fits only when its ascent and
    // descent each fit the default font's — the sum is not enough.
    const pixel_size = env.cast(u16, env.vecGet(font_info, 2));
    const ascent = env.cast(u16, env.vecGet(font_info, 4));
    const descent = env.cast(u16, env.vecGet(font_info, 5));

    // Each element is a vector containing information of a glyph in this format:
    // [FROM-IDX TO-IDX C CODE WIDTH LBEARING RBEARING ASCENT DESCENT ADJUSTMENT]
    const width = env.cast(u16, env.vecGet(glyph, 4));

    const metrics = GlyphMetricsCache.Metrics{
        .width = width,
        .ascent = ascent,
        .descent = descent,
        .pixel_size = pixel_size,
    };
    if (self.font_info) |*fi| {
        try fi.metrics_cache.put(self.alloc, key, metrics);
    }

    return metrics;
}

fn findGlyphString(
    env: emacs.Env,
    window: emacs.Value,
    span_start: usize,
    cell: *const SpanContent.CellInfo,
) ?emacs.Value {
    const start_val = env.makeValue(span_start + cell.char_start);
    const end_val = env.makeValue(span_start + cell.char_end);
    const composition = env.f("find-composition", .{ start_val, end_val, env.nil(), env.t() });
    if (env.isNotNil(composition)) {
        const gstring = env.f("nth", .{ 2, composition });
        if (env.isNotNil(gstring)) return gstring;
    }

    const font = env.f("font-at", .{ start_val, window });
    // TODO: Maybe we should replace the cell with something else if there
    //       is no font. Today, it will just show the missing char glyph,
    //       which will push the line size bigger. This is rare, though.
    //       Most chars are covered by SOME font on the system.
    if (env.isNil(font)) return null;
    var gstring = env.f("composition-get-gstring", .{ start_val, end_val, font, env.nil() });
    gstring = env.f("font-shape-gstring", .{ gstring, env.nil() });
    return if (env.isNil(gstring)) null else gstring;
}

fn addRowToSpan(self: *Self, row_pin: gt.Pin) !usize {
    return try self.span.addRow(
        self,
        row_pin,
        if (self.font_info) |f| f.coverage else std.math.maxInt(u32),
    );
}

fn flushSpan(self: *Self, env: emacs.Env) !void {
    if (self.span.text.items.len == 0) return;

    const span_start = env.cast(usize, env.f("point", .{}));
    _ = env.f("insert", .{self.span.text.items});

    for (self.span.runs.items) |*run| {
        if (run.key) |*key| {
            const prop_start = span_start + @as(usize, @intCast(run.start_char));
            const prop_end = span_start + @as(usize, @intCast(run.end_char));
            try self.applyProps(env, prop_start, prop_end, self.span.node.?, key);
        }
    }

    try self.adjustGlyphs(env, span_start);

    for (self.span.line_wraps.items) |offset| {
        // Mark newlines from soft-wrapped rows so copy mode can filter them
        _ = env.f("put-text-property", .{
            span_start + offset,
            span_start + offset + 1,
            emacs.sym.@"ghostel-wrap",
            env.t(),
        });
    }

    if (self.span.cursor_char_pos) |pos| {
        env.set(
            "ghostel--cursor-char-pos",
            @as(usize, @intCast(span_start)) + pos,
        );
    }
}

fn isSameRow(a: gt.Pin, b: gt.Pin) bool {
    return a.node == b.node and a.y == b.y;
}

fn isRowDirty(self: *Self, pin: gt.Pin) bool {
    if (pin.rowAndCell().row.dirty) return true;

    const cursor = if (self.term.modes.get(.cursor_visible))
        self.term.screens.active.cursor.page_pin.*
    else
        null;

    // Cursor movement requires rebuilding both the previous and current cursor rows.
    if (!std.meta.eql(cursor, self.rendered_cursor)) {
        if (cursor) |c| if (isSameRow(c, pin)) return true;
        if (self.rendered_cursor) |c| if (isSameRow(c, pin)) return true;
    }

    return false;
}

fn render(
    self: *Self,
    env: emacs.Env,
    start_pin: gt.Pin,
) !void {
    const term = self.term;

    var page = if (term.screens.active.no_scrollback)
        null
    else
        try self.getOrAddPage(start_pin.node.serial);

    var eob = false;
    var current_span: ?struct {
        start_val: emacs.Value,
        node: *const gt.PageList.List.Node,
        adjusted_line_start: usize,
    } = null;

    var it = start_pin.rowIterator(.right_down, null);
    while (it.next()) |row_pin| {
        const row = row_pin.rowAndCell().row;
        eob = eob or env.isNotNil(env.f("eobp", .{}));

        if (page) |p| {
            if (p.serial != row_pin.node.serial) {
                page = p.next() orelse try self.addPage(row_pin.node.serial);
                std.debug.assert(page != null);
                std.debug.assert(page.?.serial == row_pin.node.serial);
            }
        }

        const clean = !eob and !self.isRowDirty(row_pin);
        if (current_span) |*span| {
            if (clean or span.node != row_pin.node) {
                _ = env.f("delete-region", .{ span.start_val, env.f("point", .{}) });
                try self.flushSpan(env);
                current_span = null;
            }
        }

        const line_start_val = env.f("point", .{});
        if (!eob) _ = env.f("forward-line", .{1});
        const old_line_end_val = env.f("point", .{});

        if (!clean) {
            if (current_span == null) {
                current_span = .{
                    .start_val = line_start_val,
                    .node = row_pin.node,
                    .adjusted_line_start = env.cast(usize, line_start_val),
                };
                try self.span.clear();
            }

            const new_line_len = try self.addRowToSpan(row_pin);
            const line_start = env.cast(usize, line_start_val);
            const old_line_len = env.cast(usize, old_line_end_val) - line_start;
            if (old_line_len > 0) {
                self.saved_markers.adjustRegion(
                    current_span.?.adjusted_line_start,
                    old_line_len,
                    new_line_len,
                );
                current_span.?.adjusted_line_start += new_line_len;
            }

            if (page) |p| {
                p.len -|= old_line_len;
                p.len += new_line_len;
            }
        }

        row.dirty = false;
    }

    if (current_span) |*span| {
        _ = env.f("delete-region", .{ span.start_val, env.f("point", .{}) });
        try self.flushSpan(env);
    }
}

fn renderCursor(self: *Self, env: emacs.Env) !void {
    if (self.term.modes.get(.cursor_visible)) {
        const screen = self.term.screens.active;
        _ = env.set("ghostel--cursor-pos", env.cons(screen.cursor.x, screen.cursor.y));
        env.set(
            "ghostel--cursor-style",
            @intFromEnum(screen.cursor.cursor_style),
        );
        self.rendered_cursor = screen.cursor.page_pin.*;
    } else {
        _ = env.set("ghostel--cursor-pos", env.nil());
        env.set("ghostel--cursor-style", env.nil());
        self.rendered_cursor = null;
    }

    _ = env.set("ghostel--cursor-blinking", if (self.term.modes.get(.cursor_blinking))
        env.t()
    else
        env.nil());
}

fn commitResize(self: *Self, env: emacs.Env) !void {
    if (self.pending_resize) |rz| {
        const cols_changed = rz.cols != self.term.cols;
        // Pin our saved positions during resize
        self.saved_markers.pin(self.term.screens.active, env);

        try self.term.resize(self.alloc, rz.cols, rz.rows);
        self.term.width_px = std.math.mul(u32, rz.cols, rz.cell_w) catch
            std.math.maxInt(u32);
        self.term.height_px = std.math.mul(u32, rz.rows, rz.cell_h) catch
            std.math.maxInt(u32);
        self.pending_resize = null;

        env.set("ghostel--term-rows", self.term.rows);
        env.set("ghostel--term-cols", self.term.cols);

        const total_rows_changed = self.rows_in_buffer != self.term.screens.active.pages.total_rows;
        if (cols_changed or
            total_rows_changed or
            self.term.screens.active.no_scrollback)
        {
            try self.clear(env);
        }
    }
}

/// Position the Emacs point at the start of the active area: `self.term.rows`
/// lines back from `point-max`.
fn gotoActiveStart(self: *Self, env: emacs.Env) void {
    _ = env.f("goto-char", .{env.f("point-max", .{})});
    _ = env.f("forward-line", .{-@as(i64, @intCast(self.term.rows))});
}

fn getOrAddPage(self: *Self, serial: PageSerial) !*MaterializedPage {
    var node = self.pages_in_buffer.last;
    while (node) |n| : (node = n.prev) {
        const page: *MaterializedPage = @fieldParentPtr("node", n);
        if (page.serial == serial) return page;
    }

    return self.addPage(serial);
}

fn addPage(self: *Self, serial: PageSerial) !*MaterializedPage {
    const page = try self.alloc.create(MaterializedPage);
    page.* = .{ .serial = serial };
    self.pages_in_buffer.append(&page.node);
    return page;
}

fn clear(self: *Self, env: emacs.Env) !void {
    _ = env.f("erase-buffer", .{});
    self.rows_in_buffer = 0;
    self.clearPages();

    const screen = self.term.screens.active;
    const active_pin = try screen.pages.trackPin(screen.pages.getTopLeft(.screen));

    self.untrackActivePinIfLive();
    self.active_pin = active_pin;
    self.rendered_screen = currentScreenId(self.term);
}

fn clearPages(self: *Self) void {
    while (self.pages_in_buffer.pop()) |n| {
        self.alloc.destroy(@as(*MaterializedPage, @fieldParentPtr("node", n)));
    }
}

fn evictScrollback(self: *Self, env: emacs.Env) void {
    var evicted_chars: usize = 0;

    // Only evict whole pages. libghostty can erase partial pages when clearing
    // the scrollback, but we handle that by detecting clearing specifically and
    // clearing the whole screen instead.
    const term_first_page = self.term.screens.active.pages.pages.first.?;
    while (self.pages_in_buffer.first) |n| {
        const first_page: *MaterializedPage = @fieldParentPtr("node", n);
        if (first_page.serial == term_first_page.serial) break;

        evicted_chars += first_page.len;

        _ = self.pages_in_buffer.popFirst();
        self.alloc.destroy(first_page);
    }

    if (evicted_chars > 0) {
        _ = env.f("delete-region", .{ 1, 1 + evicted_chars });
        self.saved_markers.adjustRegion(1, evicted_chars, 0);
    }
}
