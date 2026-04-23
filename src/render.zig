/// RenderState-based terminal rendering to Emacs buffers.
///
/// Reads dirty rows/cells from the ghostty render state, extracts
/// text and style attributes, and inserts propertized text into the
/// current Emacs buffer.
///
/// Supports two modes:
/// - DIRTY_FULL: erase buffer and redraw everything
/// - DIRTY_PARTIAL: only update dirty rows in-place
const std = @import("std");
const emacs = @import("emacs.zig");
const gt = @import("ghostty.zig");
const Terminal = @import("terminal.zig");

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

    fn eql(a: CellStyle, b: CellStyle) bool {
        return colorEql(a.fg, b.fg) and
            colorEql(a.bg, b.bg) and
            a.bold == b.bold and
            a.italic == b.italic and
            a.faint == b.faint and
            a.underline == b.underline and
            colorEql(a.underline_color, b.underline_color) and
            a.strikethrough == b.strikethrough and
            a.inverse == b.inverse;
    }

    fn isDefault(self: CellStyle) bool {
        return self.fg == null and
            self.bg == null and
            !self.bold and
            !self.italic and
            !self.faint and
            self.underline == 0 and
            !self.strikethrough and
            !self.inverse;
    }
};

/// Track style runs for propertizing after insertion.
/// Positions are in characters (codepoints), not bytes, because
/// Emacs put-text-property works with character positions.
const RunInfo = struct {
    start_char: usize,
    end_char: usize,
    style: CellStyle,
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

/// Tri-state cache of the per-cell raw handle. Used by `buildRowContent`
/// so cells that need both the semantic-content check (in-prompt) and
/// the wide-spacer check (empty grapheme) only pay for one
/// `cells_get(RAW)` call.
const RawTag = enum { unset, loaded, failed };

/// Lazily populate `out` with the raw cell; memoizes success/failure
/// in `tag` so repeated calls within one cell do not re-issue the get.
///
/// The cache assumes `cells_get(RAW)` is idempotent for a given
/// iterator position (which it is in libghostty today — it returns a
/// handle into already-materialized cell data).  If that ever
/// changes, a failed first call would become sticky for the rest of
/// the current cell.
fn loadRawCell(cells: gt.RenderStateRowCells, out: *gt.c.GhosttyCell, tag: *RawTag) bool {
    switch (tag.*) {
        .unset => {
            if (gt.c.ghostty_render_state_row_cells_get(cells, gt.c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(out)) == gt.SUCCESS) {
                tag.* = .loaded;
                return true;
            }
            tag.* = .failed;
            return false;
        },
        .loaded => return true,
        .failed => return false,
    }
}

/// Read the style for the current cell from the render state.
fn readCellStyle(cells: gt.RenderStateRowCells) CellStyle {
    var style: CellStyle = .{};

    // Read resolved FG color
    var fg: gt.ColorRgb = undefined;
    if (gt.c.ghostty_render_state_row_cells_get(cells, gt.RS_CELLS_DATA_FG_COLOR, @ptrCast(&fg)) == gt.SUCCESS) {
        style.fg = fg;
    }

    // Read resolved BG color
    var bg: gt.ColorRgb = undefined;
    if (gt.c.ghostty_render_state_row_cells_get(cells, gt.RS_CELLS_DATA_BG_COLOR, @ptrCast(&bg)) == gt.SUCCESS) {
        style.bg = bg;
    }

    // Read style attributes
    var gs: gt.Style = std.mem.zeroes(gt.Style);
    gs.size = @sizeOf(gt.Style);
    if (gt.c.ghostty_render_state_row_cells_get(cells, gt.RS_CELLS_DATA_STYLE, @ptrCast(&gs)) == gt.SUCCESS) {
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

    return style;
}

/// Apply face properties to a region of the buffer.
/// Uses (put-text-property START END 'face PLIST).
fn applyStyle(env: emacs.Env, start: i64, end: i64, style: CellStyle, default_fg: gt.ColorRgb, default_bg: gt.ColorRgb) void {
    if (style.isDefault()) return;
    if (start >= end) return;

    var props: [24]emacs.Value = undefined;
    var prop_count: usize = 0;

    var fg_buf: [7]u8 = undefined;
    var bg_buf: [7]u8 = undefined;
    var dim_buf: [7]u8 = undefined;

    const effective_fg = if (style.inverse) (style.bg orelse default_bg) else (style.fg orelse default_fg);
    const effective_bg = if (style.inverse) (style.fg orelse default_fg) else (style.bg orelse default_bg);

    const s = &emacs.sym;

    if (style.faint) {
        // Dim text: blend foreground toward background to reduce intensity.
        // Always set :foreground since we modify the color itself.
        const dimmed = dimColor(effective_fg, effective_bg);
        const dim_str = formatColor(dimmed, &dim_buf);
        props[prop_count] = s.@":foreground";
        prop_count += 1;
        props[prop_count] = env.makeString(dim_str);
        prop_count += 1;
    } else if (!colorEql(style.fg, null) or style.inverse) {
        const fg_str = formatColor(effective_fg, &fg_buf);
        props[prop_count] = s.@":foreground";
        prop_count += 1;
        props[prop_count] = env.makeString(fg_str);
        prop_count += 1;
    }

    if (!colorEql(style.bg, null) or style.inverse) {
        const bg_str = formatColor(effective_bg, &bg_buf);
        props[prop_count] = s.@":background";
        prop_count += 1;
        props[prop_count] = env.makeString(bg_str);
        prop_count += 1;
    }

    if (style.bold) {
        props[prop_count] = s.@":weight";
        prop_count += 1;
        props[prop_count] = s.bold;
        prop_count += 1;
    }

    if (style.italic) {
        props[prop_count] = s.@":slant";
        prop_count += 1;
        props[prop_count] = s.italic;
        prop_count += 1;
    }

    if (style.underline != 0) {
        props[prop_count] = s.@":underline";
        prop_count += 1;
        if (style.underline == 1 and style.underline_color == null) {
            props[prop_count] = env.t();
        } else {
            var ul_props: [4]emacs.Value = undefined;
            var ul_count: usize = 0;

            ul_props[ul_count] = s.@":style";
            ul_count += 1;
            ul_props[ul_count] = switch (style.underline) {
                3 => s.wave,
                2 => s.@"double-line",
                4 => s.dot,
                5 => s.dash,
                else => s.line,
            };
            ul_count += 1;

            if (style.underline_color) |uc| {
                var uc_buf: [7]u8 = undefined;
                ul_props[ul_count] = s.@":color";
                ul_count += 1;
                ul_props[ul_count] = env.makeString(formatColor(uc, &uc_buf));
                ul_count += 1;
            }

            props[prop_count] = env.funcall(s.list, ul_props[0..ul_count]);
        }
        prop_count += 1;
    }

    if (style.strikethrough) {
        props[prop_count] = s.@":strike-through";
        prop_count += 1;
        props[prop_count] = env.t();
        prop_count += 1;
    }

    if (prop_count == 0) return;

    const face = env.funcall(s.list, props[0..prop_count]);
    const start_val = env.makeInteger(start);
    const end_val = env.makeInteger(end);
    env.putTextProperty(start_val, end_val, s.face, face);
}

/// A hyperlink span detected from the terminal grid.
const HyperlinkSpan = struct {
    row: u16,
    col_start: u16,
    col_end: u16,
    uri_start: usize, // offset into uri_buf
    uri_len: usize,
};

/// Result of hyperlink scanning.
const HyperlinkResult = struct {
    count: usize,
    uri_used: usize,
};

/// Scan specific rows for hyperlinks using the grid_ref API.
/// Queries each cell directly for its hyperlink URI, coalescing
/// adjacent cells with the same URI into spans.
fn scanHyperlinksFromGrid(
    terminal: gt.Terminal,
    cols: u16,
    hyperlink_rows: []const u16,
    spans: []HyperlinkSpan,
    uri_buf: []u8,
) HyperlinkResult {
    var span_count: usize = 0;
    var uri_used: usize = 0;

    for (hyperlink_rows) |row| {
        var in_link = false;
        var link_start_col: u16 = 0;
        var link_uri_start: usize = 0;
        var link_uri_len: usize = 0;

        for (0..cols) |col_idx| {
            const col: u16 = @intCast(col_idx);

            // Build viewport point for this cell
            var point: gt.Point = undefined;
            point.tag = gt.c.GHOSTTY_POINT_TAG_VIEWPORT;
            point.value = .{ .coordinate = .{ .x = col, .y = @intCast(row) } };

            // Resolve grid ref
            var grid_ref = std.mem.zeroes(gt.GridRef);
            grid_ref.size = @sizeOf(gt.GridRef);
            if (gt.c.ghostty_terminal_grid_ref(terminal, point, &grid_ref) != gt.SUCCESS) {
                if (in_link and span_count < spans.len and col > link_start_col) {
                    spans[span_count] = .{ .row = row, .col_start = link_start_col, .col_end = col, .uri_start = link_uri_start, .uri_len = link_uri_len };
                    span_count += 1;
                }
                in_link = false;
                continue;
            }

            // Query hyperlink URI (stack buffer; heap fallback for long URIs)
            var uri_stack: [2048]u8 = undefined;
            var out_len: usize = 0;
            var result = gt.c.ghostty_grid_ref_hyperlink_uri(&grid_ref, &uri_stack, uri_stack.len, &out_len);
            var heap_uri: ?[]u8 = null;
            defer if (heap_uri) |buf| std.heap.c_allocator.free(buf);

            if (result == gt.OUT_OF_SPACE and out_len > uri_stack.len) {
                if (std.heap.c_allocator.alloc(u8, out_len)) |buf| {
                    heap_uri = buf;
                    result = gt.c.ghostty_grid_ref_hyperlink_uri(&grid_ref, buf.ptr, buf.len, &out_len);
                } else |_| {}
            }

            if (result == gt.SUCCESS and out_len > 0) {
                const uri = if (heap_uri) |buf| buf[0..out_len] else uri_stack[0..out_len];
                // Check if this extends the current span (same URI)
                if (in_link and link_uri_len == out_len and
                    std.mem.eql(u8, uri_buf[link_uri_start..link_uri_start + link_uri_len], uri))
                {
                    // Same URI — span continues
                } else {
                    // Close previous span if any
                    if (in_link and span_count < spans.len and col > link_start_col) {
                        spans[span_count] = .{ .row = row, .col_start = link_start_col, .col_end = col, .uri_start = link_uri_start, .uri_len = link_uri_len };
                        span_count += 1;
                    }
                    // Start new span, copy URI to shared buffer
                    if (uri_used + out_len <= uri_buf.len) {
                        @memcpy(uri_buf[uri_used .. uri_used + out_len], uri);
                        link_uri_start = uri_used;
                        link_uri_len = out_len;
                        uri_used += out_len;
                        link_start_col = col;
                        in_link = true;
                    } else {
                        in_link = false;
                    }
                }
            } else {
                // No hyperlink on this cell — close any open span
                if (in_link and span_count < spans.len and col > link_start_col) {
                    spans[span_count] = .{ .row = row, .col_start = link_start_col, .col_end = col, .uri_start = link_uri_start, .uri_len = link_uri_len };
                    span_count += 1;
                }
                in_link = false;
            }
        }

        // Close span at end of row
        if (in_link and span_count < spans.len and cols > link_start_col) {
            spans[span_count] = .{ .row = row, .col_start = link_start_col, .col_end = cols, .uri_start = link_uri_start, .uri_len = link_uri_len };
            span_count += 1;
        }
    }

    return .{ .count = span_count, .uri_used = uri_used };
}

/// Apply hyperlink text properties to the Emacs buffer.
/// Row indices are relative to the viewport — caller passes the char
/// position of the first viewport line so we can resolve absolute rows.
fn applyHyperlinks(
    env: emacs.Env,
    spans: []const HyperlinkSpan,
    span_count: usize,
    uri_buf: []const u8,
    viewport_start: i64,
) void {
    if (span_count == 0) return;

    const s = &emacs.sym;
    // Cache the link keymap value
    const link_map = env.call1(s.@"symbol-value", s.@"ghostel-link-map");

    for (spans[0..span_count]) |span| {
        const uri = uri_buf[span.uri_start..span.uri_start + span.uri_len];
        if (uri.len == 0) continue;

        // Navigate to span start (viewport-relative row -> absolute line)
        env.gotoCharN(viewport_start);
        _ = env.forwardLine(@as(i64, span.row));
        env.moveToColumn(@as(i64, span.col_start));
        const start = env.point();
        env.moveToColumn(@as(i64, span.col_end));
        const end = env.point();

        env.putTextProperty(start, end, s.@"help-echo", env.makeString(uri));
        env.putTextProperty(start, end, s.@"mouse-face", s.highlight);
        env.putTextProperty(start, end, s.keymap, link_map);
    }
}

/// Check if the current row in the iterator is soft-wrapped.
fn isRowWrapped(term: *Terminal) bool {
    var raw_row: gt.c.GhosttyRow = undefined;
    if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.c.GHOSTTY_RENDER_STATE_ROW_DATA_RAW, @ptrCast(&raw_row)) != gt.SUCCESS) {
        return false;
    }
    var wrapped: bool = false;
    _ = gt.c.ghostty_row_get(raw_row, gt.ROW_DATA_WRAP, @ptrCast(&wrapped));
    return wrapped;
}

