/// Shared style→face translation.
///
/// Both the renderer (which materialises a 2D grid into an Emacs buffer)
/// and the comint stream filter (which transforms a byte stream into
/// propertized text for `comint-preoutput-filter-functions') need the
/// same SGR-to-face plist mapping.  This module owns the data type
/// (`CellProps`) and the plist builder so the two paths stay in sync.
const std = @import("std");
const emacs = @import("emacs.zig");
const gt = @import("ghostty-vt");
const FixedArrayList = @import("fixed_array_list.zig").FixedArrayList;

/// Globally-stable identity for an OSC 8 hyperlink span.  `.explicit`
/// holds the user-supplied `id=...`; `.implicit` is ghostty's auto-counter
/// for links emitted without one.  Both survive page dupes, so equality
/// is meaningful across the whole buffer.
pub const LinkId = union(enum) {
    explicit: []const u8,
    implicit: u32,
};

pub const Hyperlink = struct {
    id: LinkId,
    uri: []const u8,
};

/// Resolved style attributes for a run of cells.
pub const CellProps = struct {
    fg: gt.color.RGB = .{},
    bg: gt.color.RGB = .{},
    /// Whether the foreground was explicitly set by SGR. When false the
    /// face plist omits `:foreground` so the buffer's default fg shows
    /// through.  Renderer leaves this true so every cell paints opaquely.
    fg_set: bool = true,
    /// As `fg_set`, for background.
    bg_set: bool = true,
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    underline: gt.sgr.Attribute.Underline = .none,
    underline_color: ?gt.color.RGB = null,
    strikethrough: bool = false,
    overline: bool = false,
    inverse: bool = false,
    hyperlink: ?Hyperlink = null,
    semantic_content: gt.page.Cell.SemanticContent = .output,

    /// True if these props match the default style for the given palette
    /// (no face plist needs to be emitted).
    pub fn isDefault(self: CellProps, default_fg: gt.color.RGB, default_bg: gt.color.RGB) bool {
        return std.meta.eql(self, .{ .fg = default_fg, .bg = default_bg });
    }
};

/// Format an RGB color as "#RRGGBB" into a 7-byte buffer.
pub fn formatColor(color: gt.color.RGB, buf: *[7]u8) []const u8 {
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

/// Blend a foreground color toward a background color to produce a "dim"
/// effect.  Uses ~65% foreground / ~35% background weighting.
pub fn dimColor(fg: gt.color.RGB, bg: gt.color.RGB) gt.color.RGB {
    return .{
        .r = @intCast((@as(u16, fg.r) * 166 + @as(u16, bg.r) * 90) / 256),
        .g = @intCast((@as(u16, fg.g) * 166 + @as(u16, bg.g) * 90) / 256),
        .b = @intCast((@as(u16, fg.b) * 166 + @as(u16, bg.b) * 90) / 256),
    };
}

/// Build a face plist (`(:foreground "#xxx" :background "#yyy" ...)`)
/// from CellProps.  Returns null if the resulting plist is empty.
///
/// The caller is responsible for actually applying the plist via
/// `put-text-property` against either the current buffer or a string.
pub fn buildFacePlist(env: emacs.Env, props: CellProps) error{Overflow}!?emacs.Value {
    var face_props: FixedArrayList(emacs.Value, 32) = .{};

    var fg_buf: [7]u8 = undefined;
    var bg_buf: [7]u8 = undefined;
    var dim_buf: [7]u8 = undefined;

    const s = &emacs.sym;

    // Faint dims fg toward bg; needs resolved colors regardless of
    // `fg_set` / `bg_set`.  Otherwise emit fg only when SGR set it,
    // so an unstyled run inherits the buffer's default face.
    if (props.faint) {
        const dimmed = dimColor(props.fg, props.bg);
        const dim_str = formatColor(dimmed, &dim_buf);
        try face_props.append(s.@":foreground");
        try face_props.append(env.makeString(dim_str));
    } else if (props.fg_set) {
        const fg_str = formatColor(props.fg, &fg_buf);
        try face_props.append(s.@":foreground");
        try face_props.append(env.makeString(fg_str));
    }

    if (props.bg_set) {
        const bg_str = formatColor(props.bg, &bg_buf);
        try face_props.append(s.@":background");
        try face_props.append(env.makeString(bg_str));
    }

    // Inverse is a face attribute, not a manual swap: Emacs handles the
    // swap at display time, so a run with no explicit fg/bg correctly
    // inverts against whatever the buffer's default face actually is.
    if (props.inverse) {
        try face_props.append(s.@":inverse-video");
        try face_props.append(env.t());
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

    if (props.overline) {
        try face_props.append(s.@":overline");
        try face_props.append(env.t());
    }

    if (face_props.len == 0) return null;
    return env.funcall(s.list, face_props.items());
}
