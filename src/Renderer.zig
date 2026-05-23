/// RenderState-based terminal rendering to Emacs buffers.
///
/// Reads rows/cells from the ghostty render state, extracts text and
/// style attributes, and inserts propertized text into the current
/// Emacs buffer.  See `redraw' below for the per-redraw algorithm
/// (pin-based scrollback sync, dirty-row reuse).
const std = @import("std");
const Allocator = std.mem.Allocator;
const emacs = @import("emacs.zig");
const gt = @import("ghostty-vt");
const GhostelTerm = @import("GhostelTerm.zig");
const style_face = @import("style_face.zig");

pub const CellProps = style_face.CellProps;
const formatColor = style_face.formatColor;

const Self = @This();

/// Render state for incremental screen updates.
term: *gt.Terminal,

/// Render state for incremental screen updates.
render_state: gt.RenderState,

/// Tracked pin of the active region.
active_pin: *gt.Pin,

/// The screen that is currently rendered into the buffer.
rendered_screen: *gt.Screen,

/// Number of libghostty rows already materialized into the Emacs buffer.
rows_in_buffer: usize = 0,

/// List of pages materialized in buffer
pages_in_buffer: std.DoublyLinkedList = .{},

/// Any pending resize as `.{cols, rows}`. Resizes are comitted on next redraw.
pending_resize: ?ViewportSize = null,

/// Reusable instance of RowContent to reduce allocations
row: RowContent = .{},

/// Cached font metrics and rendering parameters that affect glyph layout.
/// When any field changes between redraws the viewport is fully invalidated.
font_info: ?FontInfo = null,

/// Bold text coloring configuration.
bold_config: ?gt.Style.BoldColor = null,

const PageSerial = @FieldType(gt.PageList.List.Node, "serial");

const MaterializedPage = struct {
    node: std.DoublyLinkedList.Node = .{},
    serial: PageSerial,
    char_len: usize = 0,
    rows: usize = 0,
};

const FontInfo = struct {
    width: i64,
    height: i64,
    coverage: u32,
    glyph_scale_floor: f64,
};

