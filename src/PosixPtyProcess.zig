const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const c = @cImport({
    @cDefine("_GNU_SOURCE", {});
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("termios.h");
});

const Self = @This();

const Pty = struct {
    primary_fd: c_int = -1,
    replica_fd: c_int = -1,
    replica_name: [1024]u8 = undefined,

    pub fn init() !Pty {
        var self: @This() = .{};
        self.primary_fd = c.posix_openpt(c.O_RDWR | c.O_NOCTTY | c.O_CLOEXEC);
        if (posix.errno(self.primary_fd) != .SUCCESS) {
            return error.OpenPtFailed;
        }
        errdefer posix.close(self.primary_fd);

        if (posix.errno(c.grantpt(self.primary_fd)) != .SUCCESS) {
            return error.OpenPtFailed;
        }

        if (posix.errno(c.unlockpt(self.primary_fd)) != .SUCCESS) {
            return error.OpenPtFailed;
        }

        const ptsname_err = posix.errno(c.ptsname_r(
            self.primary_fd,
            &self.replica_name,
            self.replica_name.len,
        ));
        if (ptsname_err != .SUCCESS) {
            return error.OpenPtFailed;
        }

        self.replica_fd = try posix.openZ(
            @ptrCast(&self.replica_name),
            .{ .ACCMODE = .RDWR, .NOCTTY = true },
            0,
        );
        errdefer posix.close(self.replica_fd);

        // Configure the line discipline on the replica. On macOS/BSD the
        // master (ptm) fd rejects termios ioctls with ENOTTY; only the
        // replica carries the terminal attributes, so this must run on
        // `replica_fd', not `primary_fd'.
        var attrs: c.termios = undefined;
        if (c.tcgetattr(self.replica_fd, &attrs) != 0) {
            return error.OpenPtFailed;
        }
        // Enable UTF-8 mode so backspace erases multi-byte characters.
        attrs.c_iflag |= c.IUTF8;
        // Disable XON/XOFF flow control so C-q (DC1) and C-s (DC3) pass
        // through to the application instead of being swallowed by the
        // line discipline. Ghostel's send-next-key escape hatch and the
        // direct C-q binding rely on these bytes reaching the child.
        attrs.c_iflag &= ~@as(@TypeOf(attrs.c_iflag), c.IXON);
        if (c.tcsetattr(self.replica_fd, c.TCSANOW, &attrs) != 0) {
            return error.OpenPtFailed;
        }

        return self;
    }

    pub fn resize(self: *@This(), cols: u16, rows: u16) !void {
        const size = c.winsize{ .ws_col = cols, .ws_row = rows, .ws_xpixel = 0, .ws_ypixel = 0 };
        if (posix.errno(c.ioctl(self.primary_fd, c.TIOCSWINSZ, &size)) != .SUCCESS) {
            return error.PtyResizeFailed;
        }
    }

    pub fn write(self: *@This(), data: []const u8) !void {
        var offset: usize = 0;
        while (offset < data.len) {
            offset += posix.write(self.primary_fd, data[offset..data.len]) catch |err| switch (err) {
                // If the master fd is non-blocking, a write that would fill the
                // replica's input buffer fails with WouldBlock; wait for the
                // replica to drain rather than dropping the tail of a large
                // write (e.g. a big paste to a child that reads slowly). Under
                // a blocking fd this branch never fires and the loop is an
                // ordinary blocking write, so write() works in either mode.
                error.WouldBlock => {
                    var pollfds = [_]posix.pollfd{.{
                        .fd = self.primary_fd,
                        .events = posix.POLL.OUT,
                        .revents = undefined,
                    }};
                    _ = try posix.poll(&pollfds, -1);
                    continue;
                },
                else => return err,
            };
        }
    }

    pub fn closePrimary(self: *@This()) void {
        if (self.primary_fd != -1) {
            posix.close(self.primary_fd);
            self.primary_fd = -1;
        }
    }

    pub fn closeReplica(self: *@This()) void {
        if (self.replica_fd != -1) {
            posix.close(self.replica_fd);
            self.replica_fd = -1;
        }
    }

    pub fn replicaName(self: *@This()) []const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(&self.replica_name)));
    }

    pub fn setupReplica(self: *@This()) !void {
        _ = try posix.setsid();
        if (posix.errno(c.ioctl(self.replica_fd, c.TIOCSCTTY)) != .SUCCESS) return error.CttyFailed;
        try posix.dup2(self.replica_fd, posix.STDIN_FILENO);
        try posix.dup2(self.replica_fd, posix.STDOUT_FILENO);
        try posix.dup2(self.replica_fd, posix.STDERR_FILENO);
    }

    pub fn deinit(self: *@This()) void {
        self.closePrimary();
        self.closeReplica();
    }
};

pty: Pty,
pid: posix.pid_t = -1,
wake_pipe: [2]posix.fd_t = .{ -1, -1 },

pub const ProcessParams = @import("ProcessParams.zig");

