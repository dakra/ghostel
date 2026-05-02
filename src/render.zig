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

/// Style attributes for a run of text.
const CellStyle = struct {
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

    fn isDefault(self: CellStyle) bool {
        return self.fg == null and
            self.bg == null and
            !self.bold and
            !self.italic and
            !self.faint and
            self.underline == 0 and
            !self.strikethrough and
            !self.inverse and
            !self.hyperlink;
    }
};

// Unique identifier for what we consider a style. Normally, you would only use
// style_id for this but we also use Emacs text properties for hyperlinks so
// we include "hyperlink-ness" here.
const CellStyleKey = struct { style_id: gt.c.GhosttyStyleId, hyperlink: bool };

/// Track style runs for propertizing after insertion.
/// Positions are in characters (codepoints), not bytes, because
/// Emacs put-text-property works with character positions.
const RunInfo = struct {
    start_char: usize,
    end_char: usize,
    style: ?CellStyle,
};

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
fn readCellStyle(cells: gt.RenderStateRowCells, raw: gt.c.GhosttyCell) !?CellStyle {
    var style: CellStyle = .{};

    style.fg = gt.rs_row_cells.get(gt.ColorRgb, cells, gt.RS_CELLS_DATA_FG_COLOR) catch |err| switch (err) {
        gt.Error.InvalidValue => null,
        else => return err,
    };
    style.bg = gt.rs_row_cells.get(gt.ColorRgb, cells, gt.RS_CELLS_DATA_BG_COLOR) catch |err| switch (err) {
        gt.Error.InvalidValue => null,
        else => return err,
    };

    // Read style attributes
    if (try gt.rs_row_cells.getOpt(gt.Style, cells, gt.RS_CELLS_DATA_STYLE)) |gs| {
        style.bold = gs.bold;
        style.italic = gs.italic;
        style.faint = gs.faint;
        style.underline = gs.underline;
        style.strikethrough = gs.strikethrough;
        style.inverse = gs.inverse;

        // Underline color
        if (gs.underline_color.tag == gt.c.GHOSTTY_STYLE_COLOR_RGB) {
            style.underline_color = gs.underline_color.value.rgb;
        }
    }

    if (try gt.cell.getOpt(bool, raw, gt.c.GHOSTTY_CELL_DATA_HAS_HYPERLINK)) |hl| {
        style.hyperlink = hl;
    }

    return if (style.isDefault()) null else style;
}

