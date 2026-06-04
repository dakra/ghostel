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

/// Terminal being rendered.
term: *gt.Terminal,

/// Render state for incremental screen updates.
render_state: gt.RenderState,

/// Tracked pin of which row to render down from.
render_pin: ?*gt.Pin,

/// The screen that is currently rendered into the buffer.
rendered_screen: *gt.Screen,

/// Number of libghostty rows already materialized into the Emacs buffer.
rows_in_buffer: usize = 0,

/// List of pages materialized in buffer
pages_in_buffer: std.DoublyLinkedList = .{},

/// Any pending resize as `.{cols, rows}`. Resizes are committed on next redraw.
pending_resize: ?ViewportSize = null,

/// Reusable instance of RowContent to reduce allocations
row: RowContent = .{},

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
};

const FontInfo = struct {
    width: u32,
    height: u32,
    coverage: u32,
    glyph_scale_floor: f64,
    metrics_cache: GlyphMetricsCache = .{},

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        self.metrics_cache.deinit(alloc);
    }
};

pub fn init(alloc: Allocator, term: *gt.Terminal) !Self {
    var renderer = Self{
        .term = term,
        .render_state = gt.RenderState.empty,
        .render_pin = try term.screens.active.pages.trackPin(
            term.screens.active.pages.getTopLeft(.screen),
        ),
        .rendered_screen = term.screens.active,
        .pending_resize = .{ .cols = term.cols, .rows = term.rows, .cell_w = 1, .cell_h = 1 },
    };
    try renderer.commitResize(alloc);
    return renderer;
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    self.saved_markers.deinit(alloc);
    self.render_state.deinit(alloc);
    self.row.deinit(alloc);
    self.clearPages(alloc);
    if (self.render_pin) |p| self.rendered_screen.pages.untrackPin(p);
    if (self.font_info) |*fi| fi.deinit(alloc);
}

pub fn resize(self: *Self, cols: u16, rows: u16, cell_w: u32, cell_h: u32) void {
    self.pending_resize = .{
        .cols = cols,
        .rows = rows,
        .cell_w = cell_w,
        .cell_h = cell_h,
    };
}

/// Redraw the terminal into the current Emacs buffer.
///
/// The Emacs buffer is a permanent record: materialized scrollback sits
/// above the active area. `render_pin` tracks the next libghostty row to
/// render, and `pages_in_buffer` mirrors libghostty's page list so
/// scrollback eviction can be applied precisely by character count.
///
/// Saved buffer positions are restored after mutations.  When
/// `force_full_arg` is true, the buffer is cleared and fully rebuilt
/// instead of using the incremental dirty-row path.
pub fn redraw(self: *Self, alloc: Allocator, env: emacs.Env, force_full_arg: bool) !void {
    try self.saved_markers.save(alloc, env);
    defer self.saved_markers.restoreAndClear(self.term.screens.active, env);

    if (self.invalidate(alloc, env) or force_full_arg) {
        try self.clear(alloc, env);
    }

    self.evictScrollback(alloc, env);
    self.gotoActiveStart(env);
    try self.renderToEnd(
        alloc,
        env,
        if (self.render_pin) |p|
            p.*
        else
            self.rendered_screen.pages.getTopLeft(.active),
    );

    // If we have a pending resize, commit it now and just rerender the active
    // since the scrollback is already up to date.
    if (self.pending_resize != null) {
        try self.commitResize(alloc);
        self.gotoActiveStart(env);
        try self.render(alloc, env, self.term.screens.active.pages.getTopLeft(.active));
        self.evictScrollback(alloc, env);
    }

    try self.renderCursor(env);

    if (self.render_pin) |p| p.* = self.rendered_screen.pages.getTopLeft(.active);

    std.debug.assert(self.rows_in_buffer == if (self.rendered_screen.no_scrollback)
        self.term.rows
    else
        self.rendered_screen.pages.total_rows);
}

