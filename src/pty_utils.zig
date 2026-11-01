/// PTY introspection helpers.
///
/// Mirrors libghostty's password-input heuristic (canonical mode + echo
/// off) from `src/termio/Exec.zig` so embedders that don't go through
/// the full `Surface` apprt — like ghostel — can detect the same
/// signal.  The check is purely a read of the slave's termios; it does
/// not change the device's state and is safe to run frequently.
const std = @import("std");
const builtin = @import("builtin");
const sys = std.posix.system;
const c = @import("posix_c");

/// Returns true if the tty at PATH is in canonical mode with echo
/// disabled — the heuristic libghostty uses to decide that the
/// foreground program is reading a password (`stty -echo` is what
/// `getpass(3)`, `sudo`, `ssh`, `gpg`, etc. all do).  Returns false
/// when the path can't be opened, `tcgetattr` fails, or the tty is in
/// some other state (echo on, raw mode under ssh, etc.); callers
/// fall back to a content-based heuristic when their context warrants
/// it (see `ghostel--password-prompt-detected-p').
///
/// `O_NOCTTY` keeps the open from making this fd our controlling tty,
/// and `O_NONBLOCK` keeps it from blocking on a tty that hasn't seen
/// DCD.  Neither flag affects what `tcgetattr` reads.  `RDONLY` is
/// sufficient — we never write to the slave; reducing the mode means
/// a stray write through this fd can't garble the child's input.
pub fn isPasswordMode(path: [*:0]const u8) bool {
    if (builtin.os.tag == .windows) return false;

    const fd = sys.open(path, .{
        .ACCMODE = .RDONLY,
        .NOCTTY = true,
        .NONBLOCK = true,
    });
    if (sys.errno(fd) != .SUCCESS) return false;
    defer _ = sys.close(fd);

    var tio: c.termios = undefined;
    if (c.tcgetattr(fd, &tio) != 0) return false;
    return (tio.c_lflag & c.ICANON) != 0 and (tio.c_lflag & c.ECHO) == 0;
}

test "isPasswordMode: missing paths and non-ttys return false" {
    try std.testing.expect(!isPasswordMode("/dev/null/ghostel-missing-tty"));
    try std.testing.expect(!isPasswordMode("/dev/null"));
}

test "isPasswordMode: only canonical mode with echo disabled is a password mode" {
    const primary_fd = c.posix_openpt(c.O_RDWR | c.O_NOCTTY | c.O_CLOEXEC);
    try std.testing.expect(primary_fd >= 0);
    defer _ = sys.close(primary_fd);
    try std.testing.expectEqual(0, c.grantpt(primary_fd));
    try std.testing.expectEqual(0, c.unlockpt(primary_fd));

    var replica_name: [1024:0]u8 = undefined;
    try std.testing.expectEqual(0, c.ptsname_r(primary_fd, &replica_name, replica_name.len));
    const replica_fd = sys.open(&replica_name, .{ .ACCMODE = .RDWR, .NOCTTY = true });
    try std.testing.expect(sys.errno(replica_fd) == .SUCCESS);
    defer _ = sys.close(replica_fd);

    var attrs: c.termios = undefined;
    try std.testing.expectEqual(0, c.tcgetattr(replica_fd, &attrs));
    const cases = .{
        .{ c.ICANON | c.ECHO, false },
        .{ c.ICANON, true },
        .{ 0, false },
        .{ c.ECHO, false },
    };
    inline for (cases) |case| {
        attrs.c_lflag &= ~@as(@TypeOf(attrs.c_lflag), c.ICANON | c.ECHO);
        attrs.c_lflag |= case[0];
        try std.testing.expectEqual(0, c.tcsetattr(replica_fd, c.TCSANOW, &attrs));
        try std.testing.expectEqual(case[1], isPasswordMode(&replica_name));
    }
}
