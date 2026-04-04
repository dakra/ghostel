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

/// A hyperlink span detected from the HTML formatter output.
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

/// Scan the terminal for hyperlinks using the HTML formatter.
/// Returns the number of hyperlink spans found.
fn scanHyperlinks(
    term: *Terminal,
    spans: []HyperlinkSpan,
    uri_buf: []u8,
) HyperlinkResult {
    // Create HTML formatter
    var opts = std.mem.zeroes(gt.FormatterTerminalOptions);
    opts.size = @sizeOf(gt.FormatterTerminalOptions);
    opts.emit = @intCast(gt.FORMATTER_FORMAT_HTML);

    var formatter: gt.Formatter = undefined;
    if (gt.c.ghostty_formatter_terminal_new(null, &formatter, term.terminal, opts) != gt.SUCCESS) {
        return .{ .count = 0, .uri_used = 0 };
    }
    defer gt.c.ghostty_formatter_free(formatter);

    // Format into a stack buffer; fall back to heap if too small
    var html_buf: [262144]u8 = undefined;
    var out_len: usize = 0;
    if (gt.c.ghostty_formatter_format_buf(formatter, &html_buf, html_buf.len, &out_len) == gt.SUCCESS) {
        return parseHtmlHyperlinks(html_buf[0..out_len], spans, uri_buf);
    }

    const heap_buf = std.heap.page_allocator.alloc(u8, 1024 * 1024) catch {
        return .{ .count = 0, .uri_used = 0 };
    };
    defer std.heap.page_allocator.free(heap_buf);
    if (gt.c.ghostty_formatter_format_buf(formatter, heap_buf.ptr, heap_buf.len, &out_len) != gt.SUCCESS) {
        return .{ .count = 0, .uri_used = 0 };
    }
    return parseHtmlHyperlinks(heap_buf[0..out_len], spans, uri_buf);
}

/// Parse HTML output to extract hyperlink spans and their URIs.
fn parseHtmlHyperlinks(
    html: []const u8,
    spans: []HyperlinkSpan,
    uri_buf: []u8,
) HyperlinkResult {
    var row: u16 = 0;
    var col: u16 = 0;
    var span_count: usize = 0;
    var uri_used: usize = 0;

    var in_link = false;
    var link_start_col: u16 = 0;
    var link_start_row: u16 = 0;
    var link_uri_start: usize = 0;
    var link_uri_len: usize = 0;

    const a_open = "<a href=\"";
    const a_close = "</a>";

    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const remaining = html[i..];
            if (remaining.len >= a_open.len and std.mem.eql(u8, remaining[0..a_open.len], a_open)) {
                // <a href="URI"> — extract URI
                const uri_start_idx = i + a_open.len;
                var uri_end_idx = uri_start_idx;
                while (uri_end_idx < html.len and html[uri_end_idx] != '"') : (uri_end_idx += 1) {}

                const raw_uri = html[uri_start_idx..uri_end_idx];
                // Un-escape HTML entities in the URI
                const decoded_len = htmlUnescapeInto(raw_uri, uri_buf[uri_used..]);
                if (decoded_len > 0) {
                    link_uri_start = uri_used;
                    link_uri_len = decoded_len;
                    uri_used += decoded_len;
                }

                // Close any previous open link
                if (in_link and span_count < spans.len and col > link_start_col) {
                    spans[span_count] = .{
                        .row = link_start_row,
                        .col_start = link_start_col,
                        .col_end = col,
                        .uri_start = link_uri_start,
                        .uri_len = link_uri_len,
                    };
                    span_count += 1;
                }

                in_link = true;
                link_start_row = row;
                link_start_col = col;

                // Skip to end of tag
                while (i < html.len and html[i] != '>') : (i += 1) {}
                if (i < html.len) i += 1;
                continue;
            } else if (remaining.len >= a_close.len and std.mem.eql(u8, remaining[0..a_close.len], a_close)) {
                // </a> — end hyperlink
                if (in_link and span_count < spans.len) {
                    const start_col = if (row == link_start_row) link_start_col else 0;
                    if (col > start_col) {
                        spans[span_count] = .{
                            .row = row,
                            .col_start = start_col,
                            .col_end = col,
                            .uri_start = link_uri_start,
                            .uri_len = link_uri_len,
                        };
                        span_count += 1;
                    }
                }
                in_link = false;
                i += a_close.len;
                continue;
            } else {
                // Other tag — skip to closing >
                while (i < html.len and html[i] != '>') : (i += 1) {}
                if (i < html.len) i += 1;
                continue;
            }
        } else if (html[i] == '&') {
            // HTML entity — counts as 1 visible character
            while (i < html.len and html[i] != ';') : (i += 1) {}
            if (i < html.len) i += 1;
            col += 1;
        } else if (html[i] == '\n') {
            // Row boundary
            if (in_link) {
                const start_col = if (row == link_start_row) link_start_col else 0;
                if (col > start_col and span_count < spans.len) {
                    spans[span_count] = .{
                        .row = row,
                        .col_start = start_col,
                        .col_end = col,
                        .uri_start = link_uri_start,
                        .uri_len = link_uri_len,
                    };
                    span_count += 1;
                }
                // Link continues on next row
                link_start_row = row + 1;
                link_start_col = 0;
            }
            row += 1;
            col = 0;
            i += 1;
        } else {
            // Regular character — advance column, handle UTF-8
            if (html[i] & 0x80 == 0) {
                i += 1;
            } else if (html[i] & 0xE0 == 0xC0) {
                i += 2;
            } else if (html[i] & 0xF0 == 0xE0) {
                i += 3;
            } else {
                i += @min(4, html.len - i);
            }
            col += 1;
        }
    }

    return .{ .count = span_count, .uri_used = uri_used };
}