/// Apply face properties to a region of the buffer.
/// Uses (put-text-property START END 'face PLIST).
fn applyStyle(env: emacs.Env, start: i64, end: i64, style: CellStyle, default_colors: *const BgFg) !void {
    if (start >= end) return;

    var face_props: FixedArrayList(emacs.Value, 32) = .{};
    const start_val = env.makeInteger(start);
    const end_val = env.makeInteger(end);

    var fg_buf: [7]u8 = undefined;
    var bg_buf: [7]u8 = undefined;
    var dim_buf: [7]u8 = undefined;

    const bg = style.bg orelse default_colors.bg;
    const fg = style.fg orelse default_colors.fg;
    const effective_fg = if (style.inverse) bg else fg;
    const effective_bg = if (style.inverse) fg else bg;

    const s = &emacs.sym;

    if (style.faint) {
        // Dim text: blend foreground toward background to reduce intensity.
        // Always set :foreground since we modify the color itself.
        const dimmed = dimColor(effective_fg, effective_bg);
        const dim_str = formatColor(dimmed, &dim_buf);
        try face_props.append(s.@":foreground");
        try face_props.append(env.makeString(dim_str));
    } else if (!colorEql(style.fg, null) or style.inverse) {
        const fg_str = formatColor(effective_fg, &fg_buf);
        try face_props.append(s.@":foreground");
        try face_props.append(env.makeString(fg_str));
    }

    if (!colorEql(style.bg, null) or style.inverse) {
        const bg_str = formatColor(effective_bg, &bg_buf);
        try face_props.append(s.@":background");
        try face_props.append(env.makeString(bg_str));
    }

    if (style.bold) {
        try face_props.append(s.@":weight");
        try face_props.append(s.bold);
    }

    if (style.italic) {
        try face_props.append(s.@":slant");
        try face_props.append(s.italic);
    }

    if (style.underline != 0) {
        try face_props.append(s.@":underline");
        if (style.underline == 1 and style.underline_color == null) {
            try face_props.append(env.t());
        } else {
            var ul_props: FixedArrayList(emacs.Value, 4) = .{};

            try ul_props.append(s.@":style");
            try ul_props.append(switch (style.underline) {
                3 => s.wave,
                2 => s.@"double-line",
                4 => s.dot,
                5 => s.dash,
                else => s.line,
            });

            if (style.underline_color) |uc| {
                var uc_buf: [7]u8 = undefined;
                try ul_props.append(s.@":color");
                try ul_props.append(env.makeString(formatColor(uc, &uc_buf)));
            }

            try face_props.append(env.funcall(s.list, ul_props.items()));
        }
    }

    if (style.strikethrough) {
        try face_props.append(s.@":strike-through");
        try face_props.append(env.t());
    }

    if (face_props.len > 0) {
        const face = env.funcall(s.list, face_props.items());
        env.putTextProperty(start_val, end_val, s.face, face);
    }

    if (style.hyperlink) {
        env.putTextProperty(start_val, end_val, s.@"help-echo", s.@"ghostel--native-link-help-echo");
        env.putTextProperty(start_val, end_val, s.@"mouse-face", s.highlight);
        env.putTextProperty(start_val, end_val, s.keymap, env.call1(s.@"symbol-value", s.@"ghostel-link-map"));
    }
}

/// Check if the current row in the iterator is soft-wrapped.
fn isRowWrapped(term: *Terminal) !bool {
    const raw_row = try gt.rs_row.get(gt.c.GhosttyRow, term.row_iterator, gt.c.GHOSTTY_RENDER_STATE_ROW_DATA_RAW);
    return try gt.row.get(bool, raw_row, gt.ROW_DATA_WRAP);
}

/// Check if the current row in the iterator is a semantic prompt.
fn isRowPrompt(term: *Terminal) !bool {
    const raw_row = try gt.rs_row.get(gt.c.GhosttyRow, term.row_iterator, gt.c.GHOSTTY_RENDER_STATE_ROW_DATA_RAW);
    return try gt.row.get(c_int, raw_row, gt.ROW_DATA_SEMANTIC_PROMPT) != 0;
}

/// Result from buildRowContent: byte length for make_string, char count for properties.
const RowContent = struct {
    /// The text content of the row
    text: FixedArrayList(u8, 16384) = .{},

    /// The number of Emacs characters (as opposed to bytes) in the text. Emacs
    /// treats each codepoint as a separate character for buffer positions, even
    /// if it doesn't necessarily render as such.
    emacs_char_len: usize = 0,

    /// A list of continuous property runs
    runs: FixedArrayList(RunInfo, 512) = .{},

    /// Number of leading characters that are semantic prompt content.
    /// Zero if the row has no prompt cells.
    prompt_char_len: usize = 0,

    /// Character range covering semantic-input cells (OSC 133 B..C).
    /// `input_end_char == input_start_char` means no input cells on the row.
    input_start_char: usize = 0,
    input_end_char: usize = 0,

    /// True when the row contains at least one wide (2-cell) character.
    has_wide: bool = false,

    pub fn appendAsciiChar(self: *RowContent, c: u8) !void {
        try self.text.append(c);
        self.emacs_char_len += 1;
    }

    pub fn appendGraphemeCluster(self: *RowContent, cluster: []const u32) !void {
        for (cluster) |cp| {
            const codepoint: u21 = @intCast(cp);
            const encoded_len = try std.unicode.utf8Encode(codepoint, self.text.unusedCapacitySlice());
            try self.text.addMany(encoded_len);
            self.emacs_char_len += 1; // one codepoint = one Emacs character
        }
    }
};

