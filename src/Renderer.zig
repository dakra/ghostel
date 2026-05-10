/// RenderState-based terminal rendering to Emacs buffers.
///
/// Reads rows/cells from the ghostty render state, extracts text and
/// style attributes, and inserts propertized text into the current
/// Emacs buffer.  See `redraw' below for the per-redraw algorithm
/// (viewport parking, scrollback sync, dirty-row reuse).
const std = @import("std");
const emacs = @import("emacs.zig");
const gt = @import("ghostty.zig");
const Terminal = @import("terminal.zig");

const FixedArrayList = @import("fixed_array_list.zig").FixedArrayList;

const Self = @This();

/// Render state for incremental screen updates.
render_state: gt.RenderState,

/// Reusable row iterator (populated during redraw).
row_iterator: gt.RenderStateRowIterator,

/// Reusable row cells handle (populated during redraw).
row_cells: gt.RenderStateRowCells,

/// Number of libghostty rows already materialized into the Emacs buffer. Polled
/// on each redraw; kept in sync by appending newly-scrolled-off rows and
/// trimming rows evicted by libghostty's scrollback cap.
rows_in_buffer: usize = 0,

/// Terminal viewport dimensions.
size: ViewportSize,

/// Any pending resize as `.{cols, rows}`. Resizes are comitted on next redraw.
pending_resize: ?ViewportSize = null,

/// Reusable instance of RowContent to reduce allocations
row: RowContent = .{},

font_info: ?FontInfo = null,

const FontInfo = struct {
    width: i64,
    height: i64,
    coverage: u32,
};

pub fn init(cols: u16, rows: u16) !Self {
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

    return .{
        .render_state = render_state,
        .row_iterator = row_iterator,
        .row_cells = row_cells,
        .size = .{ .cols = cols, .rows = rows },
    };
}

pub fn deinit(self: *Self) void {
    gt.c.ghostty_render_state_row_cells_free(self.row_cells);
    gt.c.ghostty_render_state_row_iterator_free(self.row_iterator);
    gt.c.ghostty_render_state_free(self.render_state);
    self.row.deinit();
}

pub fn resize(self: *Self, cols: u16, rows: u16) void {
    self.pending_resize = .{ .cols = cols, .rows = rows };
}