/// Check if the current row in the iterator is a semantic prompt.
fn isRowPrompt(term: *Terminal) bool {
    var raw_row: gt.c.GhosttyRow = undefined;
    if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.c.GHOSTTY_RENDER_STATE_ROW_DATA_RAW, @ptrCast(&raw_row)) != gt.SUCCESS) {
        return false;
    }
    var semantic: c_int = 0;
    _ = gt.c.ghostty_row_get(raw_row, gt.ROW_DATA_SEMANTIC_PROMPT, @ptrCast(&semantic));
    return semantic != 0;
}

/// Return true if row `cy` (0-indexed, viewport-relative) renders to an
/// empty Emacs buffer line — no cell has a grapheme and no cell has
/// non-default styling.  Matches `buildRowContent`'s trim rules: a row
/// for which this returns true produces `byte_len == 0`.
///
/// Assumes the caller has refreshed the render state (via
/// `ghostty_render_state_update`).  Drives the row iterator, so callers
/// must not rely on iterator position after this call.
pub fn isRowEmptyAt(term: *Terminal, cy: u16) bool {
    if (gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_ROW_ITERATOR, @ptrCast(&term.row_iterator)) != gt.SUCCESS) return false;

    var ri: u16 = 0;
    while (ri <= cy) : (ri += 1) {
        if (!gt.c.ghostty_render_state_row_iterator_next(term.row_iterator)) return false;
    }

    if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.RS_ROW_DATA_CELLS, @ptrCast(&term.row_cells)) != gt.SUCCESS) {
        return false;
    }

    while (gt.c.ghostty_render_state_row_cells_next(term.row_cells)) {
        var graphemes_len: u32 = 0;
        if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_LEN, @ptrCast(&graphemes_len)) == gt.SUCCESS and graphemes_len > 0) {
            return false;
        }
        // Mirror `buildRowContent`: wide-spacer-tail cells are skipped
        // outright and never contribute to buffer content, even when
        // they carry non-default styling.
        var raw_cell: gt.c.GhosttyCell = undefined;
        if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(&raw_cell)) == gt.SUCCESS) {
            var wide: c_int = gt.c.GHOSTTY_CELL_WIDE_NARROW;
            _ = gt.c.ghostty_cell_get(raw_cell, gt.c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
            if (wide == gt.c.GHOSTTY_CELL_WIDE_SPACER_TAIL) continue;
        }
        if (!readCellStyle(term.row_cells).isDefault()) return false;
    }
    return true;
}

