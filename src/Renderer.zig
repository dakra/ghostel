/// RenderState-based terminal rendering to Emacs buffers.
///
/// Reads rows/cells from the ghostty render state, extracts text and
/// style attributes, and inserts propertized text into the current
/// Emacs buffer.  See `redraw' below for the per-redraw algorithm.
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
render_pin: ?*gt.Pin,

/// The screen that is currently rendered into the buffer.
rendered_screen: *gt.Screen,

/// Pin of the last rendered cursor position
rendered_cursor: ?gt.Pin,

/// Number of libghostty rows already materialized into the Emacs buffer.
rows_in_buffer: usize = 0,

/// List of pages materialized in buffer
pages_in_buffer: std.DoublyLinkedList = .{},

/// Any pending resize as `.{cols, rows}`. Resizes are committed on next redraw.
pending_resize: ?ViewportSize = null,

/// Reusable instance of RowContent to reduce allocations
row: RowContent,

/// Cached font metrics and rendering parameters that affect glyph layout.
/// When any field changes between redraws the viewport is fully invalidated.
font_info: ?FontInfo = null,

/// Bold text coloring configuration.
bold_config: ?gt.Style.BoldColor = null,

/// Saved positions and pins for various buffer markers. Retained between
/// rendering passes to avoid allocations.
saved_markers: SavedBufferMarkers = .{},

const PageSerial = @FieldType(gt.PageList.List.Node, "serial");

const MaterializedPage = struct {
    node: std.DoublyLinkedList.Node = .{},
    serial: PageSerial,
    char_len: usize = 0,
    rows: usize = 0,

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

    _ = env.f("make-local-variable", .{s.@"ghostel--query-font-cache"});
    _ = env.set("ghostel--query-font-cache", env.f("make-hash-table", .{
        s.@":test",
        s.eq,
    }));

    _ = env.f("make-local-variable", .{s.@"ghostel--rendered-font"});
    _ = env.set("ghostel--rendered-font", env.nil());

    var renderer = Self{
        .alloc = alloc,
        .term = term,
        .render_pin = try term.screens.active.pages.trackPin(
            term.screens.active.pages.getTopLeft(.screen),
        ),
        .rendered_screen = term.screens.active,
        .rendered_cursor = null,
        .pending_resize = .{ .cols = term.cols, .rows = term.rows, .cell_w = 1, .cell_h = 1 },
        .row = .{ .alloc = alloc },
    };
    _ = try renderer.commitResize(env);
    return renderer;
}

pub fn deinit(self: *Self) void {
    self.saved_markers.deinit(self.alloc);
    self.row.deinit();
    self.clearPages();
    if (self.render_pin) |p| self.rendered_screen.pages.untrackPin(p);
    if (self.font_info) |*fi| fi.deinit(self.alloc);
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

    try self.saved_markers.save(self.alloc, env);
    defer self.saved_markers.restoreAndClear(self.term.screens.active, env);

    self.gotoActiveStart(env);

    if (force_full) try self.clear(env);
    try self.updateFontInfo(env);
    try self.commitResize(env);
    if (self.rendered_screen != self.term.screens.active) {
        try self.clear(env);
    }
    try self.invalidate(env);
    self.evictScrollback(env);

    try self.render(
        env,
        if (self.render_pin) |p|
            p.*
        else
            self.rendered_screen.pages.getTopLeft(.active),
    );

    try self.renderCursor(env);

    if (self.render_pin) |p| p.* = self.rendered_screen.pages.getTopLeft(.active);

    // Verify integrity in debug mode
    std.debug.assert(self.rows_in_buffer == if (self.rendered_screen.no_scrollback)
        self.term.rows
    else
        self.rendered_screen.pages.total_rows);
}