fn invalidate(self: *Self, alloc: Allocator, env: emacs.Env) bool {
    // If the font metrics or related parameters changed, the cached metrics
    // are no longer valid, so we rebuild.
    if (self.updateFontInfo(alloc, env)) return true;

    // We always do a full rebuild if the width changed
    if (self.pending_resize) |rz| {
        if (rz.cols != self.term.cols) {
            // Pin our saved positions during resize
            self.saved_markers.pin(self.term.screens.active, env);
            return true;
        }
    }

    // If we are in no-scrollback mode, just redraw whenever we have a resize.
    if (self.pending_resize != null and self.rendered_screen.no_scrollback) {
        return true;
    }

    // If the active screen changes, we reset scrollback
    if (self.rendered_screen != self.term.screens.active) {
        return true;
    }

    // If we had existing scrollback, the render pin should be below the top of
    // the scrollback. If it isn't that means that the scrollback was cleared.
    if (self.rows_in_buffer > self.term.rows and
        self.render_pin != null and
        self.render_pin.?.eql(self.rendered_screen.pages.getTopLeft(.screen)))
    {
        return true;
    }

    return false;
}

/// Read the default font and rendering parameters from Emacs, compare
/// against the cached values, and signal whether a full invalidation is
/// required.
fn updateFontInfo(self: *Self, alloc: Allocator, env: emacs.Env) bool {
    const new_font = getDefaultFont(env);
    const current_font = env.symbolValue("ghostel--rendered-font");

    const raw_floor = env.symbolValue("ghostel-glyph-scale-floor");
    const floor = std.math.clamp(env.asFloat(raw_floor, 0.0), 0.0, 1.0);

    // Fast path: nothing changed since last redraw.
    if (env.eq(new_font, current_font)) {
        if (self.font_info) |cached| {
            if (cached.glyph_scale_floor == floor) return false;
        } else {
            return false; // no font before, no font now
        }
    }

    _ = env.set("ghostel--rendered-font", new_font);

    if (self.font_info) |*fi| {
        fi.deinit(alloc);
        self.font_info = null;
    }

    if (env.isNotNil(new_font)) {
        const default_font_info = env.f("ghostel--query-font-cached", .{new_font});
        // The value is a vector:
        // [ NAME FILENAME PIXEL-SIZE SIZE ASCENT DESCENT SPACE-WIDTH AVERAGE-WIDTH
        //   CAPABILITY ]
        const cell_ascent = env.cast(u32, env.vecGet(default_font_info, 4));
        const cell_descent = env.cast(u32, env.vecGet(default_font_info, 5));

        self.font_info = .{
            .width = env.cast(u32, env.vecGet(default_font_info, 6)),
            .height = cell_ascent + cell_descent,
            .coverage = probeCoverage(env, new_font),
            .glyph_scale_floor = floor,
        };
    }
    return true;
}

fn getDefaultFont(env: emacs.Env) emacs.Value {
    const s = emacs.sym;
    const font = env.f("face-attribute", .{ s.default, s.@":font" });
    if (env.isNil(env.f("fontp", .{ font, s.@"font-object" }))) return env.nil();
    return font;
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
    cell: *const gt.RenderState.Cell,
) ?CellProps {
    var props: CellProps = .{};

    const style: gt.Style = if (cell.raw.hasStyling()) cell.style else .{};

    props.fg = style.fg(.{
        .default = self.render_state.colors.foreground,
        .palette = &self.render_state.colors.palette,
        .bold = self.bold_config,
    });
    props.bg = style.bg(&cell.raw, &self.render_state.colors.palette) orelse
        self.render_state.colors.background;
    props.bold = style.flags.bold;
    props.italic = style.flags.italic;
    props.faint = style.flags.faint;
    props.underline = style.flags.underline;
    props.strikethrough = style.flags.strikethrough;
    props.overline = style.flags.overline;
    props.inverse = style.flags.inverse;
    props.underline_color = style.underlineColor(&self.render_state.colors.palette);
    props.hyperlink = resolveHyperlink(page, key.hyperlink_id);
    props.semantic_content = cell.raw.semantic_content;

    return if (props.isDefault(
        self.render_state.colors.foreground,
        self.render_state.colors.background,
    )) null else props;
}

