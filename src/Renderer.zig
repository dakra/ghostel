/// RenderState-based terminal rendering to Emacs buffers.
///
/// Reads rows/cells from the ghostty render state, extracts text and
/// style attributes, and inserts propertized text into the current
/// Emacs buffer.  See `redraw' below for the per-redraw algorithm
/// (viewport parking, scrollback sync, dirty-row reuse).
const std = @import("std");
const emacs = @import("emacs.zig");
const gt = @import("ghostty-vt");
const Terminal = @import("terminal.zig");

const FixedArrayList = @import("fixed_array_list.zig").FixedArrayList;

const Self = @This();

/// Render state for incremental screen updates.
render_state: gt.RenderState,

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

/// Cached information about font metrics, used for glyph scaling
font_info: ?FontInfo = null,

/// Bold text coloring configuration.
bold_config: ?gt.Style.BoldColor = null,

const FontInfo = struct {
    width: i64,
    height: i64,
    coverage: u32,
};

pub fn init(term: *gt.Terminal) !Self {
    var renderer = Self{
        .render_state = gt.RenderState.empty,
        .size = undefined,
        .pending_resize = .{ .cols = term.cols, .rows = term.rows, .cell_w = 1, .cell_h = 1 },
    };
    try renderer.commitResize(term);
    return renderer;
}

pub fn deinit(self: *Self) void {
    self.render_state.deinit(std.heap.c_allocator);
    self.row.deinit();
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

    const scrollbar = term.terminal.screens.active.pages.scrollbar();

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
        try self.commitResize(&term.terminal);

        self.rows_in_buffer = 0;
        force_full = true;
    }

    // Unpark the viewport. When we have scrollback the viewport is sitting at
    // `max_offset - 1`; advance by 1 to reach the old active area, which is
    // also where the Emacs buffer currently ends. When we have no scrollback
    // there was no parking, so go to the top instead.
    if (self.rows_in_buffer > self.size.rows) {
        term.terminal.scrollViewport(.{ .delta = 1 });
        env.gotoChar(env.pointMax());
        _ = env.forwardLine(-@as(i64, @intCast(scrollbar.len)));
    } else {
        term.terminal.scrollViewport(.top);
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
        try self.commitResize(&term.terminal);
        term.terminal.scrollViewport(.bottom);
        self.gotoActiveStart(env);
        try self.render(env, term, 0, false);
        // There is now at least self.size.rows number of rows
        self.rows_in_buffer = @max(self.rows_in_buffer, self.size.rows);
    }

    // Evict old scrollback if libghostty also did
    const libghostty_rows = term.terminal.screens.active.pages.total_rows;
    if (libghostty_rows < self.rows_in_buffer) {
        env.gotoChar(env.pointMin());
        _ = env.forwardLine(@as(i64, @intCast(self.rows_in_buffer - libghostty_rows)));
        env.deleteRegion(env.pointMin(), env.point());
        self.rows_in_buffer = libghostty_rows;
    }

    try self.renderCursor(env);

    // Update working directory from OSC 7
    if (term.terminal.getPwd()) |pwd| {
        _ = env.f("ghostel--update-directory", .{pwd});
    }

    // Park the viewport one row above the bottom. On the next render, if
    // libghostty has cleared its scrollback the viewport will have snapped back
    // to the bottom (`offset + len == total`), which we treat as the rebuild
    // signal. If scrollback only grew, the parked position naturally points at
    // the old active area, and advancing by 1 reaches the new one.
    term.terminal.scrollViewport(.bottom);
    term.terminal.scrollViewport(.{ .delta = -1 });
}