pub fn init(alloc: Allocator, term: *gt.Terminal) !Self {
    var renderer = Self{
        .term = term,
        .render_state = gt.RenderState.empty,
        .active_pin = try term.screens.active.pages.trackPin(
            term.screens.active.pages.getTopLeft(.screen),
        ),
        .rendered_screen = term.screens.active,
        .pending_resize = .{ .cols = term.cols, .rows = term.rows, .cell_w = 1, .cell_h = 1 },
    };
    try renderer.commitResize(alloc);
    return renderer;
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    self.render_state.deinit(alloc);
    self.row.deinit(alloc);
    self.clearPages(alloc);
    self.rendered_screen.pages.untrackPin(self.active_pin);
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
/// above the active area. `active_pin` tracks the top-left of the active
/// area across redraws; `pages_in_buffer` mirrors libghostty's page list
/// so scrollback eviction can be applied precisely by character count.
///
/// When `force_full_arg` is true, the buffer is cleared and fully rebuilt
/// instead of using the incremental dirty-row path.
pub fn redraw(self: *Self, alloc: Allocator, env: emacs.Env, force_full_arg: bool) !void {
    // Snapshot the buffer's mark across the destructive ops below.  Both
    // paths — full (eraseBuffer / deleteRegion over the viewport) and
    // partial (per-row deleteRegion + insert) — move every marker in the
    // buffer by standard Emacs marker rules.  Point is owned by the
    // renderer and is placed at the TUI cursor on exit, but mark is user
    // state (C-SPC, region commands) and must survive the redraw.  Other
    // markers (e.g. evil's visual-beginning/end) remain the caller's
    // responsibility to preserve in elisp.
    const saved_mark: ?i64 = blk: {
        const pos = env.markerPosition(env.markMarker());
        if (!env.isNotNil(pos)) break :blk null;
        break :blk env.extractInteger(pos);
    };
    defer {
        if (saved_mark) |pos| {
            const pmax = env.extractInteger(env.pointMax());
            const clamped: i64 = if (pos > pmax) pmax else pos;
            _ = env.setMarker(env.markMarker(), env.makeInteger(clamped));
        }
    }

    // If the font metrics or related parameters changed, the cached metrics
    // are no longer valid, so we rebuild.
    const font_info_changed = self.updateFontInfo(env);

    // We always reset scrollback if the number of columns changed
    const cols_changed = if (self.pending_resize) |rz|
        rz.cols != self.term.cols
    else
        false;

    // If the active screen changes, we reset scrollback
    const screen_changed = self.rendered_screen != self.term.screens.active;

    if (force_full_arg or font_info_changed or cols_changed or screen_changed) {
        try self.clear(alloc, env);
    }

    self.gotoActiveStart(env);
    try self.renderToEnd(alloc, env, self.active_pin.*);

    // If we have a pending resize, commit it now and just rerender the active
    // since the scrollback is already up to date.
    if (self.pending_resize != null) {
        try self.commitResize(alloc);
        self.gotoActiveStart(env);
        try self.render(alloc, env, self.term.screens.active.pages.getTopLeft(.active), 0);
    }

    self.evictScrollback(alloc, env);

    try self.renderCursor(env);

    // Update working directory from OSC 7
    if (self.term.getPwd()) |pwd| {
        _ = env.f("ghostel--update-directory", .{pwd});
    }

    self.active_pin.* = self.rendered_screen.pages.getTopLeft(.active);
}

/// Read the default font and rendering parameters from Emacs, compare
/// against the cached values, and signal whether a full invalidation is
/// required.
fn updateFontInfo(self: *Self, env: emacs.Env) bool {
    const new_font = getDefaultFont(env);
    const current_font = env.symbolValue("ghostel--rendered-font");

    const raw_floor = env.symbolValue("ghostel-glyph-scale-floor");
    const floor = std.math.clamp(env.asFloat(raw_floor, 0.0), 0.0, 1.0);

    // Fast path: nothing changed since last redraw.
    if (env.eq(new_font, current_font)) {
        if (self.font_info) |cached| {
            const old_bits: u64 = @bitCast(cached.glyph_scale_floor);
            const new_bits: u64 = @bitCast(floor);
            if (old_bits == new_bits) return false;
        } else {
            return false; // no font before, no font now
        }
    }

    _ = env.set("ghostel--rendered-font", new_font);

    if (env.isNil(new_font)) {
        self.font_info = null;
    } else {
        const default_font_info = env.f("ghostel--query-font-cached", .{new_font});
        // The value is a vector:
        // [ NAME FILENAME PIXEL-SIZE SIZE ASCENT DESCENT SPACE-WIDTH AVERAGE-WIDTH
        //   CAPABILITY ]
        const cell_ascent = env.extractInteger(env.vecGet(default_font_info, 4));
        const cell_descent = env.extractInteger(env.vecGet(default_font_info, 5));

        self.font_info = .{
            .width = env.extractInteger(env.vecGet(default_font_info, 6)),
            .height = cell_ascent + cell_descent,
            .coverage = probeCoverage(env, new_font),
            .glyph_scale_floor = floor,
        };
    }
    return true;
}

fn getDefaultFont(env: emacs.Env) emacs.Value {
    const font = env.f("face-attribute", .{ emacs.sym.default, emacs.sym.@":font" });
    if (env.isNil(env.f("fontp", .{ font, emacs.sym.@"font-object" }))) return env.nil();
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

/// Read the style for the current cell from the render state.
fn readCellProps(self: *Self, cell: *const gt.RenderState.Cell) ?CellProps {
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
    props.hyperlink = cell.raw.hyperlink;
    props.semantic_content = cell.raw.semantic_content;

    return if (props.isDefault(
        self.render_state.colors.foreground,
        self.render_state.colors.background,
    )) null else props;
}

/// Apply face properties to a region of the buffer.
/// Uses (put-text-property START END 'face PLIST).
fn applyProps(env: emacs.Env, start: i64, end: i64, props: CellProps) !void {
    if (start >= end) return;

    const start_val = env.makeInteger(start);
    const end_val = env.makeInteger(end);
    const s = &emacs.sym;

    if (try style_face.buildFacePlist(env, props)) |face| {
        env.putTextProperty(start_val, end_val, "face", face);
    }

    if (props.hyperlink) {
        env.putTextProperty(start_val, end_val, "help-echo", s.@"ghostel--native-link-help-echo");
        env.putTextProperty(start_val, end_val, "mouse-face", s.highlight);
        env.putTextProperty(start_val, end_val, "keymap", env.symbolValue("ghostel-link-map"));
    }

    switch (props.semantic_content) {
        .prompt => env.putTextProperty(start_val, end_val, "ghostel-prompt", env.t()),
        .input => env.putTextProperty(start_val, end_val, "ghostel-input", env.t()),
        else => {},
    }
}

/// Unique identifier that is cheaper to read and compare relative to `CellProps`.
/// We read this first and if it differs from the previous cell, we read the full
/// `CellProps`.
const CellPropKey = packed struct {
    // TODO: Style ID type is not exported from ghostty-vt for some reason.
    //       We should file an issue.
    style_id: @FieldType(gt.page.Cell, "style_id"),
    hyperlink: bool,
    semantic_content: gt.page.Cell.SemanticContent,

    fn fromCell(cell: gt.page.Cell) CellPropKey {
        return .{
            .style_id = cell.style_id,
            .hyperlink = cell.hyperlink,
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
        byte_start: i64,
        byte_end: i64,
        char_start: i64,
        char_end: i64,
        wide: bool,
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

    /// Build text content and style runs for the current row in the iterator.
    /// Style runs use character (codepoint) offsets for Emacs put-text-property.
    ///
    /// Trailing blank cells — spaces with the default cell style — are
    /// trimmed off the end of the row so the Emacs buffer does not carry
    /// libghostty's full-width viewport padding. A cell is NOT blank if
    /// its character is non-space, or if its style has any non-default
    /// attribute (e.g. a colored background, underline, etc.), so visibly-
    /// styled blanks are preserved.
    pub fn build(
        self: *RowContent,
        alloc: Allocator,
        renderer: *Self,
        row: *const gt.RenderState.Row,
        adjustment_threshold: u32,
    ) !void {
        try self.clear();

        // Position at the end of the last non-blank cell; final row length
        // is trimmed back to this. Any run of blank cells past the end is
        // discarded along with their default-style trailing padding.
        var trim_byte_len: usize = 0;
        var trim_char_len: usize = 0;

        var current_prop_key: ?CellPropKey = null;
        var col: usize = 0;
        while (col < row.cells.len) : (col += 1) {
            const cell = row.cells.get(col);
            if (cell.raw.wide == .spacer_tail or cell.raw.wide == .spacer_head) continue;

            // We use a "key" that holds a minimum set of values that are cheap to
            // read and compare to detect style run breaks. Only when we detect a
            // break do we read the cell style, which is a more expensive operation
            // in such a tight loop.
            const prop_key = CellPropKey.fromCell(cell.raw);
            if (prop_key != current_prop_key) {
                try self.runs.append(alloc, .{
                    .start_char = self.char_len,
                    .end_char = self.char_len,
                    .props = readCellProps(renderer, &cell),
                });
                current_prop_key = prop_key;
            }

            const byte_start = self.text.items.len;
            const char_start = self.char_len;

            const codepoint: u21 = if (cell.raw.hasText()) cell.raw.codepoint() else ' ';
            try self.appendCodepoints(alloc, &[1]u21{codepoint});
            if (cell.raw.hasGrapheme()) {
                try self.appendCodepoints(alloc, cell.grapheme);
            }

            // If this is a grapheme cluster, or if the char is not covered by
            // the default font, we register it as needing font glyph adjustment
            // to fit into the monospace grid.
            if (cell.raw.hasGrapheme() or codepoint >= adjustment_threshold) {
                try self.adjust_cells.append(alloc, .{
                    .col = @intCast(col),
                    .byte_start = @intCast(byte_start),
                    .byte_end = @intCast(self.text.items.len),
                    .char_start = @intCast(char_start),
                    .char_end = @intCast(self.char_len),
                    .wide = cell.raw.wide == .wide,
                });
            }

            const last_run = &self.runs.items[self.runs.items.len - 1];
            last_run.end_char = self.char_len;

            // We trim cells that neither have content nor styling
            if (cell.raw.hasText() or last_run.props != null) {
                trim_byte_len = self.text.items.len;
                trim_char_len = self.char_len;
            }
        }

        // Trim trailing blank cells. Cap `prompt_char_len' / input range at the
        // new `char_len' so neither region extends past the trimmed text. Style
        // runs extending past the trim point are clipped by `insertAndStyle' via
        // its `self.row.char_len' cap.
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

fn adjustGlyphs(self: *Self, env: emacs.Env, row_start: i64, row_end: i64) void {
    if (self.row.adjust_cells.items.len == 0) return;
    if (self.font_info == null) return;
    const window = env.f("selected-window", .{});
    if (env.isNil(window)) return;

    for (self.row.adjust_cells.items) |*cell| {
        self.adjustGlyph(env, window, row_start, row_end, cell);
    }
}

fn adjustGlyph(
    self: *Self,
    env: emacs.Env,
    window: emacs.Value,
    row_start: i64,
    row_end: i64,
    cell: *const RowContent.CellInfo,
) void {
    const default_font_info = self.font_info.?;

    const s = emacs.sym;

    const start_val = env.makeInteger(row_start + @as(i64, @intCast(cell.char_start)));
    const end_val = env.makeInteger(row_start + @as(i64, @intCast(cell.char_end)));
    const font = env.f("font-at", .{ start_val, window });
    // TODO: Maybe we should replace the cell with something else if there
    //       is no font. Today, it will just show the missing char glyph,
    //       which will push the line size bigger. This is rare, though.
    //       Most chars are covered by SOME font on the system.
    if (env.isNil(font)) return;

    const font_info = env.f("ghostel--query-font-cached", .{font});
    const ascent = env.extractInteger(env.vecGet(font_info, 4));
    const descent = env.extractInteger(env.vecGet(font_info, 5));
    const height = ascent + descent;

    const glyphs = env.f("font-get-glyphs", .{ font, start_val, end_val });
    if (env.vecSize(glyphs) == 0) return;

    // Each element is a vector containing information of a glyph in this format:
    // [FROM-IDX TO-IDX C CODE WIDTH LBEARING RBEARING ASCENT DESCENT ADJUSTMENT]
    const glyph = env.vecGet(glyphs, 0);
    const width = env.extractInteger(env.vecGet(glyph, 4));
    var char_width: i64 = if (cell.wide) 2 else 1;
    var slot_width = default_font_info.width * char_width;

    // Skip adjustments if size already matches perfectly
    if (width == slot_width and height == default_font_info.height) return;

    // Let's check if we can claim some space after the glyph to be able to render
    // it larger than the cell size while still maintaining alignment.
    const pre_char_width = char_width;
    while (cell.col + char_width < self.term.cols) : ({
        char_width += 1;
        slot_width = default_font_info.width * char_width;
    }) {
        const cell_aspect = @as(f64, @floatFromInt(slot_width)) / @as(f64, @floatFromInt(default_font_info.height));
        const glyph_aspect = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(height));
        // If the aspect of the glyph is narrower than that of the cell, we're done
        if (glyph_aspect < cell_aspect) break;

        const claim_pos = row_start + cell.char_end + (char_width - pre_char_width);
        // Lines are right-trimmed of trailing spaces, so positions at and past
        // the newline represent empty space we can freely claim.
        if (claim_pos >= row_end - 1) continue;

        const c = env.extractInteger(env.f("char-after", .{claim_pos}));
        if (c == ' ') {
            env.putTextProperty(
                claim_pos,
                claim_pos + 1,
                "display",
                env.cons(s.space, env.list(.{ s.@":width", 0 })),
            );
        } else {
            break;
        }
    }

    // We add a fudge factor of +1 to the denominator to ensure fit
    const scale_width = @as(f64, @floatFromInt(slot_width)) / @as(f64, @floatFromInt(width + 1));
    const scale_height = @as(f64, @floatFromInt(default_font_info.height)) / @as(f64, @floatFromInt(height + 1));
    const computed_scale = @min(scale_width, scale_height);
    const scale = @max(computed_scale, default_font_info.glyph_scale_floor);

    const min_width_spec = env.list(.{ s.@"min-width", env.list(.{char_width}) });
    const scale_spec = env.list(.{ s.height, scale });
    const display_spec = env.list(.{ min_width_spec, scale_spec });
    _ = env.f("put-text-property", .{ start_val, end_val, s.display, display_spec });
}

/// Insert row text and apply property runs.
fn insertRow(self: *Self, alloc: Allocator, env: emacs.Env, row: *const gt.RenderState.Row) !usize {
    try self.row.build(
        alloc,
        self,
        row,
        if (self.font_info) |f| f.coverage else std.math.maxInt(u32),
    );

    const row_start = env.extractInteger(env.point());
    env.insert(self.row.text.items);
    const row_end = env.extractInteger(env.point());

    for (self.row.runs.items) |*run| {
        if (run.end_char <= run.start_char) continue;

        const prop_start = row_start + @as(i64, @intCast(run.start_char));
        const prop_end = row_start + @as(i64, @intCast(run.end_char));
        if (run.props) |props| {
            try applyProps(env, prop_start, prop_end, props);
        }
    }

    self.adjustGlyphs(env, row_start, row_end);

    if (row.raw.wrap) {
        // Mark newlines from soft-wrapped rows so copy mode can filter them
        const point = env.point();
        const nl_pos = env.makeInteger(env.extractInteger(point) - 1);
        env.putTextProperty(nl_pos, point, "ghostel-wrap", env.t());
    }

    return @intCast(row_end - row_start);
}

/// Convert a terminal column to an Emacs character offset by iterating
/// the row's cells.  Returns `true` and positions point on success;
/// `false` if the cell data is unavailable (caller should fall back to
/// `move-to-column`).
///
/// This avoids relying on Emacs' `char-width`, which can disagree with
/// the terminal's column width for certain characters (e.g. box-drawing
/// glyphs on CJK/pgtk systems where `char-width` returns 2 but the
/// terminal treats them as single-width).
fn positionCursorByCell(self: *Self, env: emacs.Env, cx: u16, cy: u16) !bool {
    if (cx == 0) return true; // already at column 0

    // Walk cells 0..cx-1, counting Emacs characters.
    var col: u16 = 0;
    var char_count: i64 = 0;
    const cells = &self.render_state.row_data.items(.cells)[cy];
    while (col < cx) : (col += 1) {
        const cell = cells.get(col);
        if (cell.raw.wide == .spacer_head or cell.raw.wide == .spacer_tail) continue;

        const graphemes_len = 1 + if (cell.raw.hasGrapheme()) cell.grapheme.len else 0;
        char_count += @intCast(graphemes_len);
    }

    // Cap at end of line so we never jump past it into the next row
    // (can happen when cursor is on a trimmed trailing blank).
    const pt = env.extractInteger(env.point());
    const eol = env.extractInteger(env.lineEndPosition());
    const max_chars = eol - pt;
    env.gotoChar(pt + @min(char_count, max_chars));
    return true;
}

pub fn render(
    self: *Self,
    alloc: Allocator,
    env: emacs.Env,
    pin: gt.Pin,
    skip: usize,
) !void {
    self.term.screens.active.pages.scroll(.{ .pin = pin });
    try self.render_state.update(alloc, self.term);

    if (self.render_state.dirty != .false) {
        // Set buffer default face
        var fg_hex: [7]u8 = undefined;
        var bg_hex: [7]u8 = undefined;
        _ = env.f("ghostel--set-buffer-face", .{
            formatColor(self.render_state.colors.foreground, &fg_hex),
            formatColor(self.render_state.colors.background, &bg_hex),
        });

        var i: u16 = 0;
        const row_dirty = self.render_state.row_data.items(.dirty);
        while (i < self.render_state.rows) : ({
            // Clear per-row dirty flag
            row_dirty[i] = false;
            i += 1;
        }) {
            if (i < skip) continue;

            const dirty_row = self.render_state.dirty == .full or row_dirty[i];
            // Only process dirty rows, or there's no existing row
            const eob = env.eobp();
            if (dirty_row or eob) {
                const row = self.render_state.row_data.get(i);
                const page = try self.getOrAddLastPage(alloc, row.pin.node.serial);

                if (eob) {
                    // We're adding one line since we're at the end of the buffer
                    self.rows_in_buffer += 1;
                    page.rows += 1;
                } else {
                    // Line is dirty and we're not at the end of the buffer,
                    // delete the old line.
                    const old_line_start = env.point();
                    const old_line_end = env.lineBeginningPosition2();
                    const old_line_len = env.extractInteger(old_line_end) - env.extractInteger(old_line_start);
                    page.char_len -= @intCast(old_line_len);
                    env.deleteRegion(old_line_start, old_line_end);
                }

                page.char_len += try self.insertRow(alloc, env, &row);
            } else {
                _ = env.forwardLine(1);
            }
        }

        // Reset dirty state
        self.render_state.dirty = .false;
    }
}

fn renderCursor(self: *Self, env: emacs.Env) !void {
    // Walk to the current viewport start
    self.gotoActiveStart(env);
    const active_start_int = env.extractInteger(env.point());

    // Position cursor (active-relative row -> absolute line).
    // X/Y are only valid when HAS_VALUE is true, so query separately
    // to avoid stopping the style batch above on NO_VALUE.
    if (self.render_state.cursor.viewport) |vp| {
        env.gotoChar(active_start_int);
        _ = env.forwardLine(@as(i64, vp.y));
        if (!try self.positionCursorByCell(env, vp.x, vp.y)) {
            env.moveToColumn(@as(i64, vp.x));
        }

        _ = env.set("ghostel--cursor-pos", env.cons(vp.x, vp.y));
        _ = env.set("ghostel--cursor-char-pos", env.point());
    } else {
        _ = env.set("ghostel--cursor-pos", env.nil());
        _ = env.set("ghostel--cursor-char-pos", env.nil());
    }

    _ = env.f("ghostel--set-cursor-style", .{
        @intFromEnum(self.render_state.cursor.visual_style),
        if (self.render_state.cursor.visible) env.t() else env.nil(),
    });
}

// Render all pages from start_pin through the end of the active area,
// one viewport-sized chunk per page.
fn renderToEnd(self: *Self, alloc: Allocator, env: emacs.Env, start_pin: gt.Pin) !void {
    const pages = &self.term.screens.active.pages;
    var p: ?gt.Pin = start_pin;
    while (p) |pin| : (p = pin.down(self.term.rows)) {
        var overflow: usize = 0;
        if (pin.node == pages.pages.last) {
            overflow = (pin.y + self.term.rows) -| pin.node.data.size.rows;
        }
        try self.render(alloc, env, pin, overflow);
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
    env.gotoChar(env.pointMax());
    _ = env.forwardLine(-@as(i64, @intCast(self.term.rows)));
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
    env.eraseBuffer();
    self.rows_in_buffer = 0;
    self.render_state.dirty = .full;
    self.clearPages(alloc);

    self.rendered_screen.pages.untrackPin(self.active_pin);

    // Commit any pending resize since we're doing a rebuild anyway.
    try self.commitResize(alloc);

    self.rendered_screen = self.term.screens.active;
    self.active_pin = try self.rendered_screen.pages.trackPin(
        self.rendered_screen.pages.getTopLeft(.screen),
    );
}

fn clearPages(self: *Self, alloc: Allocator) void {
    while (self.pages_in_buffer.pop()) |n| {
        alloc.destroy(@as(*MaterializedPage, @fieldParentPtr("node", n)));
    }
}

fn evictScrollback(self: *Self, alloc: Allocator, env: emacs.Env) void {
    const term_first_page = self.term.screens.active.pages.pages.first.?;
    var evicted_chars: usize = 0;
    while (self.pages_in_buffer.first) |n| {
        const first_page: *MaterializedPage = @fieldParentPtr("node", n);
        if (first_page.serial == term_first_page.serial) break;
        evicted_chars += first_page.char_len;
        self.rows_in_buffer -= first_page.rows;
        _ = self.pages_in_buffer.popFirst();
        alloc.destroy(first_page);
    }
    if (evicted_chars > 0) env.deleteRegion(1, 1 + evicted_chars);

    if (self.pages_in_buffer.first) |n| {
        const first_page: *MaterializedPage = @fieldParentPtr("node", n);
        const term_page_rows = term_first_page.data.size.rows;
        if (term_page_rows < first_page.rows) {
            const diff = first_page.rows - term_first_page.data.size.rows;
            env.gotoChar(1);
            _ = env.forwardLine(diff);

            const point = env.point();
            env.deleteRegion(1, point);
            const deleted_chars = env.extractInteger(point) - 1;
            first_page.char_len -= @intCast(deleted_chars);
            first_page.rows -= diff;
            self.rows_in_buffer -= diff;
        }
    }
}