/// Hash the first ~16 cells of libghostty's first scrollback row using
/// FNV-1a. Returns 0 if there is no scrollback or if anything fails.
///
/// Used to detect rotation: when libghostty's scrollback is plateaued at
/// its byte cap, sustained writes evict the oldest row in lockstep with
/// new rows being pushed, so `total_rows` doesn't change and the normal
/// delta-detection sees no work to do. Sampling the first scrollback
/// row's content lets us detect that the row at index 0 has changed
/// underneath us.
///
/// Scrolls libghostty's viewport to the top to read the row, then
/// restores the previous viewport offset. Cheap (~6 libghostty calls);
/// gated by the caller to only run when rotation is suspected.
fn computeFirstScrollbackRowHash(term: *Terminal) u64 {
    const sb = term.getScrollbar() orelse return 0;
    const saved_offset = sb.offset;

    term.scrollViewport(gt.SCROLL_TOP, 0);
    defer {
        term.scrollViewport(gt.SCROLL_TOP, 0);
        if (saved_offset > 0) {
            term.scrollViewport(gt.SCROLL_DELTA, @intCast(saved_offset));
        }
    }

    if (gt.c.ghostty_render_state_update(term.render_state, term.terminal) != gt.SUCCESS) return 0;
    if (gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_ROW_ITERATOR, @ptrCast(&term.row_iterator)) != gt.SUCCESS) return 0;
    if (!gt.c.ghostty_render_state_row_iterator_next(term.row_iterator)) return 0;
    if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.RS_ROW_DATA_CELLS, @ptrCast(&term.row_cells)) != gt.SUCCESS) return 0;

    // FNV-1a 64-bit hash. We mix in the first ~16 cells' first
    // codepoints (or a space for empty cells) — enough entropy to
    // distinguish rotation states without scanning the whole row.
    const fnv_prime: u64 = 0x100000001b3;
    var hash: u64 = 0xcbf29ce484222325;
    var i: usize = 0;
    while (i < 16 and gt.c.ghostty_render_state_row_cells_next(term.row_cells)) : (i += 1) {
        var graphemes_len: u32 = 0;
        if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_LEN, @ptrCast(&graphemes_len)) != gt.SUCCESS) continue;
        if (graphemes_len == 0) {
            hash = (hash ^ ' ') *% fnv_prime;
            continue;
        }
        var codepoints: [4]u32 = undefined;
        if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_BUF, @ptrCast(&codepoints)) != gt.SUCCESS) continue;
        hash = (hash ^ codepoints[0]) *% fnv_prime;
    }
    return hash;
}

/// Result from buildRowContent: byte length for make_string, char count for properties.
const RowContent = struct {
    byte_len: usize,
    char_len: usize,
    /// Number of leading characters that are semantic prompt content.
    /// Zero if the row has no prompt cells.
    prompt_char_len: usize,
    /// True when the row contains at least one wide (2-cell) character.
    has_wide: bool,
};