/// Decode HTML entities in src into dst. Returns number of bytes written.
fn htmlUnescapeInto(src: []const u8, dst: []u8) usize {
    var di: usize = 0;
    var si: usize = 0;
    while (si < src.len and di < dst.len) {
        if (src[si] == '&') {
            const rem = src[si..];
            if (std.mem.startsWith(u8, rem, "&amp;")) {
                dst[di] = '&';
                di += 1;
                si += 5;
            } else if (std.mem.startsWith(u8, rem, "&lt;")) {
                dst[di] = '<';
                di += 1;
                si += 4;
            } else if (std.mem.startsWith(u8, rem, "&gt;")) {
                dst[di] = '>';
                di += 1;
                si += 4;
            } else if (std.mem.startsWith(u8, rem, "&quot;")) {
                dst[di] = '"';
                di += 1;
                si += 6;
            } else if (std.mem.startsWith(u8, rem, "&#39;")) {
                dst[di] = '\'';
                di += 1;
                si += 5;
            } else {
                dst[di] = src[si];
                di += 1;
                si += 1;
            }
        } else {
            dst[di] = src[si];
            di += 1;
            si += 1;
        }
    }
    return di;
}

/// Apply hyperlink text properties to the Emacs buffer.
fn applyHyperlinks(
    env: emacs.Env,
    spans: []const HyperlinkSpan,
    span_count: usize,
    uri_buf: []const u8,
) void {
    if (span_count == 0) return;

    const s = &emacs.sym;
    // Cache the link keymap value
    const link_map = env.call1(s.@"symbol-value", s.@"ghostel-link-map");

    for (spans[0..span_count]) |span| {
        const uri = uri_buf[span.uri_start..span.uri_start + span.uri_len];
        if (uri.len == 0) continue;

        // Navigate to span start
        env.gotoCharN(1);
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
fn buildRowContent(
    term: *Terminal,
    text_buf: []u8,
    runs: []RunInfo,
    run_count: *usize,
) RowContent {
    var text_len: usize = 0; // byte offset
    var char_len: usize = 0; // character (codepoint) offset
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

        // Track leading prompt characters via cell-level semantic content.
        if (in_prompt) {
            var raw_cell: gt.c.GhosttyCell = undefined;
            var semantic: c_int = 0; // GHOSTTY_CELL_SEMANTIC_OUTPUT
            if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(&raw_cell)) == gt.SUCCESS) {
                _ = gt.c.ghostty_cell_get(raw_cell, gt.c.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, @ptrCast(&semantic));
            }
            if (semantic == gt.c.GHOSTTY_CELL_SEMANTIC_PROMPT) {
                // Will be updated below after chars are counted
            } else {
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
            var raw_cell_wide: gt.c.GhosttyCell = undefined;
            var wide: c_int = gt.c.GHOSTTY_CELL_WIDE_NARROW;
            if (gt.c.ghostty_render_state_row_cells_get(term.row_cells, gt.c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(&raw_cell_wide)) == gt.SUCCESS) {
                _ = gt.c.ghostty_cell_get(raw_cell_wide, gt.c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
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
    }

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

/// Redraw the terminal into the current Emacs buffer.
/// When force_full is true, always erase and rebuild (matches Ghostty GPU behaviour).
pub fn redraw(env: emacs.Env, term: *Terminal, force_full: bool) void {
    // Update render state from terminal
    if (gt.c.ghostty_render_state_update(term.render_state, term.terminal) != gt.SUCCESS) {
        return;
    }

    // Check dirty state — cells are only redrawn when dirty, but cursor
    // positioning always runs so that cursor-only movements are visible.
    var dirty: c_int = gt.DIRTY_FALSE;
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_DIRTY, @ptrCast(&dirty));
    var has_hyperlinks: bool = false;
    var has_wide_chars: bool = false;

    if (dirty != gt.DIRTY_FALSE) {
        // Get default colors
        var default_fg = gt.ColorRgb{ .r = 204, .g = 204, .b = 204 };
        var default_bg = gt.ColorRgb{ .r = 0, .g = 0, .b = 0 };
        _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_COLOR_FOREGROUND, @ptrCast(&default_fg));
        _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_COLOR_BACKGROUND, @ptrCast(&default_bg));

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
            env.eraseBuffer();
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
            if (!has_hyperlinks) {
                var raw_row: gt.c.GhosttyRow = undefined;
                if (gt.c.ghostty_render_state_row_get(term.row_iterator, gt.c.GHOSTTY_RENDER_STATE_ROW_DATA_RAW, @ptrCast(&raw_row)) == gt.SUCCESS) {
                    var row_has_links: bool = false;
                    _ = gt.c.ghostty_row_get(raw_row, gt.ROW_DATA_HYPERLINK, @ptrCast(&row_has_links));
                    if (row_has_links) has_hyperlinks = true;
                }
            }

            if (partial) {
                // Navigate to this row and clear its content
                env.gotoCharN(1);
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

            // Mark prompt portion so Elisp navigation can find it
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
        // Partial redraws don't erase the buffer, so stale trailing
        // lines can accumulate after a resize or mode switch.
        if (partial and row_count > 0) {
            env.gotoCharN(1);
            if (env.forwardLine(@as(i64, @intCast(row_count))) == 0) {
                env.deleteRegion(env.point(), env.pointMax());
            }
        }

        // Reset dirty state
        const dirty_false: c_int = gt.DIRTY_FALSE;
        _ = gt.c.ghostty_render_state_set(term.render_state, gt.RS_OPT_DIRTY, @ptrCast(&dirty_false));
    }

    // Scan for hyperlinks and apply text properties (before cursor positioning).
    // Only run the expensive HTML formatter when a viewport row actually has
    // a hyperlink — this avoids formatting the entire terminal (including
    // scrollback) on every redraw.
    if (dirty != gt.DIRTY_FALSE and has_hyperlinks) {
        var hl_spans: [128]HyperlinkSpan = undefined;
        var hl_uri_buf: [8192]u8 = undefined;
        const hl = scanHyperlinks(term, &hl_spans, &hl_uri_buf);
        if (hl.count > 0) {
            applyHyperlinks(env, &hl_spans, hl.count, &hl_uri_buf);
        }
    }

    // Auto-detect plain-text URLs
    if (dirty != gt.DIRTY_FALSE) {
        _ = env.call0(emacs.sym.@"ghostel--detect-urls");
        if (has_wide_chars) {
            _ = env.call0(emacs.sym.@"ghostel--compensate-wide-chars");
        }
    }

    // Position cursor
    var cursor_has_value: bool = false;
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_HAS_VALUE, @ptrCast(&cursor_has_value));
    if (cursor_has_value) {
        var cx: u16 = 0;
        var cy: u16 = 0;
        _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_X, @ptrCast(&cx));
        _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VIEWPORT_Y, @ptrCast(&cy));

        env.gotoCharN(1);
        _ = env.forwardLine(@as(i64, cy));
        env.moveToColumn(@as(i64, cx));
    }

    // Update cursor style
    var cursor_visible: bool = true;
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VISIBLE, @ptrCast(&cursor_visible));

    var cursor_style: c_int = gt.CURSOR_BLOCK;
    _ = gt.c.ghostty_render_state_get(term.render_state, gt.RS_DATA_CURSOR_VISUAL_STYLE, @ptrCast(&cursor_style));

    _ = env.call2(
        emacs.sym.@"ghostel--set-cursor-style",
        env.makeInteger(@as(i64, cursor_style)),
        if (cursor_visible) env.t() else env.nil(),
    );

    // Update working directory from OSC 7
    if (term.getPwd()) |pwd| {
        _ = env.call1(emacs.sym.@"ghostel--update-directory", env.makeString(pwd));
    }
}