fn getStyleKey(cell: gt.c.GhosttyCell) !CellStyleKey {
    return CellStyleKey{ // zig fmt: off
        .style_id = try gt.cell.getOpt(gt.c.GhosttyStyleId, cell, gt.c.GHOSTTY_CELL_DATA_STYLE_ID) orelse 0,
        .hyperlink = try gt.cell.getOpt(bool, cell, gt.c.GHOSTTY_CELL_DATA_HAS_HYPERLINK) orelse false
    }; // zig fmt: on
}

/// Build text content and style runs for the current row in the iterator.
/// Style runs use character (codepoint) offsets for Emacs put-text-property.
///
/// Trailing blank cells — spaces with the default cell style — are
/// trimmed off the end of the row so the Emacs buffer does not carry
/// libghostty's full-width viewport padding. A cell is NOT blank if
/// its character is non-space, or if its style has any non-default
/// attribute (e.g. a colored background, underline, etc.), so visibly-
/// styled blanks are preserved.
fn buildRowContent(term: *Terminal, content: *RowContent) !void {
    // Position at the end of the last non-blank cell; final row length
    // is trimmed back to this. Any run of blank cells past the end is
    // discarded along with their default-style trailing padding.
    var trim_text_len: usize = 0;
    var trim_char_len: usize = 0;
    var in_prompt: bool = true; // track contiguous leading prompt cells
    var saw_input: bool = false;
    var current_style_key: ?CellStyleKey = null;

    try gt.rs_row.read(term.row_iterator, gt.RS_ROW_DATA_CELLS, &term.row_cells);
    while (gt.rs_row_cells_next(term.row_cells)) {
        const graphemes_len = try gt.rs_row_cells.get(u32, term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_LEN);
        const raw_cell = try gt.rs_row_cells.get(gt.c.GhosttyCell, term.row_cells, gt.c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW);

        const semantic = try gt.cell.get(c_int, raw_cell, gt.c.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT);

        // Track leading prompt characters via cell-level semantic content.
        if (in_prompt and semantic != gt.c.GHOSTTY_CELL_SEMANTIC_PROMPT) {
            in_prompt = false;
        }

        const cell_start_char = content.emacs_char_len;
        if (semantic == gt.c.GHOSTTY_CELL_SEMANTIC_INPUT and !saw_input) {
            content.input_start_char = cell_start_char;
            saw_input = true;
        }

        // We use a "key" that holds a minimum set of values that are cheap to
        // read and compare to detect style run breaks. Only when we detect a
        // break do we read the cell style, which is a more expensive operation
        // in such a tight loop.
        const style_key: CellStyleKey = try getStyleKey(raw_cell);
        if (!std.meta.eql(@as(?CellStyleKey, style_key), current_style_key)) {
            try content.runs.append(.{
                .start_char = content.emacs_char_len,
                .end_char = content.emacs_char_len + 1,
                .style = try readCellStyle(term.row_cells, raw_cell),
            });
            current_style_key = style_key;
        } else {
            content.runs.lastPtr().end_char += 1;
        }

        if (graphemes_len == 0) {
            // Wide-character spacer tails occupy a terminal cell but must
            // not produce output — the preceding wide cell already accounts
            // for 2 visual columns in Emacs.
            const wide = try gt.cell.get(c_int, raw_cell, gt.c.GHOSTTY_CELL_DATA_WIDE);
            if (wide == gt.c.GHOSTTY_CELL_WIDE_SPACER_TAIL) {
                content.runs.lastPtr().end_char -= 1;
                content.has_wide = true;
                continue;
            }
            try content.appendAsciiChar(' ');
            if (in_prompt) content.prompt_char_len = content.emacs_char_len;
            if (saw_input and semantic == gt.c.GHOSTTY_CELL_SEMANTIC_INPUT) {
                content.input_end_char = content.emacs_char_len;
            }
            // Empty cells are blank for trim purposes unless their
            // style has a visible attribute (e.g. colored background).
            if (content.runs.lastPtr().style != null) {
                trim_text_len = content.text.len;
                trim_char_len = content.emacs_char_len;
            }
            continue;
        }

        const codepoints = try gt.rs_row_cells.get([16]u32, term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_BUF);
        const cp_count = @min(graphemes_len, 16);
        try content.appendGraphemeCluster(codepoints[0..cp_count]);
        if (in_prompt) content.prompt_char_len = content.emacs_char_len;
        if (saw_input and semantic == gt.c.GHOSTTY_CELL_SEMANTIC_INPUT) {
            content.input_end_char = content.emacs_char_len;
        }
        // Any cell that libghostty stored a grapheme for was written
        // explicitly by the terminal, so it anchors the trim point —
        // even if the grapheme happens to be a space (e.g. the space
        // in a \"$ \" prompt, or a space the shell intentionally
        // emitted as part of a layout). Only unwritten padding cells
        // (the `graphemes_len == 0' branch above) are considered blank.
        trim_text_len = content.text.len;
        trim_char_len = content.emacs_char_len;
    }

    // Trim trailing blank cells. Cap `prompt_char_len' / input range at the
    // new `char_len' so neither region extends past the trimmed text. Style
    // runs extending past the trim point are clipped by `insertAndStyle' via
    // its `content.char_len' cap.
    content.text.resize(trim_text_len);
    content.emacs_char_len = trim_char_len;
    if (content.prompt_char_len > content.emacs_char_len) content.prompt_char_len = content.emacs_char_len;
    if (content.input_end_char > content.emacs_char_len) content.input_end_char = content.emacs_char_len;
    if (content.input_start_char > content.input_end_char) content.input_start_char = content.input_end_char;
}

