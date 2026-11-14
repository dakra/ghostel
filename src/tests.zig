const builtin = @import("builtin");

test {
    _ = @import("emacs.zig");
    _ = @import("png.zig");
    _ = @import("ppm.zig");
    _ = @import("image_composition.zig");
    _ = @import("KittyRenderer.zig");
    _ = @import("GlyphMetricsCache.zig");
    _ = @import("fixed_array_list.zig");
    _ = @import("RefCount.zig");
    _ = @import("input.zig");
    _ = @import("handler.zig");
    if (builtin.os.tag == .windows) {
        _ = @import("ConPtyProcess.zig");
    } else {
        _ = @import("PosixPtyProcess.zig");
        _ = @import("pty_utils.zig");
    }
}