/// Redraw the terminal into the current Emacs buffer.
///
/// The Emacs buffer is a permanent record: all materialized scrollback sits
/// above the active viewport and is never evicted, even when libghostty
/// rotates rows out at the scrollback cap.
///
/// Detection relies on parking the libghostty viewport at `max_offset - 1`
/// at the end of every render (see bottom of this function).  On the next
/// call the parked position tells us two things:
///   - If scrollback was cleared, the viewport will have snapped back to the
///     bottom (`offset + len == total`), so we erase and rebuild.
///   - Otherwise, advancing the viewport by 1 lands exactly at the new
///     active area, and `total - offset` tells us how many rows to render.
///
/// When `force_full` is true, the viewport region is fully re-rendered
/// instead of using the incremental dirty-row path.
pub fn redraw(self: *Self, env: emacs.Env, term: *Terminal, force_full_arg: bool) !void {
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

    const scrollbar = try term.getScrollbar();

    // If the font changed, the font metrics are no longer valid, so we rebuild.
    const font_changed = self.updateFontInfo(env);

    // We always reset scrollback if the number of columns changed
    const cols_changed = if (self.pending_resize) |rz| rz.cols != self.size.cols else false;

    // If we had some scrollback but the scrollbar was reset from the parked
    // MAX - 1 position, that indicates that libghostty cleared its scrollback
    // and we follow after by clearing too.
    const had_scrollback = self.rows_in_buffer > scrollbar.len;
    const scrollbar_reset = had_scrollback and scrollbar.len + scrollbar.offset == scrollbar.total;

    // If we had some scrollback but the scrollbar ended up at offset == 0, that
    // means that we got so much scrolling that we scrolled all the way up to the
    // cap and do not know how much we missed.
    const scrollbar_hit_cap = had_scrollback and scrollbar.offset == 0;

    var force_full = false;
    if (force_full_arg or font_changed or cols_changed or scrollbar_reset or scrollbar_hit_cap) {
        env.eraseBuffer();
        // Commit any pending resize since we're doing a rebuild anyway.
        self.commitResize(term);

        self.rows_in_buffer = 0;
        force_full = true;
    }

    // Unpark the viewport. When we have scrollback the viewport is sitting at
    // `max_offset - 1`; advance by 1 to reach the old active area, which is
    // also where the Emacs buffer currently ends. When we have no scrollback
    // there was no parking, so go to the top instead.
    if (self.rows_in_buffer > self.size.rows) {
        term.scrollViewport(gt.SCROLL_DELTA, 1);
        env.gotoChar(env.pointMax());
        _ = env.forwardLine(-@as(i64, @intCast(scrollbar.len)));
    } else {
        term.scrollViewport(gt.SCROLL_TOP, 0);
        env.gotoChar(env.pointMin());
    }

    const rendered_rows = try self.renderToEnd(env, term, force_full);
    // Now that we rendered, even if we cleared the buffer above, we now have at
    // least the rows in the active area:
    self.rows_in_buffer = @max(self.rows_in_buffer, self.size.rows);
    // But we might also have added scrollback rows - that is, rows that we
    // rendered that was not active area. Guard the subtraction: when
    // renderToEnd is a no-op (scrollbar.len == 0 or empty range) it returns 0,
    // and there are no new scrollback rows to add.
    if (rendered_rows > self.size.rows) {
        self.rows_in_buffer += rendered_rows - self.size.rows;
    }

    // If we have a pending resize, commit it now and just rerender the active
    // since the scrollback is already up to date.
    if (self.pending_resize != null) {
        self.commitResize(term);
        term.scrollViewport(gt.SCROLL_BOTTOM, 0);
        self.gotoActiveStart(env);
        try self.render(env, term, 0, false);
        // There is now at least self.size.rows number of rows
        self.rows_in_buffer = @max(self.rows_in_buffer, self.size.rows);
    }

    // Evict old scrollback if libghostty also did
    const libghostty_rows = try term.getTotalRows();
    if (libghostty_rows < self.rows_in_buffer) {
        env.gotoChar(env.pointMin());
        _ = env.forwardLine(@as(i64, @intCast(self.rows_in_buffer - libghostty_rows)));
        env.deleteRegion(env.pointMin(), env.point());
        self.rows_in_buffer = libghostty_rows;
    }

    try self.renderCursor(env);

    // Update working directory from OSC 7
    if (try term.getPwd()) |pwd| {
        _ = env.f("ghostel--update-directory", .{pwd});
    }

    // Park the viewport one row above the bottom. On the next render, if
    // libghostty has cleared its scrollback the viewport will have snapped back
    // to the bottom (`offset + len == total`), which we treat as the rebuild
    // signal. If scrollback only grew, the parked position naturally points at
    // the old active area, and advancing by 1 reaches the new one.
    term.scrollViewport(gt.SCROLL_BOTTOM, 0);
    term.scrollViewport(gt.SCROLL_DELTA, -1);
}