fn updateFontInfo(self: *Self, env: emacs.Env) bool {
    const new_font = getDefaultFont(env);
    const current_font = env.symbolValue("ghostel--rendered-font");
    if (env.eq(new_font, current_font)) return false;

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

/// Blend a foreground color toward a background color to produce a "dim" effect.
/// Uses ~65% foreground / ~35% background weighting.
fn dimColor(fg: gt.color.RGB, bg: gt.color.RGB) gt.color.RGB {
    return .{
        .r = @intCast((@as(u16, fg.r) * 166 + @as(u16, bg.r) * 90) / 256),
        .g = @intCast((@as(u16, fg.g) * 166 + @as(u16, bg.g) * 90) / 256),
        .b = @intCast((@as(u16, fg.b) * 166 + @as(u16, bg.b) * 90) / 256),
    };
}

/// Format an RGB color as "#RRGGBB" into a buffer.
fn formatColor(color: gt.color.RGB, buf: *[7]u8) []const u8 {
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

    var face_props: FixedArrayList(emacs.Value, 32) = .{};
    const start_val = env.makeInteger(start);
    const end_val = env.makeInteger(end);

    var fg_buf: [7]u8 = undefined;
    var bg_buf: [7]u8 = undefined;
    var dim_buf: [7]u8 = undefined;

    const effective_fg = if (props.inverse) props.bg else props.fg;
    const effective_bg = if (props.inverse) props.fg else props.bg;

    const s = &emacs.sym;

    if (props.faint) {
        // Dim text: blend foreground toward background to reduce intensity.
        // Always set :foreground since we modify the color itself.
        const dimmed = dimColor(effective_fg, effective_bg);
        const dim_str = formatColor(dimmed, &dim_buf);
        try face_props.append(s.@":foreground");
        try face_props.append(env.makeString(dim_str));
    } else {
        const fg_str = formatColor(effective_fg, &fg_buf);
        try face_props.append(s.@":foreground");
        try face_props.append(env.makeString(fg_str));
    }

    {
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

    if (props.underline != .none) {
        try face_props.append(s.@":underline");
        if (props.underline == .single and props.underline_color == null) {
            try face_props.append(env.t());
        } else {
            var ul_props: FixedArrayList(emacs.Value, 4) = .{};

            try ul_props.append(s.@":style");
            try ul_props.append(switch (props.underline) {
                .curly => s.wave,
                .double => s.@"double-line",
                .dotted => s.dot,
                .dashed => s.dash,
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

/// Properties for a run of cells.
const CellProps = struct {
    fg: gt.color.RGB = .{},
    bg: gt.color.RGB = .{},
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    underline: gt.sgr.Attribute.Underline = .none,
    underline_color: ?gt.color.RGB = null,
    strikethrough: bool = false,
    inverse: bool = false,
    hyperlink: bool = false,
    semantic_content: gt.page.Cell.SemanticContent = .output,

    fn isDefault(self: CellProps, default_fg: gt.color.RGB, default_bg: gt.color.RGB) bool {
        return std.meta.eql(self, .{ .fg = default_fg, .bg = default_bg });
    }
};

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
    const allocator = std.heap.c_allocator;

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
        term: *Terminal,
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
                try self.runs.append(RowContent.allocator, .{
                    .start_char = self.char_len,
                    .end_char = self.char_len,
                    .props = readCellProps(&term.renderer, &cell),
                });
                current_prop_key = prop_key;
            }

            const byte_start = self.text.items.len;
            const char_start = self.char_len;

            const codepoint: u21 = if (cell.raw.hasText()) cell.raw.codepoint() else ' ';
            try self.appendCodepoints(&[1]u21{codepoint});
            if (cell.raw.hasGrapheme()) {
                try self.appendCodepoints(cell.grapheme);
            }

            // If this is a grapheme cluster, or if the char is not covered by
            // the default font, we register it as needing font glyph adjustment
            // to fit into the monospace grid.
            if (cell.raw.hasGrapheme() or codepoint >= adjustment_threshold) {
                try self.adjust_cells.append(RowContent.allocator, .{
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

        try self.text.append(RowContent.allocator, '\n');
    }

    pub fn deinit(self: *RowContent) void {
        self.text.deinit(allocator);
        self.adjust_cells.deinit(allocator);
        self.runs.deinit(allocator);
    }

    fn clear(self: *RowContent) !void {
        self.text.clearRetainingCapacity();
        self.adjust_cells.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
        self.char_len = 0;
    }

    fn appendCodepoints(self: *RowContent, cluster: []const u21) !void {
        for (cluster) |cp| {
            const slice = try self.text.addManyAsSlice(
                allocator,
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
    while (cell.col + char_width < self.size.cols) : ({
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
    const scale = @min(scale_width, scale_height);

    const min_width_spec = env.list(.{ s.@"min-width", env.list(.{char_width}) });
    const scale_spec = env.list(.{ s.height, scale });
    const display_spec = env.list(.{ min_width_spec, scale_spec });
    _ = env.f("put-text-property", .{ start_val, end_val, s.display, display_spec });
}

/// Insert row text and apply property runs.
fn insertRow(
    self: *Self,
    env: emacs.Env,
    term: *Terminal,
    row: *const gt.RenderState.Row,
) !void {
    try self.row.build(
        term,
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
    env.gotoCharN(pt + @min(char_count, max_chars));
    return true;
}

const BgFg = struct {
    bg: gt.color.RGB,
    fg: gt.color.RGB,
};

pub fn render(self: *Self, env: emacs.Env, term: *Terminal, skip: usize, force_full: bool) !void {
    try self.render_state.update(std.heap.c_allocator, &term.terminal);

    if (self.render_state.dirty != .false or force_full) {
        // Set buffer default face
        var fg_hex: [7]u8 = undefined;
        var bg_hex: [7]u8 = undefined;
        _ = env.f("ghostel--set-buffer-face", .{
            formatColor(self.render_state.colors.foreground, &fg_hex),
            formatColor(self.render_state.colors.background, &bg_hex),
        });

        // Incremental redraw: only update dirty rows when possible.
        // force_full bypasses partial mode to avoid stale rows after scrolls.
        const dirty_full = force_full or self.render_state.dirty == .full;
        var i: u16 = 0;
        const row_dirty = self.render_state.row_data.items(.dirty);

        while (i < self.render_state.rows) : ({
            // Clear per-row dirty flag
            row_dirty[i] = false;
            i += 1;
        }) {
            if (i < skip) continue;

            // Only process dirty rows
            const dirty_row = dirty_full or row_dirty[i];
            if (dirty_row) {
                env.deleteRegion(env.point(), env.lineBeginningPosition2());
                const row = self.render_state.row_data.get(i);
                try self.insertRow(env, term, &row);
            } else {
                _ = env.forwardLine(1);
            }
        }

        // If there's anything left below the viewport, delete it
        env.deleteRegion(env.point(), env.pointMax());

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
        env.gotoCharN(active_start_int);
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

// Render content from the current viewport scroll position all the way to
// the active area at the current Emacs point.
fn renderToEnd(self: *Self, env: emacs.Env, term: *Terminal, force_full: bool) !usize {
    const scrollbar = term.terminal.screens.active.pages.scrollbar();
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
        term.terminal.scrollViewport(.{ .delta = @intCast(step) });
    }

    return rendered_rows;
}

fn commitResize(self: *Self, term: *gt.Terminal) !void {
    if (self.pending_resize) |rz| {
        try term.resize(std.heap.c_allocator, rz.cols, rz.rows);
        term.width_px = std.math.mul(u32, rz.cols, rz.cell_w) catch std.math.maxInt(u32);
        term.height_px = std.math.mul(u32, rz.rows, rz.cell_h) catch std.math.maxInt(u32);
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