/// Build text content and style runs for the current row in the iterator.
/// Style runs use character (codepoint) offsets for Emacs put-text-property.
///
/// Trailing blank cells — spaces with the default cell style — are
/// trimmed off the end of the row so the Emacs buffer does not carry
/// libghostty's full-width viewport padding. A cell is NOT blank if
/// its character is non-space, or if its style has any non-default
/// attribute (e.g. a colored background, underline, etc.), so visibly-
/// styled blanks are preserved. Style runs extending past the trim
/// point are clipped to the new length by `insertAndStyle'.
fn buildRowContent(
    term: *Terminal,
    text_buf: []u8,
    runs: []RunInfo,
    run_count: *usize,
) RowContent {
    var text_len: usize = 0; // byte offset
    var char_len: usize = 0; // character (codepoint) offset
    // Position at the end of the last non-blank cell; final row length
    // is trimmed back to this. Any run of blank cells past the end is
    // discarded along with their default-style trailing padding.
    var trim_text_len: usize = 0;
    var trim_char_len: usize = 0;
    var prompt_char_len: usize = 0; // chars that are semantic prompt
    var in_prompt: bool = true; // track contiguous leading prompt cells
    var has_wide: bool = false;
    run_count.* = 0;
    var current_style: CellStyle = .{};
    var run_start_char: usize = 0;

    while (gt.c.ghostty_render_state_row_cells_next(term.row_cells)) {
        var graphemes_len: u32 = 0;
        if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_LEN, @ptrCast(&graphemes_len)) != gt.SUCCESS) {
            continue;
        }

        // Raw cell handle, fetched lazily for the semantic-content and
        // wide-spacer checks that each need it. Without the shared slot,
        // empty prompt padding would pay for two cells_get(RAW) calls.
        var raw_cell: gt.c.GhosttyCell = undefined;
        var raw_tag: RawTag = .unset;

        // Track leading prompt characters via cell-level semantic content.
        if (in_prompt) {
            var semantic: c_int = 0; // GHOSTTY_CELL_SEMANTIC_OUTPUT
            if (loadRawCell(term.row_cells, &raw_cell, &raw_tag)) {
                _ = gt.c.ghostty_cell_get(raw_cell, gt.c.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, @ptrCast(&semantic));
            }
            if (semantic != gt.c.GHOSTTY_CELL_SEMANTIC_PROMPT) {
                in_prompt = false;
            }
        }

        const cell_style = readCellStyle(term.row_cells);

        // Flush run on style change
        if (char_len > run_start_char and !cell_style.eql(current_style)) {
            if (run_count.* < runs.len) {
                runs[run_count.*] = .{
                    .start_char = run_start_char,
                    .end_char = char_len,
                    .style = current_style,
                };
                run_count.* += 1;
            }
            run_start_char = char_len;
            current_style = cell_style;
        } else if (char_len == run_start_char) {
            current_style = cell_style;
        }

        if (graphemes_len == 0) {
            // Wide-character spacer tails occupy a terminal cell but must
            // not produce output — the preceding wide cell already accounts
            // for 2 visual columns in Emacs.
            var wide: c_int = gt.c.GHOSTTY_CELL_WIDE_NARROW;
            if (loadRawCell(term.row_cells, &raw_cell, &raw_tag)) {
                _ = gt.c.ghostty_cell_get(raw_cell, gt.c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
            }
            if (wide == gt.c.GHOSTTY_CELL_WIDE_SPACER_TAIL) {
                has_wide = true;
                continue;
            }
            if (text_len < text_buf.len) {
                text_buf[text_len] = ' ';
                text_len += 1;
                char_len += 1;
            }
            if (in_prompt) prompt_char_len = char_len;
            // Empty cells are blank for trim purposes unless their
            // style has a visible attribute (e.g. colored background).
            if (!cell_style.isDefault()) {
                trim_text_len = text_len;
                trim_char_len = char_len;
            }
            continue;
        }

        var codepoints: [16]u32 = undefined;
        const cp_count = @min(graphemes_len, 16);
        if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_BUF, @ptrCast(&codepoints)) != gt.SUCCESS) {
            continue;
        }

        for (0..cp_count) |i| {
            const cp: u21 = @intCast(codepoints[i]);
            const remaining = text_buf[text_len..];
            if (remaining.len < 4) break;
            const encoded_len = std.unicode.utf8Encode(cp, remaining) catch continue;
            text_len += encoded_len;
            char_len += 1; // one codepoint = one Emacs character
        }
        if (in_prompt) prompt_char_len = char_len;
        // Any cell that libghostty stored a grapheme for was written
        // explicitly by the terminal, so it anchors the trim point —
        // even if the grapheme happens to be a space (e.g. the space
        // in a \"$ \" prompt, or a space the shell intentionally
        // emitted as part of a layout). Only unwritten padding cells
        // (the `graphemes_len == 0' branch above) are considered blank.
        trim_text_len = text_len;
        trim_char_len = char_len;
    }

    // Trim trailing blank cells. Cap `prompt_char_len' at the new
    // `char_len' so the "leading prompt" region never extends past the
    // trimmed text. Style runs extending past the trim point are
    // clipped by `insertAndStyle' via its `content.char_len' cap.
    text_len = trim_text_len;
    char_len = trim_char_len;
    if (prompt_char_len > char_len) prompt_char_len = char_len;

    // Close final run
    if (char_len > run_start_char and run_count.* < runs.len) {
        runs[run_count.*] = .{
            .start_char = run_start_char,
            .end_char = char_len,
            .style = current_style,
        };
        run_count.* += 1;
    }

    return .{ .byte_len = text_len, .char_len = char_len, .prompt_char_len = prompt_char_len, .has_wide = has_wide };
}

/// Insert row text and apply style runs.
fn insertAndStyle(
    env: emacs.Env,
    text_buf: []const u8,
    content: RowContent,
    runs: []const RunInfo,
    run_count: usize,
    default_fg: gt.ColorRgb,
    default_bg: gt.ColorRgb,
) void {
    if (content.byte_len == 0) return;

    const insert_start = env.extractInteger(env.point());
    env.insert(text_buf[0..content.byte_len]);

    for (runs[0..run_count]) |run| {
        if (run.start_char >= content.char_len) break;
        const run_end = @min(run.end_char, content.char_len);
        if (run_end <= run.start_char) continue;

        const prop_start = insert_start + @as(i64, @intCast(run.start_char));
        const prop_end = insert_start + @as(i64, @intCast(run_end));
        applyStyle(env, prop_start, prop_end, run.style, default_fg, default_bg);
    }
}