/// Insert row text and apply style runs.
fn insertAndStyle(
    env: emacs.Env,
    term: *Terminal,
    default_colors: *const BgFg,
) !void {
    var content: RowContent = .{};
    try buildRowContent(term, &content);

    // Append the trailing newline to the row buffer so the row
    // text + newline insert through a single env.insert call
    // instead of two. This saves one Elisp FFI round-trip per
    // inserted row, which is the dominant per-row cost in this
    // hot loop. Style runs only cover the row's cells, so the
    // unstyled trailing \n is harmless to insertAndStyle. If the
    // row exactly filled text_buf, fall back to a separate
    // env.insert("\n") so the "one row per line" invariant
    // (relied on by the `after_insert - 1` property math below)
    // always holds.
    const newline_in_buf = if (content.appendAsciiChar('\n')) true else |_| false;

    const row_start = env.extractInteger(env.point());
    env.insert(content.text.constItems());

    if (content.has_wide) {
        _ = env.call2(env.intern("set"), emacs.sym.@"ghostel--has-wide-chars", env.t());
    }

    for (content.runs.constItems()) |*run| {
        if (run.start_char >= content.emacs_char_len) break;
        const run_end = @min(run.end_char, content.emacs_char_len);
        if (run_end <= run.start_char) continue;

        const prop_start = row_start + @as(i64, @intCast(run.start_char));
        const prop_end = row_start + @as(i64, @intCast(run_end));
        if (run.style) |style| {
            try applyStyle(env, prop_start, prop_end, style, default_colors);
        }
    }

    if (!newline_in_buf) {
        env.insert("\n");
    }
    const after_insert = env.extractInteger(env.point());
    if (try isRowWrapped(term)) {
        // Mark newlines from soft-wrapped rows so copy mode can filter them
        const point = env.point();
        const nl_pos = env.makeInteger(env.extractInteger(point) - 1);
        env.putTextProperty(nl_pos, point, emacs.sym.@"ghostel-wrap", env.t());
    }

    if (content.prompt_char_len > 0) {
        env.putTextProperty(
            env.makeInteger(row_start),
            env.makeInteger(row_start + @as(i64, @intCast(content.prompt_char_len))),
            emacs.sym.@"ghostel-prompt",
            env.t(),
        );
    } else if (try isRowPrompt(term)) {
        // When OSC 133 marked an input span on this row, paint
        // `ghostel-prompt' only over the prefix preceding the input —
        // otherwise the typed input gets covered too, defeating the
        // historical-input linkification that the skip predicate is
        // designed to allow (it short-circuits on `ghostel-prompt`).
        const prompt_end: i64 = if (content.input_end_char > content.input_start_char)
            row_start + @as(i64, @intCast(content.input_start_char))
        else
            after_insert - 1; // exclude trailing newline
        if (prompt_end > row_start) {
            env.putTextProperty(
                env.makeInteger(row_start),
                env.makeInteger(prompt_end),
                emacs.sym.@"ghostel-prompt",
                env.t(),
            );
        }
    }

    if (content.input_end_char > content.input_start_char) {
        env.putTextProperty(
            env.makeInteger(row_start + @as(i64, @intCast(content.input_start_char))),
            env.makeInteger(row_start + @as(i64, @intCast(content.input_end_char))),
            emacs.sym.@"ghostel-input",
            env.t(),
        );
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
fn positionCursorByCell(env: emacs.Env, term: *Terminal, cx: u16, cy: u16) !bool {
    if (cx == 0) return true; // already at column 0

    try gt.rs.read(term.render_state, gt.RS_DATA_ROW_ITERATOR, &term.row_iterator);

    // Advance iterator to cursor row cy.
    {
        var ri: u16 = 0;
        while (ri <= cy) : (ri += 1) {
            if (!gt.rs_row_next(term.row_iterator)) {
                return false;
            }
        }
    }

    try gt.rs_row.read(term.row_iterator, gt.RS_ROW_DATA_CELLS, &term.row_cells);

    // Walk cells 0..cx-1, counting Emacs characters.
    var col: u16 = 0;
    var char_count: i64 = 0;
    while (col < cx) : (col += 1) {
        if (!gt.rs_row_cells_next(term.row_cells)) break;

        const graphemes_len = try gt.rs_row_cells.get(u32, term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_LEN);
        if (graphemes_len == 0) {
            // Spacer tails produce no Emacs character.
            const raw_cell = try gt.rs_row_cells.get(gt.c.GhosttyCell, term.row_cells, gt.c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW);
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

fn getDefaultColors(term: *Terminal) !BgFg {
    // zig fmt: off
    const fg , const bg = try gt.rs.getMulti(term.render_state, &[_]gt.Multi{
        .{ gt.RS_DATA_COLOR_FOREGROUND, gt.ColorRgb },
        .{ gt.RS_DATA_COLOR_BACKGROUND, gt.ColorRgb }
    });
    // zig fmt: on
    return BgFg{ .fg = fg, .bg = bg };
}

pub fn render(env: emacs.Env, term: *Terminal, skip: usize, force_full: bool) !void {
    try gt.renderStateUpdate(term.render_state, term.terminal);
    const default_colors = try getDefaultColors(term);

    // Check dirty state.
    // force_full overrides: the buffer may have been erased by scrollback
    // sync / resize / rotation above, so we must rebuild even if
    // libghostty considers the cells clean.
    const dirty = try gt.rs.get(c_int, term.render_state, gt.RS_DATA_DIRTY);

    if (dirty != gt.DIRTY_FALSE or force_full) {
        // Set buffer default face
        var fg_hex: [7]u8 = undefined;
        var bg_hex: [7]u8 = undefined;
        _ = env.call2(
            emacs.sym.@"ghostel--set-buffer-face",
            env.makeString(formatColor(default_colors.fg, &fg_hex)),
            env.makeString(formatColor(default_colors.bg, &bg_hex)),
        );

        // Incremental redraw: only update dirty rows when possible.
        // force_full bypasses partial mode to avoid stale rows after scrolls.
        const dirty_full = force_full or dirty == gt.DIRTY_FULL;
        var row_count: usize = 0;

        try gt.rs.read(term.render_state, gt.RS_DATA_ROW_ITERATOR, &term.row_iterator);
        while (gt.rs_row_next(term.row_iterator)) : (row_count += 1) {
            defer {
                // Clear per-row dirty flag
                gt.rs_row.set(term.row_iterator, gt.RS_ROW_OPT_DIRTY, false) catch {};
            }

            if (row_count < skip) continue;

            // Only process dirty rows
            const dirty_row = dirty_full or try gt.rs_row.get(bool, term.row_iterator, gt.RS_ROW_DATA_DIRTY);
            if (dirty_row) {
                env.deleteRegion(env.point(), env.lineBeginningPosition2());
                try insertAndStyle(env, term, &default_colors);
            } else {
                _ = env.forwardLine(1);
            }
        }

        // If there's anything left below the viewport, delete it
        env.deleteRegion(env.point(), env.pointMax());

        // Reset dirty state
        try gt.rs.set(term.render_state, gt.RS_OPT_DIRTY, gt.DIRTY_FALSE);
    }
}

pub fn renderCursor(env: emacs.Env, term: *Terminal) !void {

    // Walk to the current viewport start
    gotoActiveStart(env, term);
    const active_start_int = env.extractInteger(env.point());

    // Batch-fetch cursor style/visibility (always available).
    const cursor_visible, const cursor_style = try gt.rs.getMulti(term.render_state, &[_]gt.Multi{
        .{ gt.RS_DATA_CURSOR_VISIBLE, bool },
        .{ gt.RS_DATA_CURSOR_VISUAL_STYLE, c_int },
    });

    // Position cursor (active-relative row -> absolute line).
    // X/Y are only valid when HAS_VALUE is true, so query separately
    // to avoid stopping the style batch above on NO_VALUE.
    const cursor_has_value = try gt.rs.get(bool, term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_HAS_VALUE);
    if (cursor_has_value) {
        const cx = try gt.rs.get(u16, term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_X);
        const cy = try gt.rs.get(u16, term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_Y);

        env.gotoCharN(active_start_int);
        _ = env.forwardLine(@as(i64, cy));
        if (!try positionCursorByCell(env, term, cx, cy)) {
            env.moveToColumn(@as(i64, cx));
        }
    }

    _ = env.call2(
        emacs.sym.@"ghostel--set-cursor-style",
        env.makeInteger(@as(i64, cursor_style)),
        if (cursor_visible) env.t() else env.nil(),
    );
}

// Render content from the current viewport scroll position all the way to
// the active area at the current Emacs point.
fn renderToEnd(env: emacs.Env, term: *Terminal, force_full: bool) !usize {
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
        try render(env, term, skip, force_full);
        rendered_rows += (scrollbar.len - skip);

        const max_step = offset_max - current_offset;
        const step = @min(max_step, scrollbar.len);
        skip = scrollbar.len - step;

        current_offset += step;
        term.scrollViewport(gt.SCROLL_DELTA, @intCast(step));
    }

    return rendered_rows;
}

fn commitResize(term: *Terminal) void {
    if (term.pending_resize) |resize| {
        _ = gt.term_resize(
            term.terminal,
            resize.cols,
            resize.rows,
            term.cell_width_px,
            term.cell_height_px,
        );
        term.size = resize;
        term.pending_resize = null;
    }
}

/// Position the Emacs point at the start of the active area: `term.size.rows`
/// lines back from `point-max`.
fn gotoActiveStart(env: emacs.Env, term: *Terminal) void {
    env.gotoChar(env.pointMax());
    _ = env.forwardLine(-@as(i64, @intCast(term.size.rows)));
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
pub fn redraw(env: emacs.Env, term: *Terminal, force_full_arg: bool) !void {
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

    var force_full = false;

    // ---- Scrollback validity ------------------------------------------------
    // There are three cases where we clear scrollback:
    // 1. The terminal width/cols changed.
    // 2. We had some scrollback but the scrollbar was reset from the parked
    //    MAX - 1 position. This indicates that libghostty cleared its
    //    scrollback and we follow after by clearing too.
    // 3. We had some scrollback but the scrollbar ended up at offset = 0, which
    //    means that we got so much scrolling that we scrolled all the way up
    //    and do not know how much we missed.
    const scrollbar = try term.getScrollbar();
    const cols_changed = if (term.pending_resize) |resize| resize.cols != term.size.cols else false;
    const had_scrollback = term.rows_in_buffer > scrollbar.len;
    const scrollbar_reset = had_scrollback and scrollbar.len + scrollbar.offset == scrollbar.total;
    const scrollbar_hit_cap = had_scrollback and scrollbar.offset == 0;
    if (force_full_arg or cols_changed or scrollbar_reset or scrollbar_hit_cap) {
        env.eraseBuffer();
        // Commit any pending resize since we're doing a rebuild anyway.
        commitResize(term);

        term.rows_in_buffer = 0;
        force_full = true;
    }

    // Unpark the viewport. When we have scrollback the viewport is sitting at
    // `max_offset - 1`; advance by 1 to reach the old active area, which is
    // also where the Emacs buffer currently ends. When we have no scrollback
    // there was no parking, so go to the top instead.
    if (term.rows_in_buffer > term.size.rows) {
        term.scrollViewport(gt.SCROLL_DELTA, 1);
        env.gotoChar(env.pointMax());
        _ = env.forwardLine(-@as(i64, @intCast(scrollbar.len)));
    } else {
        term.scrollViewport(gt.SCROLL_TOP, 0);
        env.gotoChar(env.pointMin());
    }

    const rendered_rows = try renderToEnd(env, term, force_full);
    // Now that we rendered, even if we cleared the buffer above, we now have at
    // least the rows in the active area:
    term.rows_in_buffer = @max(term.rows_in_buffer, term.size.rows);
    // But we might also have added scrollback rows - that is, rows that we
    // rendered that was not active area. Guard the subtraction: when
    // renderToEnd is a no-op (scrollbar.len == 0 or empty range) it returns 0,
    // and there are no new scrollback rows to add.
    if (rendered_rows > term.size.rows) {
        term.rows_in_buffer += rendered_rows - term.size.rows;
    }

    // If we have a pending resize, commit it now and just rerender the active
    // since the scrollback is already up to date.
    if (term.pending_resize != null) {
        commitResize(term);
        term.scrollViewport(gt.SCROLL_BOTTOM, 0);
        gotoActiveStart(env, term);
        try render(env, term, 0, false);
        // There is now at least term.size.rows number of rows
        term.rows_in_buffer = @max(term.rows_in_buffer, term.size.rows);
    }

    // Evict old scrollback if libghostty also did
    const libghostty_rows = try term.getTotalRows();
    if (libghostty_rows < term.rows_in_buffer) {
        env.gotoChar(env.pointMin());
        _ = env.forwardLine(@as(i64, @intCast(term.rows_in_buffer - libghostty_rows)));
        env.deleteRegion(env.pointMin(), env.point());
        term.rows_in_buffer = libghostty_rows;
    }

    try renderCursor(env, term);

    // Update working directory from OSC 7
    if (try term.getPwd()) |pwd| {
        _ = env.call1(emacs.sym.@"ghostel--update-directory", env.makeString(pwd));
    }

    // Park the viewport one row above the bottom. On the next render, if
    // libghostty has cleared its scrollback the viewport will have snapped back
    // to the bottom (`offset + len == total`), which we treat as the rebuild
    // signal. If scrollback only grew, the parked position naturally points at
    // the old active area, and advancing by 1 reaches the new one.
    term.scrollViewport(gt.SCROLL_BOTTOM, 0);
    term.scrollViewport(gt.SCROLL_DELTA, -1);
}
