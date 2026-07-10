const std = @import("std");

pub const ProcessParams = struct {
    file: [:0]const u8,
    args: [][:0]const u8,
    env: *const std.process.EnvMap,
    cwd: ?[]const u8 = null,
};

pub const CancellationToken = struct {
    context: *const anyopaque,
    check_fn: *const fn (*const anyopaque) anyerror!void,
    poll_interval_ms: u32,

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
        checked: bool = false,

        fn check(raw: *const anyopaque) !void {
            const context: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            context.checked = true;
        }
    };

    var context = Context{};
    const token = CancellationToken{
        .context = &context,
        .check_fn = Context.check,
        .poll_interval_ms = 20,
    };
    try token.check();
    try std.testing.expect(context.checked);
}