pub const EventWriter = struct {
    pub const Fd = posix.fd_t;

    fd: Fd,

    pub fn init(fd: Fd) !EventWriter {
        return .{ .fd = fd };
    }

    pub fn write(self: *EventWriter, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = try posix.write(self.fd, data[written..data.len]);
            if (n == 0) return error.EventWriteFailed;
            written += n;
        }
    }

    pub fn close(self: *EventWriter) void {
        if (self.fd == -1) return;
        posix.close(self.fd);
        self.fd = -1;
    }

    pub fn onThreadEnter(self: *EventWriter) void {
        if (@hasDecl(posix.F, "SETNOSIGPIPE")) {
            _ = posix.fcntl(self.fd, posix.F.SETNOSIGPIPE, 1) catch |err| {
                std.log.scoped(.NativeProcessHandler).warn("Unable to set SETNOSIGPIPE: {any}", .{err});
            };
        }

        var set: c.sigset_t = undefined;
        _ = c.sigemptyset(&set);
        _ = c.sigaddset(&set, posix.SIG.PIPE);
        _ = posix.errno(c.pthread_sigmask(c.SIG_BLOCK, &set, null));
    }

    pub fn onThreadExit() void {
        var pending: c.sigset_t = undefined;
        _ = c.sigpending(&pending);
        if (c.sigismember(&pending, posix.SIG.PIPE) != 0) {
            var wait_sigs: c.sigset_t = undefined;
            _ = c.sigemptyset(&wait_sigs);
            _ = c.sigaddset(&wait_sigs, posix.SIG.PIPE);
            var sig: c_int = undefined;
            _ = c.sigwait(&wait_sigs, &sig);
        }
    }
};

pub fn init(alloc: Allocator, initial_cols: u16, initial_rows: u16, params: ProcessParams) !Self {
    var self = Self{ .pty = try .init() };
    errdefer self.pty.deinit();
    try self.pty.resize(initial_cols, initial_rows);

    var arena_allocator = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const env = try std.process.createNullDelimitedEnvMap(arena, params.env);
    const args = try arena.allocSentinel(?[*:0]const u8, params.args.len, null);
    for (params.args, 0..) |arg, i| args[i] = arg;

    self.wake_pipe = try posix.pipe2(.{ .CLOEXEC = true });
    errdefer {
        posix.close(self.wake_pipe[0]);
        posix.close(self.wake_pipe[1]);
    }
    const flags = try posix.fcntl(self.pty.primary_fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(
        self.pty.primary_fd,
        posix.F.SETFL,
        flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
    );

    const pid = try posix.fork();
    if (pid != 0) {
        // This is the parent, child started successfully.
        self.pty.closeReplica();
        self.pid = pid;
        return self;
    }

    // This is the child.
    self.pty.setupReplica() catch |err| {
        _ = posix.write(posix.STDERR_FILENO, "Failed to set up PTY replica: ") catch 0;
        _ = posix.write(posix.STDERR_FILENO, @errorName(err)) catch 0;
        std.c._exit(1);
    };

    if (params.cwd) |cwd| posix.chdir(cwd) catch |err| {
        _ = posix.write(posix.STDERR_FILENO, "Failed to change working directory: ") catch 0;
        _ = posix.write(posix.STDERR_FILENO, @errorName(err)) catch 0;
    };

    const err = posix.execvpeZ(params.file, args, env);
    // The above never returns on success, if we're here it means we failed.
    _ = posix.write(posix.STDERR_FILENO, "Failed to start subprocess: ") catch 0;
    _ = posix.write(posix.STDERR_FILENO, @errorName(err)) catch 0;
    std.c._exit(1);
}

pub fn pidValue(self: *const Self) i64 {
    return @intCast(self.pid);
}

pub fn resize(self: *Self, cols: u16, rows: u16) !void {
    try self.pty.resize(cols, rows);
}

pub fn write(self: *Self, data: []const u8) !void {
    try self.pty.write(data);
}

pub fn drain(self: *Self, stream: anytype) !bool {
    var buf: [4096]u8 = undefined;

    var pollfds = [_]posix.pollfd{
        .{
            .fd = self.pty.primary_fd,
            .events = posix.POLL.IN,
            .revents = undefined,
        },
        .{
            .fd = self.wake_pipe[0],
            .events = posix.POLL.IN,
            .revents = undefined,
        },
    };
    _ = try posix.poll(&pollfds, -1);
    if (pollfds[1].revents != 0) return false;

    const len = posix.read(self.pty.primary_fd, buf[0..]) catch |err| switch (err) {
        error.WouldBlock => return false,
        error.NotOpenForReading, error.InputOutput => return true,
        else => return err,
    };
    if (len == 0) return true;
    stream.nextSlice(buf[0..len]);
    return false;
}

pub fn requestStop(self: *Self, _: std.Thread) void {
    if (self.wake_pipe[1] != -1) {
        _ = posix.write(self.wake_pipe[1], "X") catch 0;
    }
}

pub fn replicaName(self: *Self) []const u8 {
    return self.pty.replicaName();
}

pub fn deinitAndWait(self: *Self) u8 {
    self.pty.deinit();
    posix.close(self.wake_pipe[0]);
    posix.close(self.wake_pipe[1]);
    const result = posix.waitpid(self.pid, 0);
    return @intCast(c.WEXITSTATUS(@as(c_int, @bitCast(result.status))));
}