/// Apply text properties to a region of the buffer.
fn applyProps(env: emacs.Env, start: i64, end: i64, props: CellProps) !void {
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
        wide: bool,
        metrics_key: GlyphMetricsCache.Key,
    };

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
        alloc: Allocator,
        renderer: *Self,
        row: *const gt.RenderState.Row,
        cursor_col: ?u16,
        adjustment_threshold: u32,
    ) !void {
        try self.clear();

        // Position at the end of the last non-blank cell; final row length
        // is trimmed back to this. Any run of blank cells past the end is
        // discarded along with their default-style trailing padding.
        var trim_byte_len: usize = 0;
        var trim_char_len: usize = 0;

        const page = &row.pin.node.data;
        var current_prop_key: ?CellPropKey = null;
        var col: u16 = 0;
        while (col < row.cells.len) : (col += 1) {
            const cell = row.cells.get(col);
            const raw_cell = page.getRowAndCell(col, row.pin.y).cell;

            const has_cursor = col == cursor_col;
            if (has_cursor) self.cursor_char_pos = self.char_len;

            if (cell.raw.wide == .spacer_tail or cell.raw.wide == .spacer_head) continue;

            // We use a "key" that holds a minimum set of values that are cheap to
            // compare to detect style run breaks.
            const prop_key = CellPropKey.create(&row.pin.node.data, raw_cell);
            if (prop_key != current_prop_key) {
                try self.runs.append(alloc, .{
                    .start_char = self.char_len,
                    .end_char = self.char_len,
                    .props = createCellProps(renderer, page, prop_key, &cell),
                });
                current_prop_key = prop_key;
            }

            const byte_start = self.text.items.len;
            const char_start = self.char_len;

            const codepoint: u21 = if (raw_cell.hasText()) raw_cell.codepoint() else ' ';
            try self.appendCodepoints(alloc, &[1]u21{codepoint});
            if (raw_cell.hasGrapheme()) {
                try self.appendCodepoints(alloc, cell.grapheme);
            }

            // If this is a grapheme cluster, or if the char is not covered by
            // the default font, we register it as needing font glyph adjustment
            // to fit into the monospace grid.
            if (raw_cell.hasGrapheme() or codepoint >= adjustment_threshold) {
                try self.adjust_cells.append(alloc, .{
                    .col = @intCast(col),
                    .char_start = @intCast(char_start),
                    .char_end = @intCast(self.char_len),
                    .wide = raw_cell.wide == .wide,
                    .metrics_key = .{
                        .page_serial = row.pin.node.serial,
                        .style_id = if (current_prop_key) |key| key.style_id else 0,
                        .utf8 = .{ .borrowed = self.text.items[byte_start..self.text.items.len] },
                    },
                });
            }

            const last_run = &self.runs.items[self.runs.items.len - 1];
            last_run.end_char = self.char_len;

            // We trim cells that neither have content nor styling. A blank
            // cursor cell only requires enough whitespace to place point at
            // the cursor column, not an extra rendered space under it.
            if (raw_cell.hasText() or last_run.props != null) {
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

        try self.text.append(alloc, '\n');
    }

    pub fn deinit(self: *RowContent, alloc: Allocator) void {
        self.text.deinit(alloc);
        self.adjust_cells.deinit(alloc);
        self.runs.deinit(alloc);
    }

    fn clear(self: *RowContent) !void {
        self.text.clearRetainingCapacity();
        self.adjust_cells.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
        self.char_len = 0;
        self.cursor_char_pos = null;
    }

    fn appendCodepoints(self: *RowContent, alloc: Allocator, cluster: []const u21) !void {
        for (cluster) |cp| {
            const slice = try self.text.addManyAsSlice(
                alloc,
                try std.unicode.utf8CodepointSequenceLength(cp),
            );
            _ = try std.unicode.utf8Encode(cp, slice);
            self.char_len += 1;
        }
    }
};

fn adjustGlyphs(
    self: *Self,
    alloc: Allocator,
    env: emacs.Env,
    row_start: i64,
    row_end: i64,
) !void {
    if (self.row.adjust_cells.items.len == 0) return;
    if (self.font_info == null) return;
    const window = env.f("selected-window", .{});
    if (env.isNil(window)) return;

    for (self.row.adjust_cells.items) |*cell| {
        try self.adjustGlyph(alloc, env, window, row_start, row_end, cell);
    }
}

fn adjustGlyph(
    self: *Self,
    alloc: Allocator,
    env: emacs.Env,
    window: emacs.Value,
    row_start: i64,
    row_end: i64,
    cell: *const RowContent.CellInfo,
) !void {
    const s = emacs.sym;
    const default_font_info = self.font_info.?;

    const start_val = env.makeInteger(row_start + @as(i64, @intCast(cell.char_start)));
    const end_val = env.makeInteger(row_start + @as(i64, @intCast(cell.char_end)));
    const metrics = try self.getGlyphMetrics(
        alloc,
        env,
        cell.metrics_key,
        window,
        start_val,
        end_val,
    ) orelse return;
    var char_width: i64 = if (cell.wide) 2 else 1;
    var slot_width = default_font_info.width * char_width;

    // Skip adjustments if size already matches perfectly
    if (metrics.width == slot_width and metrics.height == default_font_info.height) return;

    // Let's check if we can claim some space after the glyph to be able to render
    // it larger than the cell size while still maintaining alignment.
    const pre_char_width = char_width;
    while (cell.col + char_width < self.term.cols) : ({
        char_width += 1;
        slot_width = default_font_info.width * char_width;
    }) {
        const cell_aspect = @as(f64, @floatFromInt(slot_width)) /
            @as(f64, @floatFromInt(default_font_info.height));
        const glyph_aspect = @as(f64, @floatFromInt(metrics.width)) /
            @as(f64, @floatFromInt(metrics.height));
        // If the aspect of the glyph is narrower than that of the cell, we're done
        if (glyph_aspect < cell_aspect) break;

        const claim_pos = row_start + cell.char_end + (char_width - pre_char_width);
        // Lines are right-trimmed of trailing spaces, so positions at and past
        // the newline represent empty space we can freely claim.
        if (claim_pos >= row_end - 1) continue;

        const c = env.cast(i64, env.f("char-after", .{claim_pos}));
        if (c == ' ') {
            _ = env.f("put-text-property", .{
                claim_pos,
                claim_pos + 1,
                s.display,
                env.cons(s.space, env.list(.{ s.@":width", 0 })),
            });
        } else {
            break;
        }
    }

    // We add a fudge factor of +1 to the denominator to ensure fit
    const scale_width = @as(f64, @floatFromInt(slot_width)) /
        @as(f64, @floatFromInt(metrics.width + 1));
    const scale_height = @as(f64, @floatFromInt(default_font_info.height)) /
        @as(f64, @floatFromInt(metrics.height + 1));
    const computed_scale = @min(scale_width, scale_height);
    const scale = @max(computed_scale, default_font_info.glyph_scale_floor);

    const min_width_spec = env.list(.{ s.@"min-width", env.list(.{char_width}) });
    const scale_spec = env.list(.{ s.height, scale });
    const display_spec = env.list(.{ min_width_spec, scale_spec });
    _ = env.f("put-text-property", .{
        start_val,
        end_val,
        s.display,
        display_spec,
    });
}

fn getGlyphMetrics(
    self: *Self,
    alloc: Allocator,
    env: emacs.Env,
    key: GlyphMetricsCache.Key,
    window: emacs.Value,
    start_val: emacs.Value,
    end_val: emacs.Value,
) !?GlyphMetricsCache.Metrics {
    const borrowed_key = key.borrowed(self.row.text.items);
    if (self.font_info) |*fi| {
        if (fi.metrics_cache.get(borrowed_key)) |metrics| return metrics;
    }

    const gstring = findGlyphString(env, window, start_val, end_val) orelse {
        return null;
    };
    // [HEADER ID GLYPH ...]
    const header = env.vecGet(gstring, 0);
    const glyph = env.vecGet(gstring, 2);

    // [FONT-OBJECT CHAR ...]
    const font = env.vecGet(header, 0);
    const font_info = env.f("ghostel--query-font-cached", .{font});
    const ascent = env.cast(i64, env.vecGet(font_info, 4));
    const descent = env.cast(i64, env.vecGet(font_info, 5));
    const height = ascent + descent;

    // Each element is a vector containing information of a glyph in this format:
    // [FROM-IDX TO-IDX C CODE WIDTH LBEARING RBEARING ASCENT DESCENT ADJUSTMENT]
    const width = env.cast(u32, env.vecGet(glyph, 4));

    const metrics = GlyphMetricsCache.Metrics{ .width = width, .height = height };
    if (self.font_info) |*fi| {
        try fi.metrics_cache.put(alloc, borrowed_key, metrics);
    }

    return metrics;
}

fn findGlyphString(
    env: emacs.Env,
    window: emacs.Value,
    start_val: emacs.Value,
    end_val: emacs.Value,
) ?emacs.Value {
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
    alloc: Allocator,
    env: emacs.Env,
    row: *const gt.RenderState.Row,
    cursor_col: ?u16,
) !usize {
    try self.row.build(
        alloc,
        self,
        row,
        cursor_col,
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

    try self.adjustGlyphs(alloc, env, row_start, row_end);

    if (row.raw.wrap) {
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

pub fn render(
    self: *Self,
    alloc: Allocator,
    env: emacs.Env,
    pin: gt.Pin,
) !void {
    self.term.screens.active.pages.scroll(.{ .pin = pin });
    try self.updateRenderState(alloc);

    if (self.render_state.dirty != .false) {
        // Set buffer default face
        var fg_hex: [7]u8 = undefined;
        var bg_hex: [7]u8 = undefined;
        _ = env.f("ghostel--set-buffer-face", .{
            formatColor(self.render_state.colors.foreground, &fg_hex),
            formatColor(self.render_state.colors.background, &bg_hex),
        });

        const skip = switch (pin.downOverflow(self.term.rows)) {
            .overflow => |of| of.remaining - 1,
            else => 0,
        };

        var i: usize = 0;
        const row_dirty = self.render_state.row_data.items(.dirty);
        while (i < self.render_state.rows) : ({
            // Clear per-row dirty flag
            row_dirty[i] = false;
            i += 1;
        }) {
            if (i < skip) continue;

            const dirty_row = self.render_state.dirty == .full or row_dirty[i];
            // Only process dirty rows, or there's no existing row
            const eob = env.isNotNil(env.f("eobp", .{}));
            if (dirty_row or eob) {
                const row = self.render_state.row_data.get(i);

                // We don't track pages when we have no scrollback
                const page: ?*MaterializedPage = if (self.rendered_screen.no_scrollback)
                    null
                else
                    try self.getOrAddLastPage(alloc, row.pin.node.serial);

                const cursor_col = blk: {
                    if (self.render_state.cursor.viewport) |vp| {
                        if (vp.y == i) break :blk vp.x;
                    }

                    break :blk null;
                };

                if (eob) {
                    // We're adding one line since we're at the end of the buffer
                    const line_char_len = try self.insertRow(alloc, env, &row, cursor_col);
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
                    const new_line_len = try self.insertRow(alloc, env, &row, cursor_col);

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

        // Reset dirty state
        self.render_state.dirty = .false;
    }
}

fn updateRenderState(self: *Self, alloc: Allocator) !void {
    const pre_cursor: ?gt.RenderState.Cursor.Viewport =
        self.render_state.cursor.viewport;

    try self.render_state.update(alloc, self.term);
    if (self.render_state.dirty == .full) return;

    const post_cursor: ?gt.RenderState.Cursor.Viewport =
        self.render_state.cursor.viewport;

    if (!std.meta.eql(pre_cursor, post_cursor)) {
        // The cursor moved. Both the old row and the new row are dirty.
        if (self.render_state.dirty == .false) {
            self.render_state.dirty = .partial;
        }
        const row_dirty = self.render_state.row_data.items(.dirty);
        if (pre_cursor) |vp| row_dirty[vp.y] = true;
        if (post_cursor) |vp| row_dirty[vp.y] = true;
    }
}

fn renderCursor(self: *Self, env: emacs.Env) !void {
    if (self.render_state.cursor.viewport) |vp| {
        _ = env.set("ghostel--cursor-pos", env.cons(vp.x, vp.y));
    } else {
        _ = env.set("ghostel--cursor-pos", env.nil());
    }

    _ = env.f("ghostel--set-cursor-style", .{
        @intFromEnum(self.render_state.cursor.visual_style),
        if (self.render_state.cursor.visible) env.t() else env.nil(),
    });
}

// Render all pages from start_pin through the end of the active area,
// one viewport-sized chunk per page.
fn renderToEnd(self: *Self, alloc: Allocator, env: emacs.Env, start_pin: gt.Pin) !void {
    var p: ?gt.Pin = start_pin;
    while (p) |pin| : (p = pin.down(self.term.rows)) {
        try self.render(alloc, env, pin);
    }
}

fn commitResize(self: *Self, alloc: Allocator) !void {
    if (self.pending_resize) |rz| {
        try self.term.resize(alloc, rz.cols, rz.rows);
        self.term.width_px = std.math.mul(u32, rz.cols, rz.cell_w) catch
            std.math.maxInt(u32);
        self.term.height_px = std.math.mul(u32, rz.rows, rz.cell_h) catch
            std.math.maxInt(u32);
        self.pending_resize = null;
    }
}

/// Position the Emacs point at the start of the active area: `self.term.rows`
/// lines back from `point-max`.
fn gotoActiveStart(self: *Self, env: emacs.Env) void {
    _ = env.f("goto-char", .{env.f("point-max", .{})});
    _ = env.f("forward-line", .{-@as(i64, @intCast(self.term.rows))});
}

fn getOrAddLastPage(self: *Self, alloc: Allocator, serial: PageSerial) !*MaterializedPage {
    if (self.pages_in_buffer.last) |node| {
        const page: *MaterializedPage = @fieldParentPtr("node", node);
        if (page.serial == serial) return page;
    }

    const page = try alloc.create(MaterializedPage);
    page.* = .{ .serial = serial };
    self.pages_in_buffer.append(&page.node);
    return page;
}

fn clear(self: *Self, alloc: Allocator, env: emacs.Env) !void {
    _ = env.f("erase-buffer", .{});
    self.rows_in_buffer = 0;
    self.render_state.dirty = .full;
    self.clearPages(alloc);
    if (self.render_pin) |p| self.rendered_screen.pages.untrackPin(p);
    self.render_pin = null;

    // Commit any pending resize since we're doing a rebuild anyway.
    try self.commitResize(alloc);

    self.rendered_screen = self.term.screens.active;
    if (!self.rendered_screen.no_scrollback) {
        self.render_pin = try self.rendered_screen.pages.trackPin(
            self.rendered_screen.pages.getTopLeft(.screen),
        );
    }
}

fn clearPages(self: *Self, alloc: Allocator) void {
    while (self.pages_in_buffer.pop()) |n| {
        alloc.destroy(@as(*MaterializedPage, @fieldParentPtr("node", n)));
    }
}

fn evictScrollback(self: *Self, alloc: Allocator, env: emacs.Env) void {
    var evicted_chars: usize = 0;
    var evicted_rows: usize = 0;

    const term_first_page = self.rendered_screen.pages.pages.first.?;
    while (self.pages_in_buffer.first) |n| {
        const first_page: *MaterializedPage = @fieldParentPtr("node", n);
        if (first_page.serial == term_first_page.serial) break;

        evicted_chars += first_page.char_len;
        evicted_rows += first_page.rows;

        _ = self.pages_in_buffer.popFirst();
        alloc.destroy(first_page);
    }

    if (self.pages_in_buffer.first) |n| {
        const first_page: *MaterializedPage = @fieldParentPtr("node", n);
        const term_page_rows = term_first_page.data.size.rows;
        if (term_page_rows < first_page.rows) {
            const diff = first_page.rows - term_first_page.data.size.rows;
            _ = env.f("goto-char", .{1});
            _ = env.f("forward-line", .{diff});

            const point = env.f("point", .{});
            const rows_char_len = env.cast(usize, point) - 1;
            first_page.char_len -|= rows_char_len;
            evicted_chars += rows_char_len;

            first_page.rows -= diff;
            evicted_rows += diff;
        }
    }

    self.rows_in_buffer -|= evicted_rows;
    if (evicted_chars > 0) {
        _ = env.f("delete-region", .{ 1, 1 + evicted_chars });
        self.saved_markers.adjustRegion(1, evicted_chars, 0);
    }
}
