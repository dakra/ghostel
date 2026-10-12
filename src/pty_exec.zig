//! Runs as the session leader posix_spawn made, with the PTY replica on fd 0.
const std = @import("std");
const c = @import("posix_c");

const sys = std.posix.system;
const usage = "ghostel-pty-exec FILE ARGV0 [ARG...]";

fn fail(msg: []const u8, reason: []const u8) noreturn {
    _ = sys.write(sys.STDERR_FILENO, msg.ptr, msg.len);
    _ = sys.write(sys.STDERR_FILENO, ": ", 2);
    _ = sys.write(sys.STDERR_FILENO, reason.ptr, reason.len);
    std.c._exit(1);
}

pub export fn main(argc: c_int, argv: [*:null]const ?[*:0]const u8) c_int {
    if (argc < 3) fail("Usage", usage);
    const program = argv[1].?;
    const program_argv = argv + 2;

    const claimed = sys.errno(c.ioctl(sys.STDIN_FILENO, c.TIOCSCTTY, @as(c_int, 0)));
    if (claimed != .SUCCESS) fail("Failed to set up PTY replica", @tagName(claimed));

    const exec_rc = std.c.execve(program, program_argv, std.c.environ);
    fail("Failed to start subprocess", @tagName(sys.errno(exec_rc)));
}