fn invalidate(self: *Self, env: emacs.Env) !void {
    const scrollback_cleared = self.rows_in_buffer > self.term.rows and
        self.render_pin != null and
        self.render_pin.?.eql(self.rendered_screen.pages.getTopLeft(.screen));

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

/// Read the style for the current cell from the render state.
fn createCellProps(
    self: *Self,
    page: *const gt.Page,
    key: CellPropKey,
    cell: *const gt.Cell,
) ?CellProps {
    var props: CellProps = .{};

    const style: gt.Style = if (cell.hasStyling())
        page.styles.get(page.memory, cell.style_id).*
    else
        .{};

    props.fg = style_face.resolveForeground(
        &style,
        &self.term.colors.palette.current,
        self.bold_config,
    );
    props.bg = style.bg(cell, &self.term.colors.palette.current);
    props.bold = style.flags.bold;
    props.italic = style.flags.italic;
    props.faint = style.flags.faint;
    props.underline = style.flags.underline;
    props.strikethrough = style.flags.strikethrough;
    props.overline = style.flags.overline;
    props.inverse = style.flags.inverse;
    props.underline_color = style.underlineColor(&self.term.colors.palette.current);
    props.hyperlink = resolveHyperlink(page, key.hyperlink_id);
    props.semantic_content = cell.semantic_content;

    return if (props.isPlain()) null else props;
}

/// Apply text properties to a region of the buffer.
fn applyProps(
    env: emacs.Env,
    start: i64,
    end: i64,
    props: CellProps,
) !void {
    if (start >= end) return;
    const s = emacs.sym;

    const start_val = env.makeInteger(start);
    const end_val = env.makeInteger(end);

    if (try style_face.buildFacePlist(env, props)) |face| {
        _ = env.f("put-text-property", .{
            start_val,
            end_val,
            s.face,
            face,
        });
    }

    if (props.hyperlink) |link| {
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

    switch (props.semantic_content) {
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

// TODO: Style ID type is not exported from ghostty-vt for some reason.
//       We should file an issue.
const StyleId = @FieldType(gt.page.Cell, "style_id");

/// Unique identifier that is cheaper to read and compare relative to `CellProps`.
/// We read this first and if it differs from the previous cell, we read the full
/// `CellProps`.
const CellPropKey = packed struct {
    style_id: StyleId,
    hyperlink_id: gt.size.HyperlinkCountInt,
    semantic_content: gt.page.Cell.SemanticContent,

    fn create(page: *const gt.Page, cell: *const gt.page.Cell) CellPropKey {
        return .{
            .style_id = cell.style_id,
            .hyperlink_id = if (cell.hyperlink)
                page.lookupHyperlink(cell) orelse 0
            else
                0,
            .semantic_content = cell.semantic_content,
        };
    }
};

pub const RowContent = struct {
    const Run = struct {
        start_char: usize,
        end_char: usize,
        props: ?CellProps,
    };

    const CellInfo = struct {
        col: i64,
        char_start: i64,
        char_end: i64,
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

    /// The UTF-8 text content of the row
    text: std.ArrayList(u8) = .empty,

    /// Cells that need their glyphs metrics adjusted after insetions
    adjust_cells: std.ArrayList(CellInfo) = .empty,

    /// The number of codepoints (as opposed to bytes) in the text. Emacs
    /// treats each codepoint as a separate character for buffer positions, even
    /// if it doesn't necessarily render as such.
    char_len: usize = 0,

    /// A list of continuous property runs
    runs: std.ArrayList(Run) = .empty,

    /// The character position of the cursor
    cursor_char_pos: ?usize = null,

    pub fn build(
        self: *RowContent,
        renderer: *Self,
        row_pin: gt.Pin,
        adjustment_threshold: u32,
    ) !void {
        try self.clear();

        const term = renderer.term;
        const screen = term.screens.active;

        // Position at the end of the last non-blank cell; final row length
        // is trimmed back to this. Any run of blank cells past the end is
        // discarded along with their default-style trailing padding.
        var trim_byte_len: usize = 0;
        var trim_char_len: usize = 0;

        const cursor_visible = term.modes.get(.cursor_visible);
        const cursor_col = if (cursor_visible and isSameRow(row_pin, screen.cursor.page_pin.*))
            screen.cursor.page_pin.x
        else
            null;

        const page = &row_pin.node.data;
        const row = row_pin.rowAndCell().row;
        var current_prop_key: ?CellPropKey = null;
        for (page.getCells(row), 0..) |*cell, col| {
            const has_cursor = @as(u16, @intCast(col)) == cursor_col;
            if (has_cursor) self.cursor_char_pos = self.char_len;

            if (cell.wide == .spacer_tail or cell.wide == .spacer_head) continue;

            // We use a "key" that holds a minimum set of values that are cheap to
            // compare to detect style run breaks.
            const prop_key = CellPropKey.create(&row_pin.node.data, cell);
            if (prop_key != current_prop_key) {
                try self.runs.append(self.alloc, .{
                    .start_char = self.char_len,
                    .end_char = self.char_len,
                    .props = createCellProps(renderer, page, prop_key, cell),
                });
                current_prop_key = prop_key;
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
            if (cell.hasText() or last_run.props != null) {
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
        if (self.runs.items.len > 0) {
            self.runs.items[self.runs.items.len - 1].end_char = trim_char_len;
        }

        try self.text.append(self.alloc, '\n');
    }

    pub fn deinit(self: *RowContent) void {
        self.text.deinit(self.alloc);
        self.adjust_cells.deinit(self.alloc);
        self.runs.deinit(self.alloc);
    }

    fn clear(self: *RowContent) !void {
        self.text.clearRetainingCapacity();
        self.adjust_cells.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
        self.char_len = 0;
        self.cursor_char_pos = null;
    }

    fn appendCodepoints(self: *RowContent, cluster: []const u21) !void {
        for (cluster) |cp| {
            const slice = try self.text.addManyAsSlice(
                self.alloc,
                try std.unicode.utf8CodepointSequenceLength(cp),
            );
            _ = try std.unicode.utf8Encode(cp, slice);
            self.char_len += 1;
        }
    }
};

fn adjustGlyphs(
    self: *Self,
    env: emacs.Env,
    row_start: i64,
) !void {
    if (self.row.adjust_cells.items.len == 0) return;
    if (self.font_info == null) return;
    const window = env.f("selected-window", .{});
    if (env.isNil(window)) return;

    for (self.row.adjust_cells.items) |*cell| {
        try self.adjustGlyph(env, window, row_start, cell);
    }
}

fn adjustGlyph(
    self: *Self,
    env: emacs.Env,
    window: emacs.Value,
    row_start: i64,
    cell: *const RowContent.CellInfo,
) !void {
    const s = emacs.sym;
    const default_font_info = self.font_info.?;

    const start_val = env.makeInteger(row_start + @as(i64, @intCast(cell.char_start)));
    const end_val = env.makeInteger(row_start + @as(i64, @intCast(cell.char_end)));
    const metrics = try self.getGlyphMetrics(env, window, row_start, cell) orelse return;

    // Skip adjustments if size already matches perfectly
    const native_char_width: i64 = if (cell.wide) 2 else 1;
    const native_slot_width = default_font_info.width * native_char_width;
    if (metrics.width == native_slot_width and
        metrics.ascent == default_font_info.ascent and
        metrics.descent == default_font_info.descent) return;

    const char_width = self.adjustWidth(env, row_start, cell, metrics);
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
    row_start: i64,
    cell: *const RowContent.CellInfo,
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
    const preceding = cell.precedingByte(self.row.text.items);
    const following = cell.followingByte(self.row.text.items);
    const empty_before = preceding == null or preceding.? == ' ';
    const empty_after = following == null or following.? == ' ';
    if (!empty_before or !empty_after) return 1;

    // We can claim the space after, but if it's a space, we must first hide it.
    if (following) |c| {
        if (c == ' ') {
            const claim_pos = row_start + cell.char_end;
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
    row_start: i64,
    cell: *const RowContent.CellInfo,
) !?GlyphMetricsCache.Metrics {
    const key = cell.metricsKey(self.row.text.items);
    if (self.font_info) |*fi| {
        if (fi.metrics_cache.get(key)) |metrics| return metrics;
    }

    const gstring = findGlyphString(env, window, row_start, cell) orelse {
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
    row_start: i64,
    cell: *const RowContent.CellInfo,
) ?emacs.Value {
    const start_val = env.makeInteger(row_start + cell.char_start);
    const end_val = env.makeInteger(row_start + cell.char_end);
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

/// Insert row text and apply property runs.
fn insertRow(
    self: *Self,
    env: emacs.Env,
    row_pin: gt.Pin,
) !usize {
    try self.row.build(
        self,
        row_pin,
        if (self.font_info) |f| f.coverage else std.math.maxInt(u32),
    );

    const row_start = env.cast(i64, env.f("point", .{}));
    _ = env.f("insert", .{self.row.text.items});
    const row_end = env.cast(i64, env.f("point", .{}));

    for (self.row.runs.items) |*run| {
        if (run.end_char <= run.start_char) continue;

        const prop_start = row_start + @as(i64, @intCast(run.start_char));
        const prop_end = row_start + @as(i64, @intCast(run.end_char));
        if (run.props) |props| {
            try applyProps(env, prop_start, prop_end, props);
        }
    }

    try self.adjustGlyphs(env, row_start);

    if (row_pin.rowAndCell().row.wrap) {
        // Mark newlines from soft-wrapped rows so copy mode can filter them
        const point = env.f("point", .{});
        _ = env.f("put-text-property", .{
            env.cast(i64, point) - 1,
            point,
            emacs.sym.@"ghostel-wrap",
            env.t(),
        });
    }

    if (self.row.cursor_char_pos) |pos| {
        env.set(
            "ghostel--cursor-char-pos",
            @as(usize, @intCast(row_start)) + pos,
        );
    }

    return @intCast(row_end - row_start);
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

    // If the cursor moved, both the old row and the new row are dirty.
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

    var it = start_pin.rowIterator(.right_down, null);
    while (it.next()) |row_pin| {
        const row = row_pin.rowAndCell().row;
        defer row.dirty = false;

        if (page) |p| {
            if (p.serial != row_pin.node.serial) {
                page = p.next() orelse try self.addPage(row_pin.node.serial);
                std.debug.assert(page != null);
                std.debug.assert(page.?.serial == row_pin.node.serial);
            }
        }

        // Only process dirty rows, or if there's no existing row
        const eob = env.isNotNil(env.f("eobp", .{}));
        if (self.isRowDirty(row_pin) or eob) {
            if (eob) {
                // We're adding one line since we're at the end of the buffer
                const line_char_len = try self.insertRow(env, row_pin);
                self.rows_in_buffer += 1;
                if (page) |p| {
                    p.rows += 1;
                    p.char_len += line_char_len;
                }
            } else {
                // Line is dirty and we're not at the end of the buffer,
                // so we're replacing the line.
                const line_start_val = env.f("point", .{});
                const line_start = env.cast(usize, line_start_val);
                const old_line_end_val = env.f("pos-bol", .{2});
                const old_line_len = env.cast(usize, old_line_end_val) - line_start;
                _ = env.f("delete-region", .{ line_start_val, old_line_end_val });
                const new_line_len = try self.insertRow(env, row_pin);

                if (page) |p| {
                    p.char_len -|= old_line_len;
                    p.char_len += new_line_len;
                }
                self.saved_markers.adjustRegion(line_start, old_line_len, new_line_len);
            }
        } else {
            _ = env.f("forward-line", .{1});
        }
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
        self.rendered_cursor = self.rendered_screen.cursor.page_pin.*;
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
    if (self.render_pin) |p| self.rendered_screen.pages.untrackPin(p);
    self.render_pin = null;

    self.rendered_screen = self.term.screens.active;
    if (!self.rendered_screen.no_scrollback) {
        self.render_pin = try self.rendered_screen.pages.trackPin(
            self.rendered_screen.pages.getTopLeft(.screen),
        );
    }
}

fn clearPages(self: *Self) void {
    while (self.pages_in_buffer.pop()) |n| {
        self.alloc.destroy(@as(*MaterializedPage, @fieldParentPtr("node", n)));
    }
}

fn evictScrollback(self: *Self, env: emacs.Env) void {
    var evicted_chars: usize = 0;
    var evicted_rows: usize = 0;

    // Only evict whole pages. libghostty can erase partial pages when clearing
    // the scrollback, but we handle that by detecting clearing specifically and
    // clearing the whole screen instead.
    const term_first_page = self.rendered_screen.pages.pages.first.?;
    while (self.pages_in_buffer.first) |n| {
        const first_page: *MaterializedPage = @fieldParentPtr("node", n);
        if (first_page.serial == term_first_page.serial) break;

        evicted_chars += first_page.char_len;
        evicted_rows += first_page.rows;

        _ = self.pages_in_buffer.popFirst();
        self.alloc.destroy(first_page);
    }

    self.rows_in_buffer -|= evicted_rows;
    if (evicted_chars > 0) {
        _ = env.f("delete-region", .{ 1, 1 + evicted_chars });
        self.saved_markers.adjustRegion(1, evicted_chars, 0);
    }
}