fn updateFontInfo(self: *Self, env: emacs.Env) bool {
    const new_font = getDefaultFont(env);
    const current_font = env.symbolValue("ghostel--rendered-font");
    if (env.eq(new_font, current_font)) return false;

    _ = env.set("ghostel--rendered-font", new_font);

    if (env.isNil(new_font)) {
        self.font_info = null;
    } else {
        const default_font_info = env.f("query-font", .{new_font});
        // The value is a vector:
        // [ NAME FILENAME PIXEL-SIZE SIZE ASCENT DESCENT SPACE-WIDTH AVERAGE-WIDTH
        //   CAPABILITY ]
        const cell_ascent = env.extractInteger(env.vecGet(default_font_info, 4));
        const cell_descent = env.extractInteger(env.vecGet(default_font_info, 5));

        self.font_info = .{
            .width = env.extractInteger(env.vecGet(default_font_info, 6)),
            .height = cell_ascent + cell_descent,
            .coverage = probeCoverage(env, new_font),
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

const ViewportSize = struct { cols: u16, rows: u16 };

fn colorEql(a: ?gt.ColorRgb, b: ?gt.ColorRgb) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.r == b.?.r and a.?.g == b.?.g and a.?.b == b.?.b;
}

/// Blend a foreground color toward a background color to produce a "dim" effect.
/// Uses ~65% foreground / ~35% background weighting.
fn dimColor(fg: gt.ColorRgb, bg: gt.ColorRgb) gt.ColorRgb {
    return .{
        .r = @intCast((@as(u16, fg.r) * 166 + @as(u16, bg.r) * 90) / 256),
        .g = @intCast((@as(u16, fg.g) * 166 + @as(u16, bg.g) * 90) / 256),
        .b = @intCast((@as(u16, fg.b) * 166 + @as(u16, bg.b) * 90) / 256),
    };
}

/// Format an RGB color as "#RRGGBB" into a buffer.
fn formatColor(color: gt.ColorRgb, buf: *[7]u8) []const u8 {
    const hex = "0123456789abcdef";
    buf[0] = '#';
    buf[1] = hex[color.r >> 4];
    buf[2] = hex[color.r & 0xf];
    buf[3] = hex[color.g >> 4];
    buf[4] = hex[color.g & 0xf];
    buf[5] = hex[color.b >> 4];
    buf[6] = hex[color.b & 0xf];
    return buf[0..7];
}

/// Read the style for the current cell from the render state.
fn readCellProps(cells: gt.RenderStateRowCells, key: CellPropKey) !?CellProps {
    var props: CellProps = .{};

    props.fg = gt.rs_row_cells.get(gt.ColorRgb, cells, gt.RS_CELLS_DATA_FG_COLOR) catch |err| switch (err) {
        gt.Error.InvalidValue => null,
        else => return err,
    };
    props.bg = gt.rs_row_cells.get(gt.ColorRgb, cells, gt.RS_CELLS_DATA_BG_COLOR) catch |err| switch (err) {
        gt.Error.InvalidValue => null,
        else => return err,
    };

    // Read style attributes
    if (try gt.rs_row_cells.getOpt(gt.Style, cells, gt.RS_CELLS_DATA_STYLE)) |gs| {
        props.bold = gs.bold;
        props.italic = gs.italic;
        props.faint = gs.faint;
        props.underline = gs.underline;
        props.strikethrough = gs.strikethrough;
        props.inverse = gs.inverse;

        // Underline color
        if (gs.underline_color.tag == gt.c.GHOSTTY_STYLE_COLOR_RGB) {
            props.underline_color = gs.underline_color.value.rgb;
        }
    }

    props.hyperlink = key.hyperlink;
    props.prompt = key.prompt;
    props.input = key.input;

    return if (props.isDefault()) null else props;
}

/// Apply face properties to a region of the buffer.
/// Uses (put-text-property START END 'face PLIST).
fn applyProps(env: emacs.Env, start: i64, end: i64, props: CellProps, default_colors: *const BgFg) !void {
    if (start >= end) return;

    var face_props: FixedArrayList(emacs.Value, 32) = .{};
    const start_val = env.makeInteger(start);
    const end_val = env.makeInteger(end);

    var fg_buf: [7]u8 = undefined;
    var bg_buf: [7]u8 = undefined;
    var dim_buf: [7]u8 = undefined;

    const bg = props.bg orelse default_colors.bg;
    const fg = props.fg orelse default_colors.fg;
    const effective_fg = if (props.inverse) bg else fg;
    const effective_bg = if (props.inverse) fg else bg;

    const s = &emacs.sym;

    if (props.faint) {
        // Dim text: blend foreground toward background to reduce intensity.
        // Always set :foreground since we modify the color itself.
        const dimmed = dimColor(effective_fg, effective_bg);
        const dim_str = formatColor(dimmed, &dim_buf);
        try face_props.append(s.@":foreground");
        try face_props.append(env.makeString(dim_str));
    } else if (!colorEql(props.fg, null) or props.inverse) {
        const fg_str = formatColor(effective_fg, &fg_buf);
        try face_props.append(s.@":foreground");
        try face_props.append(env.makeString(fg_str));
    }

    if (!colorEql(props.bg, null) or props.inverse) {
        const bg_str = formatColor(effective_bg, &bg_buf);
        try face_props.append(s.@":background");
        try face_props.append(env.makeString(bg_str));
    }

    if (props.bold) {
        try face_props.append(s.@":weight");
        try face_props.append(s.bold);
    }

    if (props.italic) {
        try face_props.append(s.@":slant");
        try face_props.append(s.italic);
    }

    if (props.underline != 0) {
        try face_props.append(s.@":underline");
        if (props.underline == 1 and props.underline_color == null) {
            try face_props.append(env.t());
        } else {
            var ul_props: FixedArrayList(emacs.Value, 4) = .{};

            try ul_props.append(s.@":style");
            try ul_props.append(switch (props.underline) {
                3 => s.wave,
                2 => s.@"double-line",
                4 => s.dot,
                5 => s.dash,
                else => s.line,
            });

            if (props.underline_color) |uc| {
                var uc_buf: [7]u8 = undefined;
                try ul_props.append(s.@":color");
                try ul_props.append(env.makeString(formatColor(uc, &uc_buf)));
            }

            try face_props.append(env.funcall(s.list, ul_props.items()));
        }
    }

    if (props.strikethrough) {
        try face_props.append(s.@":strike-through");
        try face_props.append(env.t());
    }

    if (face_props.len > 0) {
        const face = env.funcall(s.list, face_props.items());
        env.putTextProperty(start_val, end_val, s.face, face);
    }

    if (props.hyperlink) {
        env.putTextProperty(start_val, end_val, s.@"help-echo", s.@"ghostel--native-link-help-echo");
        env.putTextProperty(start_val, end_val, s.@"mouse-face", s.highlight);
        env.putTextProperty(start_val, end_val, s.keymap, env.symbolValue("ghostel-link-map"));
    }

    if (props.prompt) {
        env.putTextProperty(start_val, end_val, emacs.sym.@"ghostel-prompt", env.t());
    }

    if (props.input) {
        env.putTextProperty(start_val, end_val, emacs.sym.@"ghostel-input", env.t());
    }
}

/// Check if the current row in the iterator is soft-wrapped.
fn isRowWrapped(self: *Self) !bool {
    const raw_row = try gt.rs_row.get(gt.c.GhosttyRow, self.row_iterator, gt.c.GHOSTTY_RENDER_STATE_ROW_DATA_RAW);
    return try gt.row.get(bool, raw_row, gt.ROW_DATA_WRAP);
}

/// Properties for a run of cells.
const CellProps = struct {
    fg: ?gt.ColorRgb = null,
    bg: ?gt.ColorRgb = null,
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    underline: c_int = 0, // 0=none, 1=single, 2=double, 3=curly, 4=dotted, 5=dashed
    underline_color: ?gt.ColorRgb = null,
    strikethrough: bool = false,
    inverse: bool = false,
    hyperlink: bool = false,
    prompt: bool = false,
    input: bool = false,

    fn isDefault(self: CellProps) bool {
        return std.meta.eql(self, .{});
    }
};

/// Unique identifier that is cheaper to read and compare relative to `CellProps`.
/// We read this first and if it differs from the previous cell, we read the full
/// `CellProps`.
const CellPropKey = struct {
    style_id: ?gt.c.GhosttyStyleId,
    hyperlink: bool,
    prompt: bool,
    input: bool,
};

pub const RowContent = struct {
    const allocator = std.heap.c_allocator;

    const Run = struct {
        start_char: usize,
        end_char: usize,
        props: ?CellProps,
    };

    const CellInfo = struct {
        byte_start: usize,
        byte_len: usize,
        char_start: usize,
        char_len: usize,
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

    /// Reusable grapheme buffer
    graphemes: std.ArrayList(u32) = .empty,

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
        row: gt.RenderStateRowIterator,
        row_cells: *gt.RenderStateRowCells,
        adjustment_threshold: u32,
    ) !void {
        try self.clear();

        // Position at the end of the last non-blank cell; final row length
        // is trimmed back to this. Any run of blank cells past the end is
        // discarded along with their default-style trailing padding.
        var trim_byte_len: usize = 0;
        var trim_char_len: usize = 0;

        const raw_row = try gt.rs_row.get(gt.c.GhosttyRow, row, gt.c.GHOSTTY_RENDER_STATE_ROW_DATA_RAW);
        const row_hints = try readRowHints(raw_row);

        var current_prop_key: ?CellPropKey = null;
        try gt.rs_row.read(row, gt.RS_ROW_DATA_CELLS, row_cells);
        while (gt.rs_row_cells_next(row_cells.*)) {
            const raw_cell = try gt.rs_row_cells.get(
                gt.c.GhosttyCell,
                row_cells.*,
                gt.c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
            );
            const wide = try gt.cell.get(c_int, raw_cell, gt.c.GHOSTTY_CELL_DATA_WIDE);
            if (wide == gt.c.GHOSTTY_CELL_WIDE_SPACER_TAIL or wide == gt.c.GHOSTTY_CELL_WIDE_SPACER_HEAD) continue;

            const graphemes_len = try gt.rs_row_cells.get(u32, row_cells.*, gt.RS_CELLS_DATA_GRAPHEMES_LEN);
            if (graphemes_len == 0) {
                self.graphemes.clearRetainingCapacity();
                try self.graphemes.append(RowContent.allocator, ' ');
            } else {
                try self.graphemes.resize(RowContent.allocator, graphemes_len);
                try gt.rs_row_cells.read(row_cells.*, gt.RS_CELLS_DATA_GRAPHEMES_BUF, self.graphemes.items.ptr);
            }

            // We use a "key" that holds a minimum set of values that are cheap to
            // read and compare to detect style run breaks. Only when we detect a
            // break do we read the cell style, which is a more expensive operation
            // in such a tight loop.
            var prop_key = CellPropKey{
                .style_id = null,
                .hyperlink = false,
                .prompt = false,
                .input = false,
            };

            if (row_hints.row_semantic_prompt != gt.c.GHOSTTY_ROW_SEMANTIC_NONE) {
                const semantic_prompt = try gt.cell.get(
                    gt.c.GhosttyCellSemanticContent,
                    raw_cell,
                    gt.c.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT,
                );
                prop_key.prompt = semantic_prompt == gt.c.GHOSTTY_CELL_SEMANTIC_PROMPT;
                prop_key.input = semantic_prompt == gt.c.GHOSTTY_CELL_SEMANTIC_INPUT;
            }

            if (row_hints.may_have_style) {
                prop_key.style_id = try gt.cell.get(gt.c.GhosttyStyleId, raw_cell, gt.c.GHOSTTY_CELL_DATA_STYLE_ID);
            }

            if (row_hints.may_have_hyperlink) {
                prop_key.hyperlink = try gt.cell.get(bool, raw_cell, gt.c.GHOSTTY_CELL_DATA_HAS_HYPERLINK);
            }

            if (!std.meta.eql(@as(?CellPropKey, prop_key), current_prop_key)) {
                try self.runs.append(RowContent.allocator, .{
                    .start_char = self.char_len,
                    .end_char = self.char_len,
                    .props = try readCellProps(row_cells.*, prop_key),
                });
                current_prop_key = prop_key;
            }

            const byte_start = self.text.items.len;
            const char_start = self.char_len;

            try self.appendGraphemeCluster(self.graphemes.items);

            // If this is a grapheme cluster, or if the char is not covered by
            // the default font, we register it as needing font glyph adjustment
            // to fit into the monospace grid.
            if (self.graphemes.items.len > 1 or self.graphemes.items[0] >= adjustment_threshold) {
                try self.adjust_cells.append(RowContent.allocator, .{
                    .byte_start = byte_start,
                    .byte_len = self.text.items.len - byte_start,
                    .char_start = char_start,
                    .char_len = self.char_len - char_start,
                    .wide = wide == gt.c.GHOSTTY_CELL_WIDE_WIDE,
                });
            }

            const last_run = &self.runs.items[self.runs.items.len - 1];
            last_run.end_char = self.char_len;

            // We trim cells that neither have content nor styling
            if (graphemes_len > 0 or last_run.props != null) {
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

        try self.text.append(RowContent.allocator, '\n');
    }

    pub fn deinit(self: *RowContent) void {
        self.text.deinit(allocator);
        self.adjust_cells.deinit(allocator);
        self.runs.deinit(allocator);
        self.graphemes.deinit(allocator);
    }

    fn clear(self: *RowContent) !void {
        self.text.clearRetainingCapacity();
        self.adjust_cells.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
        self.char_len = 0;
    }

    fn appendGraphemeCluster(self: *RowContent, cluster: []const u32) !void {
        for (cluster) |cp| {
            const codepoint: u21 = @intCast(cp);
            const slice = try self.text.addManyAsSlice(
                allocator,
                try std.unicode.utf8CodepointSequenceLength(codepoint),
            );
            _ = try std.unicode.utf8Encode(codepoint, slice);
            self.char_len += 1;
        }
    }
};

const RowHints = struct {
    row_semantic_prompt: gt.c.GhosttyRowSemanticPrompt,
    may_have_hyperlink: bool,
    may_have_style: bool,
};

fn readRowHints(row: gt.c.GhosttyRow) !RowHints {
    const row_semantic_prompt, const maybe_hyperlink, const maybe_style = try gt.row.getMulti(row, &[_]gt.Multi{
        .{ gt.c.GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, gt.c.GhosttyRowSemanticPrompt },
        .{ gt.c.GHOSTTY_ROW_DATA_HYPERLINK, bool },
        .{ gt.c.GHOSTTY_ROW_DATA_STYLED, bool },
    });

    return .{
        .row_semantic_prompt = row_semantic_prompt,
        .may_have_hyperlink = maybe_hyperlink,
        .may_have_style = maybe_style,
    };
}

fn adjustGlyphs(self: *Self, env: emacs.Env, row_start: i64) void {
    if (self.row.adjust_cells.items.len == 0) return;
    if (self.font_info == null) return;
    const default_font_info = self.font_info.?;

    const s = emacs.sym;

    const window = env.f("selected-window", .{});
    if (env.isNil(window)) return;

    for (self.row.adjust_cells.items) |cell| {
        const start_val = env.makeInteger(row_start + @as(i64, @intCast(cell.char_start)));
        const end_val = env.makeInteger(row_start + @as(i64, @intCast(cell.char_start + cell.char_len)));
        const font = env.f("font-at", .{ start_val, window });
        // TODO: Maybe we should replace the cell with something else if there
        //       is no font. Today, it will just show the missing char glyph,
        //       which will push the line size bigger. This is rare, though.
        //       Most chars are covered by SOME font on the system.
        if (env.isNil(font)) continue;

        const font_info = env.f("query-font", .{font});
        const ascent = env.extractInteger(env.vecGet(font_info, 4));
        const descent = env.extractInteger(env.vecGet(font_info, 5));
        const height = ascent + descent;

        const glyphs = env.f("font-get-glyphs", .{ font, start_val, end_val });
        if (env.vecSize(glyphs) == 0) continue;

        // Each element is a vector containing information of a glyph in this format:
        // [FROM-IDX TO-IDX C CODE WIDTH LBEARING RBEARING ASCENT DESCENT ADJUSTMENT]
        const glyph = env.vecGet(glyphs, 0);
        const width = env.extractInteger(env.vecGet(glyph, 4));
        const num_cells: i64 = if (cell.wide) 2 else 1;

        const max_width = default_font_info.width * num_cells;

        // Skip adjustments if size already matches perfectly
        if (max_width == width and default_font_info.height == height) continue;

        // We add a fudge factor of +1 to the denominator to ensure fit
        const scale_width = @as(f64, @floatFromInt(max_width)) / @as(f64, @floatFromInt(width + 1));
        const scale_height = @as(f64, @floatFromInt(default_font_info.height)) / @as(f64, @floatFromInt(height + 1));
        const scale = @min(scale_width, scale_height);

        const min_width_spec = env.list(.{ s.@"min-width", env.list(.{num_cells}) });
        const scale_spec = env.list(.{ s.height, scale });
        const display_spec = env.list(.{ min_width_spec, scale_spec });
        _ = env.f("put-text-property", .{ start_val, end_val, s.display, display_spec });
    }
}

/// Insert row text and apply property runs.
fn insertRow(
    self: *Self,
    env: emacs.Env,
    default_colors: *const BgFg,
) !void {
    try self.row.build(
        self.row_iterator,
        &self.row_cells,
        if (self.font_info) |f| f.coverage else std.math.maxInt(u32),
    );

    const row_start = env.extractInteger(env.point());
    env.insert(self.row.text.items);

    for (self.row.runs.items) |*run| {
        if (run.end_char <= run.start_char) continue;

        const prop_start = row_start + @as(i64, @intCast(run.start_char));
        const prop_end = row_start + @as(i64, @intCast(run.end_char));
        if (run.props) |props| {
            try applyProps(env, prop_start, prop_end, props, default_colors);
        }
    }

    self.adjustGlyphs(env, row_start);

    if (try self.isRowWrapped()) {
        // Mark newlines from soft-wrapped rows so copy mode can filter them
        const point = env.point();
        const nl_pos = env.makeInteger(env.extractInteger(point) - 1);
        env.putTextProperty(nl_pos, point, emacs.sym.@"ghostel-wrap", env.t());
    }
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

    try gt.rs.read(self.render_state, gt.RS_DATA_ROW_ITERATOR, &self.row_iterator);

    // Advance iterator to cursor row cy.
    {
        var ri: u16 = 0;
        while (ri <= cy) : (ri += 1) {
            if (!gt.rs_row_next(self.row_iterator)) {
                return false;
            }
        }
    }

    try gt.rs_row.read(self.row_iterator, gt.RS_ROW_DATA_CELLS, &self.row_cells);

    // Walk cells 0..cx-1, counting Emacs characters.
    var col: u16 = 0;
    var char_count: i64 = 0;
    while (col < cx) : (col += 1) {
        if (!gt.rs_row_cells_next(self.row_cells)) break;

        const graphemes_len = try gt.rs_row_cells.get(u32, self.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_LEN);
        if (graphemes_len == 0) {
            // Spacer tails produce no Emacs character.
            const raw_cell = try gt.rs_row_cells.get(gt.c.GhosttyCell, self.row_cells, gt.c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW);
            const wide = try gt.cell.get(c_int, raw_cell, gt.c.GHOSTTY_CELL_DATA_WIDE);
            if (wide == gt.c.GHOSTTY_CELL_WIDE_SPACER_TAIL) {
                continue;
            }
            char_count += 1; // empty cell → space
        } else {
            char_count += @intCast(@min(graphemes_len, 16));
        }
    }

    // Cap at end of line so we never jump past it into the next row
    // (can happen when cursor is on a trimmed trailing blank).
    const pt = env.extractInteger(env.point());
    const eol = env.extractInteger(env.lineEndPosition());
    const max_chars = eol - pt;
    env.gotoCharN(pt + @min(char_count, max_chars));
    return true;
}

const BgFg = struct {
    bg: gt.ColorRgb,
    fg: gt.ColorRgb,
};

fn getDefaultColors(self: *Self) !BgFg {
    const fg, const bg = try gt.rs.getMulti(self.render_state, &[_]gt.Multi{
        .{ gt.RS_DATA_COLOR_FOREGROUND, gt.ColorRgb },
        .{ gt.RS_DATA_COLOR_BACKGROUND, gt.ColorRgb },
    });
    return BgFg{ .fg = fg, .bg = bg };
}

pub fn render(self: *Self, env: emacs.Env, term: *Terminal, skip: usize, force_full: bool) !void {
    try gt.renderStateUpdate(self.render_state, term.terminal);
    const default_colors = try self.getDefaultColors();

    // Check dirty state.
    // force_full overrides: the buffer may have been erased by scrollback
    // sync / resize / rotation above, so we must rebuild even if
    // libghostty considers the cells clean.
    const dirty = try gt.rs.get(c_int, self.render_state, gt.RS_DATA_DIRTY);

    if (dirty != gt.DIRTY_FALSE or force_full) {
        // Set buffer default face
        var fg_hex: [7]u8 = undefined;
        var bg_hex: [7]u8 = undefined;
        _ = env.f("ghostel--set-buffer-face", .{
            formatColor(default_colors.fg, &fg_hex),
            formatColor(default_colors.bg, &bg_hex),
        });

        // Incremental redraw: only update dirty rows when possible.
        // force_full bypasses partial mode to avoid stale rows after scrolls.
        const dirty_full = force_full or dirty == gt.DIRTY_FULL;
        var row_count: usize = 0;

        try gt.rs.read(self.render_state, gt.RS_DATA_ROW_ITERATOR, &self.row_iterator);
        while (gt.rs_row_next(self.row_iterator)) : ({
            row_count += 1;
            // Clear per-row dirty flag
            gt.rs_row.set(self.row_iterator, gt.RS_ROW_OPT_DIRTY, false) catch |err| {
                env.logError("rs_row.set(DIRTY, false) failed: %s", .{@errorName(err)});
            };
        }) {
            if (row_count < skip) continue;

            // Only process dirty rows
            const dirty_row = dirty_full or try gt.rs_row.get(bool, self.row_iterator, gt.RS_ROW_DATA_DIRTY);
            if (dirty_row) {
                env.deleteRegion(env.point(), env.lineBeginningPosition2());
                try self.insertRow(env, &default_colors);
            } else {
                _ = env.forwardLine(1);
            }
        }

        // If there's anything left below the viewport, delete it
        env.deleteRegion(env.point(), env.pointMax());

        // Reset dirty state
        try gt.rs.set(self.render_state, gt.RS_OPT_DIRTY, gt.DIRTY_FALSE);
    }
}

fn renderCursor(self: *Self, env: emacs.Env) !void {
    // Walk to the current viewport start
    self.gotoActiveStart(env);
    const active_start_int = env.extractInteger(env.point());

    // Batch-fetch cursor style/visibility (always available).
    const cursor_visible, const cursor_style = try gt.rs.getMulti(self.render_state, &[_]gt.Multi{
        .{ gt.RS_DATA_CURSOR_VISIBLE, bool },
        .{ gt.RS_DATA_CURSOR_VISUAL_STYLE, c_int },
    });

    // Position cursor (active-relative row -> absolute line).
    // X/Y are only valid when HAS_VALUE is true, so query separately
    // to avoid stopping the style batch above on NO_VALUE.
    const cursor_has_value = try gt.rs.get(bool, self.render_state, gt.RS_DATA_CURSOR_VIEWPORT_HAS_VALUE);
    if (cursor_has_value) {
        const cx = try gt.rs.get(u16, self.render_state, gt.RS_DATA_CURSOR_VIEWPORT_X);
        const cy = try gt.rs.get(u16, self.render_state, gt.RS_DATA_CURSOR_VIEWPORT_Y);

        env.gotoCharN(active_start_int);
        _ = env.forwardLine(@as(i64, cy));
        if (!try self.positionCursorByCell(env, cx, cy)) {
            env.moveToColumn(@as(i64, cx));
        }

        _ = env.set("ghostel--cursor-pos", env.cons(cx, cy));
        _ = env.set("ghostel--cursor-char-pos", env.point());
    } else {
        _ = env.set("ghostel--cursor-pos", env.nil());
        _ = env.set("ghostel--cursor-char-pos", env.nil());
    }

    _ = env.f("ghostel--set-cursor-style", .{
        cursor_style,
        if (cursor_visible) env.t() else env.nil(),
    });
}

// Render content from the current viewport scroll position all the way to
// the active area at the current Emacs point.
fn renderToEnd(self: *Self, env: emacs.Env, term: *Terminal, force_full: bool) !usize {
    const scrollbar = try term.getScrollbar();
    if (scrollbar.len == 0) return 0;
    const offset_max = scrollbar.total - scrollbar.len;
    // Walk from the current viewport position to offset_max in viewport-sized
    // steps, rendering each chunk into the Emacs buffer. Consecutive positions
    // overlap by `scrollbar.len - step` rows when the remaining range is
    // smaller than a full viewport; `skip` tracks how many leading rows of the
    // next position were already rendered at the tail of the previous one.
    // After the loop the viewport sits at offset_max (the active area).
    const total_range = scrollbar.total - scrollbar.offset;
    const num_viewports = (total_range + scrollbar.len - 1) / scrollbar.len;
    var skip: usize = 0;
    var rendered_rows: usize = 0;
    var current_offset = scrollbar.offset;
    for (0..num_viewports) |_| {
        try self.render(env, term, skip, force_full);
        rendered_rows += (scrollbar.len - skip);

        const max_step = offset_max - current_offset;
        const step = @min(max_step, scrollbar.len);
        skip = scrollbar.len - step;

        current_offset += step;
        term.scrollViewport(gt.SCROLL_DELTA, @intCast(step));
    }

    return rendered_rows;
}

fn commitResize(self: *Self, term: *Terminal) void {
    if (self.pending_resize) |rz| {
        _ = gt.term_resize(
            term.terminal,
            rz.cols,
            rz.rows,
            term.cell_width_px,
            term.cell_height_px,
        );
        self.size = rz;
        self.pending_resize = null;
    }
}

/// Position the Emacs point at the start of the active area: `self.size.rows`
/// lines back from `point-max`.
fn gotoActiveStart(self: *Self, env: emacs.Env) void {
    env.gotoChar(env.pointMax());
    _ = env.forwardLine(-@as(i64, @intCast(self.size.rows)));
}