/// Insert `count` libghostty rows starting at `first_row` (0 = top of
/// scrollback) into the Emacs buffer at `point`. Each row is followed by
/// a newline; soft-wrapped rows get the `ghostel-wrap` property on their
/// trailing newline so copy-mode can filter them out.
///
/// Drives libghostty by scrolling its viewport through the requested range
/// and re-querying the render state for each page. The caller is expected
/// to save and restore the libghostty viewport position around this call.
///
/// Returns the number of rows actually inserted.
fn insertScrollbackRange(
    env: emacs.Env,
    term: *Terminal,
    first_row: usize,
    count: usize,
    default_fg: gt.ColorRgb,
    default_bg: gt.ColorRgb,
) usize {
    if (count == 0) return 0;

    // Position libghostty viewport at first_row.
    term.scrollViewport(gt.SCROLL_TOP, 0);
    if (first_row > 0) {
        term.scrollViewport(gt.SCROLL_DELTA, @intCast(first_row));
    }

    var runs: [512]RunInfo = undefined;
    var text_buf: [16384]u8 = undefined;

    var inserted: usize = 0;

    while (inserted < count) {
        const cur_sb = term.getScrollbar() orelse break;
        const viewport_start = cur_sb.offset;

        if (gt.c.ghostty_render_state_update(term.render_state, term.terminal) != gt.SUCCESS) break;
        if (gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_ROW_ITERATOR, @ptrCast(&term.row_iterator)) != gt.SUCCESS) break;

        const absolute_target = first_row + inserted;
        const skip: usize = if (absolute_target > viewport_start) absolute_target - viewport_start else 0;
        if (skip >= term.rows) break;
        const take: usize = @min(term.rows - skip, count - inserted);
        if (take == 0) break;

        var row_in_page: usize = 0;
        var took: usize = 0;
        while (gt.c.ghostty_render_state_row_iterator_next(term.row_iterator)) {
            defer row_in_page += 1;
            if (row_in_page < skip) continue;
            if (took >= take) break;

            if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.RS_ROW_DATA_CELLS, @ptrCast(&term.row_cells)) != gt.SUCCESS) {
                took += 1;
                inserted += 1;
                continue;
            }

            var run_count: usize = 0;
            var content = buildRowContent(term, &text_buf, &runs, &run_count);

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
            const newline_in_buf = content.byte_len < text_buf.len;
            if (newline_in_buf) {
                text_buf[content.byte_len] = '\n';
                content.byte_len += 1;
                content.char_len += 1;
            }

            const row_start = env.extractInteger(env.point());
            insertAndStyle(env, &text_buf, content, &runs, run_count, default_fg, default_bg);
            if (!newline_in_buf) {
                env.insert("\n");
            }
            const after_insert = env.extractInteger(env.point());

            if (content.prompt_char_len > 0) {
                env.putTextProperty(
                    env.makeInteger(row_start),
                    env.makeInteger(row_start + @as(i64, @intCast(content.prompt_char_len))),
                    emacs.sym.@"ghostel-prompt",
                    env.t(),
                );
            } else if (isRowPrompt(term)) {
                env.putTextProperty(
                    env.makeInteger(row_start),
                    env.makeInteger(after_insert - 1), // exclude trailing newline
                    emacs.sym.@"ghostel-prompt",
                    env.t(),
                );
            }

            // Mark the trailing newline with ghostel-wrap if the row is
            // soft-wrapped, so copy-mode can filter wrap newlines from
            // copied text.
            if (isRowWrapped(term)) {
                env.putTextProperty(
                    env.makeInteger(after_insert - 1),
                    env.makeInteger(after_insert),
                    emacs.sym.@"ghostel-wrap",
                    env.t(),
                );
            }

            took += 1;
            inserted += 1;
        }

        if (inserted >= count) break;
        // Advance viewport by a full page for the next iteration.
        term.scrollViewport(gt.SCROLL_DELTA, @intCast(term.rows));
    }

    return inserted;
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
fn positionCursorByCell(env: emacs.Env, term: *Terminal, cx: u16, cy: u16) bool {
    if (cx == 0) return true; // already at column 0

    if (gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_ROW_ITERATOR, @ptrCast(&term.row_iterator)) != gt.SUCCESS) {
        return false;
    }

    // Advance iterator to cursor row cy.
    {
        var ri: u16 = 0;
        while (ri <= cy) : (ri += 1) {
            if (!gt.c.ghostty_render_state_row_iterator_next(term.row_iterator)) {
                return false;
            }
        }
    }

    if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.RS_ROW_DATA_CELLS, @ptrCast(&term.row_cells)) != gt.SUCCESS) {
        return false;
    }

    // Walk cells 0..cx-1, counting Emacs characters.
    var col: u16 = 0;
    var char_count: i64 = 0;
    while (col < cx) : (col += 1) {
        if (!gt.c.ghostty_render_state_row_cells_next(term.row_cells)) break;

        var graphemes_len: u32 = 0;
        _ = gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.RS_CELLS_DATA_GRAPHEMES_LEN, @ptrCast(&graphemes_len));

        if (graphemes_len == 0) {
            // Spacer tails produce no Emacs character.
            var raw_cell: gt.c.GhosttyCell = undefined;
            var wide: c_int = gt.c.GHOSTTY_CELL_WIDE_NARROW;
            if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(&raw_cell)) == gt.SUCCESS) {
                _ = gt.c.ghostty_cell_get(raw_cell, gt.c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
            }
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

/// Redraw the terminal into the current Emacs buffer.
///
/// Maintains a "growing buffer" model where the Emacs buffer contains
/// all materialized scrollback (above) and the current viewport (below).
/// On each call we:
///   1. Force libghostty's viewport to the bottom (active screen).
///   2. Poll `getTotalRows()` against `term.scrollback_in_buffer` to
///      detect rows that scrolled off the top of the viewport and promoted them
///      to the scrollback part of the buffer
///   3. Render the viewport into the tail of the buffer, anchored at
///      the line that follows the last scrollback row.
///
/// When `force_full` is true, the viewport region is fully re-rendered
/// instead of using the incremental dirty-row path.
pub fn redraw(env: emacs.Env, term: *Terminal, force_full_arg: bool) void {
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

    var force_full = force_full_arg;

    // Lock the libghostty viewport to the bottom. Users navigate history
    // through Emacs now, so any lingering scroll offset (e.g. from an
    // explicit ghostel--scroll) would desync our scrollback tracker.
    if (term.getScrollbar()) |sb| {
        if (sb.len + sb.offset < sb.total) {
            term.scrollViewport(gt.SCROLL_BOTTOM, 0);
        }
    }

    // Update render state from terminal
    if (gt.c.ghostty_render_state_update(term.render_state, term.terminal) != gt.SUCCESS) {
        return;
    }

    // Resolve default colors once — used for both the scrollback append
    // path and the viewport render path.  These always succeed (the
    // render state always has resolved default colors), so batching is safe.
    var default_fg = gt.ColorRgb{ .r = 204, .g = 204, .b = 204 };
    var default_bg = gt.ColorRgb{ .r = 0, .g = 0, .b = 0 };
    {
        const color_keys = [_]gt.c.GhosttyRenderStateData{
            gt.RS_DATA_COLOR_FOREGROUND,
            gt.RS_DATA_COLOR_BACKGROUND,
        };
        var color_values = [_]?*anyopaque{
            @ptrCast(&default_fg),
            @ptrCast(&default_bg),
        };
        _ = gt.c.ghostty_render_state_get_multi(term.render_state, color_keys.len, &color_keys, @ptrCast(&color_values), null);
    }

    // ---- Scrollback validity ------------------------------------------------
    // Two signals can invalidate buffered scrollback and are collected here;
    // a third (rotation) is checked below.
    //
    //   rebuild_pending: set by terminal.resize() and by the CSI 3 J scanner
    //                    in vtWrite. Defers the Emacs-buffer erase into the
    //                    redraw pass where inhibit-redisplay prevents a
    //                    visible blank frame.
    //
    //   rotation:        checked below via a row-0 hash; only computed when
    //                    rebuild_pending hasn't already fired.
    var scrollback_stale = term.rebuild_pending;
    term.rebuild_pending = false;

    // ---- Rotation detection ------------------------------------------------
    // When libghostty's scrollback cap is saturated, sustained writes evict
    // the oldest rows. total_rows doesn't change, so the delta-sync below
    // would see nothing to do — detect the churn by hashing the first
    // scrollback row and comparing to the value sampled at the last redraw.
    //
    // Skip when scrollback is already known to be stale: the viewport scroll
    // that sampling requires is wasted work if we are about to erase anyway.
    // On a hash match, stash the value for reuse at end-of-redraw (promotion
    // and insert-at-tail don't shift row 0, so it stays valid).
    var cached_row0_hash: ?u64 = null;
    if (!scrollback_stale and
        term.wrote_since_redraw and
        term.scrollback_in_buffer > 0 and
        term.first_scrollback_row_hash != 0)
    {
        const new_hash = computeFirstScrollbackRowHash(term);
        // computeFirstScrollbackRowHash scrolled libghostty's viewport to
        // sample row 0; the render state is now stale — refresh it.
        if (gt.c.ghostty_render_state_update(term.render_state, term.terminal) != gt.SUCCESS) return;
        if (new_hash != term.first_scrollback_row_hash) {
            scrollback_stale = true;
        } else {
            cached_row0_hash = new_hash;
        }
    }

    // Compare counts: scrollback shrinking means the buffered rows are no
    // longer valid (CSI 3 J or resize would have set rebuild_pending, but
    // this catches any other unexpected reduction).
    const total_rows = term.getTotalRows();
    const libghostty_sb: usize = if (total_rows > term.rows) total_rows - term.rows else 0;
    if (libghostty_sb < term.scrollback_in_buffer) scrollback_stale = true;

    // If scrollback is stale for any reason, erase it completely.
    if (scrollback_stale) {
        env.eraseBuffer();
        term.scrollback_in_buffer = 0;
        term.first_scrollback_row_hash = 0;
        force_full = true;
    }

    // ---- Scrollback sync ---------------------------------------------------
    // libghostty stores scrollback + active screen in a single row space.
    // The rows "above" the viewport are scrollback; our invariant is that
    // those rows are all materialized in the Emacs buffer, one per line.
    //
    // We compute the viewport-start char position at most once per redraw
    // by walking from point-min and reusing point() after any insert/trim
    // touches it. forwardLine is O(scrollback) so doing it twice would
    // double the per-redraw cost in long-running sessions.

    // Walk to the current viewport start (line scrollback_in_buffer + 1).
    env.gotoCharN(1);
    if (term.scrollback_in_buffer > 0) {
        _ = env.forwardLine(@as(i64, @intCast(term.scrollback_in_buffer)));
    }
    var viewport_start_int = env.extractInteger(env.point());

    if (libghostty_sb > term.scrollback_in_buffer) {
        // New rows scrolled off in libghostty. Strategy:
        //
        // 1. Promote as many existing buffer rows as possible. The rows
        //    that were at the top of the viewport in the previous redraw
        //    are exactly the rows libghostty just pushed into scrollback,
        //    so just bumping `scrollback_in_buffer` makes them scrollback
        //    in our model too — no fetch, no re-render. Critically, any
        //    text properties applied to those rows while they were in the
        //    viewport (URL detection, ghostel-prompt, etc.) survive
        //    automatically because we never touch the text.
        //
        // 2. If the buffer didn't have enough viewport rows to absorb the
        //    full delta (bootstrap, post-resize, or a burst that scrolled
        //    more rows than the viewport between redraws), fall back to
        //    `insertScrollbackRange` for the remainder.
        var delta = libghostty_sb - term.scrollback_in_buffer;

        // Skip promotion when the entire previous viewport scrolled off
        // during first materialization.  The buffer still contains the
        // initial viewport (often mostly empty rows from before any
        // output) which was overwritten at the cursor before scrolling
        // off — promoted rows would be stale.  When delta < rows only
        // the topmost rows scrolled off; those sat above the cursor and
        // were not overwritten, so promotion is safe even on the first
        // burst.  The stale old viewport tail gets cleaned up by the
        // deleteRegion(viewport_start, pointMax) in the viewport
        // renderer below.
        var promoted: usize = 0;
        if (term.scrollback_in_buffer > 0 or delta < term.rows) {
            env.gotoCharN(viewport_start_int);
            const remaining_lines = env.forwardLine(@as(i64, @intCast(delta)));
            promoted = delta - @as(usize, @intCast(remaining_lines));

            // forward-line counts the position right after the last buffer
            // char as a moveable "line N+1" even when the buffer doesn't
            // end in \n. That position corresponds to our terminal cursor
            // row — a stale snapshot, NOT a real libghostty scrollback row.
            // If we landed at pointMax with no trailing newline, peel one
            // off the promoted count so we don't promote the cursor row.
            if (promoted > 0 and env.extractInteger(env.point()) == env.extractInteger(env.pointMax())) {
                const cb = env.call0(emacs.sym.@"char-before");
                if (env.isNotNil(cb) and env.extractInteger(cb) != '\n') {
                    promoted -= 1;
                }
            }

            if (promoted > 0) {
                term.scrollback_in_buffer += promoted;
                // forward-line may have left point at pointMax even when it
                // partially walked past complete lines, so always re-walk
                // exactly `promoted` newline-bounded lines to anchor the new
                // viewport_start at the start of the first un-promoted row.
                env.gotoCharN(viewport_start_int);
                _ = env.forwardLine(@as(i64, @intCast(promoted)));
                viewport_start_int = env.extractInteger(env.point());
                delta -= promoted;
            }
        }

        if (delta > 0) {
            // Bootstrap fallback: fetch the rest from libghostty.
            env.gotoCharN(viewport_start_int);
            const inserted = insertScrollbackRange(
                env,
                term,
                term.scrollback_in_buffer,
                delta,
                default_fg,
                default_bg,
            );
            term.scrollback_in_buffer += inserted;
            viewport_start_int = env.extractInteger(env.point());

            // insertScrollbackRange scrolled libghostty's viewport through
            // the scrollback range — restore it to the active screen and
            // refresh the render state for the viewport render below.
            term.scrollViewport(gt.SCROLL_BOTTOM, 0);
            if (gt.c.ghostty_render_state_update(term.render_state, term.terminal) != gt.SUCCESS) return;
        }
    }

    // Check dirty state — cells are only redrawn when dirty, but cursor
    // positioning always runs so that cursor-only movements are visible.
    // force_full overrides: the buffer may have been erased by scrollback
    // sync / resize / rotation above, so we must rebuild even if
    // libghostty considers the cells clean.
    var dirty: c_int = gt.DIRTY_FALSE;
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_DIRTY, @ptrCast(&dirty));
    var has_hyperlinks: bool = false;
    var hyperlink_rows: [256]u16 = undefined;
    var hyperlink_row_count: usize = 0;
    var has_wide_chars: bool = false;

    if (dirty != gt.DIRTY_FALSE or force_full) {
        // Set buffer default face
        var fg_hex: [7]u8 = undefined;
        var bg_hex: [7]u8 = undefined;
        _ = env.call2(
            emacs.sym.@"ghostel--set-buffer-face",
            env.makeString(formatColor(default_fg, &fg_hex)),
            env.makeString(formatColor(default_bg, &bg_hex)),
        );

        // Get row iterator
        if (gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_ROW_ITERATOR, @ptrCast(&term.row_iterator)) != gt.SUCCESS) {
            return;
        }

        // Incremental redraw: only update dirty rows when possible.
        // force_full bypasses partial mode to avoid stale rows after scrolls.
        const partial = (!force_full and dirty == gt.DIRTY_PARTIAL);
        if (!partial) {
            // Wipe only the viewport region; scrollback stays intact.
            env.deleteRegion(env.makeInteger(viewport_start_int), env.pointMax());
        }

        // Shared buffers for row content
        var runs: [512]RunInfo = undefined;
        var text_buf: [16384]u8 = undefined;

        var row_count: usize = 0;
        var prev_wrapped: bool = false;
        while (gt.c.ghostty_render_state_row_iterator_next(term.row_iterator)) {
            if (partial) {
                // Only process dirty rows
                var row_dirty: bool = false;
                _ = gt.c.ghostty_render_state_row_get(term.row_iterator, gt.RS_ROW_DATA_DIRTY, @ptrCast(&row_dirty));
                if (!row_dirty) {
                    row_count += 1;
                    // Still need to track wrap state for next row
                    prev_wrapped = isRowWrapped(term);
                    continue;
                }
            }

            // Get cells for this row
            if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.RS_ROW_DATA_CELLS, @ptrCast(&term.row_cells)) != gt.SUCCESS) {
                row_count += 1;
                prev_wrapped = false;
                continue;
            }

            // Check for hyperlinks (row-level flag, may have false positives)
            {
                var raw_row: gt.c.GhosttyRow = undefined;
                if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.c.GHOSTTY_RENDER_STATE_ROW_DATA_RAW, @ptrCast(&raw_row)) == gt.SUCCESS) {
                    var row_has_links: bool = false;
                    _ = gt.c.ghostty_row_get(raw_row, gt.ROW_DATA_HYPERLINK, @ptrCast(&row_has_links));
                    if (row_has_links and hyperlink_row_count < hyperlink_rows.len) {
                        hyperlink_rows[hyperlink_row_count] = @intCast(row_count);
                        hyperlink_row_count += 1;
                        has_hyperlinks = true;
                    }
                }
            }

            if (partial) {
                // Navigate to this row (viewport-relative) and clear its content.
                env.gotoCharN(viewport_start_int);
                const moved = env.forwardLine(@as(i64, @intCast(row_count)));
                if (moved != 0) {
                    // Row doesn't exist yet — fall through to append
                    env.gotoChar(env.pointMax());
                    env.insert("\n");
                } else {
                    env.deleteRegion(env.point(), env.lineEndPosition());
                }
                // Clear per-row dirty flag
                const row_clean: bool = false;
                _ = gt.c.ghostty_render_state_row_set(term.row_iterator, gt.RS_ROW_OPT_DIRTY, @ptrCast(&row_clean));
            } else {
                // Full redraw: insert newline between rows
                if (row_count > 0) {
                    const nl_start = env.point();
                    env.insert("\n");
                    // Mark newlines from soft-wrapped rows so copy mode can filter them
                    if (prev_wrapped) {
                        env.putTextProperty(nl_start, env.point(), emacs.sym.@"ghostel-wrap", env.t());
                    }
                }
            }

            // Build row content
            var run_count: usize = 0;
            const content = buildRowContent(term, &text_buf, &runs, &run_count);
            if (content.has_wide) has_wide_chars = true;

            // Insert text and apply styles
            const row_start = env.extractInteger(env.point());
            insertAndStyle(env, &text_buf, content, &runs, run_count, default_fg, default_bg);

            // Mark prompt portion (cell-level boundary), or entire row (row-level fallback).
            if (content.prompt_char_len > 0) {
                env.putTextProperty(
                    env.makeInteger(row_start),
                    env.makeInteger(row_start + @as(i64, @intCast(content.prompt_char_len))),
                    emacs.sym.@"ghostel-prompt",
                    env.t(),
                );
            } else if (isRowPrompt(term)) {
                env.putTextProperty(
                    env.makeInteger(row_start),
                    env.point(),
                    emacs.sym.@"ghostel-prompt",
                    env.t(),
                );
            }

            // Track whether this row is soft-wrapped for the next newline
            prev_wrapped = isRowWrapped(term);
            row_count += 1;
        }

        // Trim excess buffer lines beyond the terminal's row count.
        // Partial redraws don't erase the viewport region, so stale
        // trailing lines can accumulate after a resize or mode switch.
        if (partial and row_count > 0) {
            env.gotoCharN(viewport_start_int);
            if (env.forwardLine(@as(i64, @intCast(row_count))) == 0) {
                env.deleteRegion(env.point(), env.pointMax());
            }
        }

        // Reset dirty state
        const dirty_false: c_int = gt.DIRTY_FALSE;
        _ = gt.c.ghostty_render_state_set(term.render_state, gt.RS_OPT_DIRTY, @ptrCast(&dirty_false));
    }

    // Scan for hyperlinks and apply text properties (before cursor positioning).
    // Uses the grid_ref API to query hyperlink URIs directly from cells,
    // only for rows flagged with GHOSTTY_ROW_DATA_HYPERLINK.
    if (dirty != gt.DIRTY_FALSE and has_hyperlinks) {
        var hl_spans: [128]HyperlinkSpan = undefined;
        var hl_uri_buf: [8192]u8 = undefined;
        const hl = scanHyperlinksFromGrid(
            term.terminal,
            term.cols,
            hyperlink_rows[0..hyperlink_row_count],
            &hl_spans,
            &hl_uri_buf,
        );
        if (hl.count > 0) {
            applyHyperlinks(env, &hl_spans, hl.count, &hl_uri_buf, viewport_start_int);
        }
    }

    // Auto-detect plain-text URLs — only on the viewport region. Scrollback
    // rows are skipped to keep streaming O(viewport) per redraw instead of
    // O(buffer); rows that have already scrolled past stay as plain text
    // and remain searchable, just not clickable.
    if (dirty != gt.DIRTY_FALSE) {
        _ = env.call2(
            emacs.sym.@"ghostel--detect-urls",
            env.makeInteger(viewport_start_int),
            env.pointMax(),
        );
        if (has_wide_chars) {
            _ = env.call2(env.intern("set"), emacs.sym.@"ghostel--has-wide-chars", env.t());
        }
    }

    // Batch-fetch cursor style/visibility (always available).
    var cursor_visible: bool = true;
    var cursor_style: c_int = gt.CURSOR_BLOCK;
    {
        const cursor_keys = [_]gt.c.GhosttyRenderStateData{
            gt.RS_DATA_CURSOR_VISIBLE,
            gt.RS_DATA_CURSOR_VISUAL_STYLE,
        };
        var cursor_values = [_]?*anyopaque{
            @ptrCast(&cursor_visible),
            @ptrCast(&cursor_style),
        };
        _ = gt.c.ghostty_render_state_get_multi(term.render_state, cursor_keys.len, &cursor_keys, @ptrCast(&cursor_values), null);
    }

    // Position cursor (viewport-relative row -> absolute line).
    // X/Y are only valid when HAS_VALUE is true, so query separately
    // to avoid stopping the style batch above on NO_VALUE.
    var cursor_has_value: bool = false;
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_HAS_VALUE, @ptrCast(&cursor_has_value));
    if (cursor_has_value) {
        var cx: u16 = 0;
        var cy: u16 = 0;
        _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_X, @ptrCast(&cx));
        _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_Y, @ptrCast(&cy));

        env.gotoCharN(viewport_start_int);
        _ = env.forwardLine(@as(i64, cy));
        if (!positionCursorByCell(env, term, cx, cy)) {
            env.moveToColumn(@as(i64, cx));
        }
    }

    _ = env.call2(
        emacs.sym.@"ghostel--set-cursor-style",
        env.makeInteger(@as(i64, cursor_style)),
        if (cursor_visible) env.t() else env.nil(),
    );

    // Update working directory from OSC 7
    if (term.getPwd()) |pwd| {
        _ = env.call1(emacs.sym.@"ghostel--update-directory", env.makeString(pwd));
    }

    // Update the cached first-scrollback-row hash for the next redraw's
    // rotation check. Reuse the start-of-redraw hash when it's still
    // valid (no rotation, no trim) — avoids a second scroll-to-top +
    // render_state_update round trip per redraw.
    //
    // If nothing was written AND we didn't populate `cached_row0_hash`
    // at the top, row 0 cannot have moved since the previous redraw
    // set `first_scrollback_row_hash`, so skip the compute entirely.
    // This covers cursor-only redraws and idle-timer fires.
    if (term.scrollback_in_buffer > 0) {
        if (cached_row0_hash) |h| {
            term.first_scrollback_row_hash = h;
        } else if (term.wrote_since_redraw) {
            term.first_scrollback_row_hash = computeFirstScrollbackRowHash(term);
        }
        // else: no writes, no cached hash → existing value is still current.
    } else {
        term.first_scrollback_row_hash = 0;
    }

    // Clear the write flag so the next redraw can detect "writes happened
    // since last redraw" for the rotation check.
    term.wrote_since_redraw = false;
}
