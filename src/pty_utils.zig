/// PTY introspection helpers.
///
/// Mirrors libghostty's password-input heuristic (canonical mode + echo
/// off) from `src/termio/Exec.zig` so embedders that don't go through
/// the full `Surface` apprt — like ghostel — can detect the same
/// signal.  The check is purely a read of the slave's termios; it does
/// not change the device's state and is safe to run frequently.
const std = @import("std");

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
pub fn isPasswordMode(path: []const u8) bool {
    const fd = std.posix.open(path, .{
        .ACCMODE = .RDONLY,
        .NOCTTY = true,
        .NONBLOCK = true,
    }, 0) catch return false;
    defer std.posix.close(fd);

    const tio = std.posix.tcgetattr(fd) catch return false;
    return tio.lflag.ICANON and !tio.lflag.ECHO;
}
