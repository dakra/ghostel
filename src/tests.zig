const builtin = @import("builtin");

test {
    _ = @import("ppm.zig");
    _ = @import("png.zig");
    _ = @import("GlyphMetricsCache.zig");
    _ = @import("fixed_array_list.zig");
    if (builtin.os.tag == .windows) {
        _ = @import("ConPtyProcess.zig");
    } else {
        _ = @import("PosixPtyProcess.zig");
    }
}
