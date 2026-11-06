const std = @import("std");

pub const ProcessParams = struct {
    file: [:0]const u8,
    args: [][:0]const u8,
    env: *const std.process.Environ.Map,
    cwd: ?[:0]const u8 = null,
};

pub const WinSize = struct {
    cols: u16,
    rows: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

pub const CancellationToken = struct {
    context: *const anyopaque,
    check_fn: *const fn (*const anyopaque) anyerror!void,
    poll_interval: std.Io.Duration,

    pub fn check(self: CancellationToken) !void {
        try self.check_fn(self.context);
    }
};

pub const WriteResult = union(enum) {
    written: usize,
    interrupted,
};

test "CancellationToken delegates cancellation checks" {
    const Context = struct {
        checked: *bool,

        fn check(raw: *const anyopaque) !void {
            const context: *const @This() = @ptrCast(@alignCast(raw));
            context.checked.* = true;
        }
    };

    var checked = false;
    const context = Context{ .checked = &checked };
    const token = CancellationToken{
        .context = &context,
        .check_fn = Context.check,
        .poll_interval = .fromMilliseconds(20),
    };
    try token.check();
    try std.testing.expect(checked);
}
