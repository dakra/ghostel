/// Shared style→face translation.
///
/// Both the renderer (which materialises a 2D grid into an Emacs buffer)
/// and the comint stream filter (which transforms a byte stream into
/// propertized text for `comint-preoutput-filter-functions') use the same
/// SGR-to-face plist mapping.
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

// TODO: Style ID type is not exported from ghostty-vt for some reason.
//       We should file an issue.
const StyleId = @FieldType(gt.page.Cell, "style_id");

/// Resolved style attributes for a run of cells.
pub const CellProps = struct {
    style_id: StyleId = 0,
    fg: ?gt.color.RGB = null,
    bg: ?gt.color.RGB = null,
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

    /// True when this run needs no text properties at all
    pub fn isPlain(self: CellProps) bool {
        return std.meta.eql(self, .{});
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

pub fn getGhostelDefaultColor(env: emacs.Env, comptime prop: anytype) !gt.color.RGB {
    const s = emacs.sym;
    const color_val = env.f(
        "ghostel--face-hex-color",
        .{ s.@"ghostel-default", @field(s, prop) },
    );
    var buf: [8]u8 = undefined;
    return try gt.color.RGB.parse(try env.extractString(color_val, &buf));
}

/// Blend a foreground color toward a background color to produce a "dim"
/// effect.  Uses ~65% foreground / ~35% background weighting.
pub fn dimColor(env: emacs.Env, fg: ?gt.color.RGB, bg: ?gt.color.RGB) !gt.color.RGB {
    const fg_e = fg orelse try getGhostelDefaultColor(env, ":foreground");
    const bg_e = bg orelse try getGhostelDefaultColor(env, ":background");
    return .{
        .r = @intCast((@as(u16, fg_e.r) * 166 + @as(u16, bg_e.r) * 90) / 256),
        .g = @intCast((@as(u16, fg_e.g) * 166 + @as(u16, bg_e.g) * 90) / 256),
        .b = @intCast((@as(u16, fg_e.b) * 166 + @as(u16, bg_e.b) * 90) / 256),
    };
}

pub fn resolveForeground(
    style: *const gt.Style,
    palette: *const gt.color.Palette,
    bold_config: ?gt.Style.BoldColor,
) ?gt.color.RGB {
    switch (style.fg_color) {
        .none => {
            if (style.flags.bold) {
                if (bold_config) |bold| switch (bold) {
                    .bright => {},
                    .color => |v| return v,
                };
            }
        },

        .palette => |idx| {
            if (style.flags.bold) {
                if (bold_config) |_| {
                    const bright_offset = @intFromEnum(gt.color.Name.bright_black);
                    if (idx < bright_offset) {
                        return palette[idx + bright_offset];
                    }
                }
            }

            return palette[idx];
        },

        .rgb => |c| return c,
    }

    return null;
}

fn resolveColor(
    palette: *const gt.color.Palette,
    color: gt.Style.Color,
) ?gt.color.RGB {
    return switch (color) {
        .rgb => |rgb| rgb,
        .palette => |idx| palette[idx],
        .none => null,
    };
}

/// Build a face plist (`(:foreground "#xxx" :background "#yyy" ...)`)
/// from a libghostty style.
///
/// The caller is responsible for actually applying the plist via
/// `put-text-property` against either the current buffer or a string.
pub fn buildFacePlist(
    env: emacs.Env,
    style: *const gt.Style,
    palette: *const gt.color.Palette,
    bold_config: ?gt.Style.BoldColor,
) !emacs.Value {
    var face_props: FixedArrayList(emacs.Value, 32) = .{};

    const s = &emacs.sym;

    const fg = resolveForeground(style, palette, bold_config);
    const bg = resolveColor(palette, style.bg_color);
    if (style.flags.faint) {
        var buf: [7]u8 = undefined;
        const dimmed = try dimColor(env, fg, bg);
        const dim_str = formatColor(dimmed, &buf);
        try face_props.append(s.@":foreground");
        try face_props.append(env.makeString(dim_str));
    } else if (fg) |rgb| {
        var buf: [7]u8 = undefined;
        const fg_str = formatColor(rgb, &buf);
        try face_props.append(s.@":foreground");
        try face_props.append(env.makeString(fg_str));
    }

    if (bg) |rgb| {
        var buf: [7]u8 = undefined;
        const bg_str = formatColor(rgb, &buf);
        try face_props.append(s.@":background");
        try face_props.append(env.makeString(bg_str));
    }

    if (style.flags.inverse) {
        try face_props.append(s.@":inverse-video");
        try face_props.append(env.t());
    }

    if (style.flags.bold) {
        try face_props.append(s.@":weight");
        try face_props.append(s.bold);
    }

    if (style.flags.italic) {
        try face_props.append(s.@":slant");
        try face_props.append(s.italic);
    }

    if (style.flags.underline != .none) {
        const underline_color = resolveColor(palette, style.underline_color);

        try face_props.append(s.@":underline");
        if (style.flags.underline == .single and underline_color == null) {
            try face_props.append(env.t());
        } else {
            var ul_props: FixedArrayList(emacs.Value, 4) = .{};
            try ul_props.append(s.@":style");
            try ul_props.append(switch (style.flags.underline) {
                .curly => s.wave,
                .double => s.@"double-line",
                .dotted => s.dot,
                .dashed => s.dash,
                else => s.line,
            });

            if (underline_color) |uc| {
                var uc_buf: [7]u8 = undefined;
                try ul_props.append(s.@":color");
                try ul_props.append(env.makeString(formatColor(uc, &uc_buf)));
            }

            try face_props.append(env.funcall(s.list, ul_props.items()));
        }
    }

    if (style.flags.strikethrough) {
        try face_props.append(s.@":strike-through");
        try face_props.append(env.t());
    }

    if (style.flags.overline) {
        try face_props.append(s.@":overline");
        try face_props.append(env.t());
    }

    return env.funcall(s.list, face_props.items());
}
