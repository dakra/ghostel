const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = std.posix.system;

const backend_types = @import("backend_types.zig");
const RefCount = @import("RefCount.zig").RefCount;
const c = @import("posix_c");

const Self = @This();
const WRITE_CHUNK_SIZE = 4096;

const log = std.log.scoped(.NativeProcessHandler);

const Pty = struct {
    primary_fd: c_int = -1,
    replica_fd: c_int = -1,
    replica_name: [1024:0]u8 = undefined,

    pub fn init() !Pty {
        var self: @This() = .{};
        self.primary_fd = c.posix_openpt(c.O_RDWR | c.O_NOCTTY | c.O_CLOEXEC);
        if (sys.errno(self.primary_fd) != .SUCCESS) {
            return error.OpenPtFailed;
        }
        errdefer _ = sys.close(self.primary_fd);

        if (sys.errno(c.grantpt(self.primary_fd)) != .SUCCESS) {
            return error.GrantPtFailed;
        }

        if (sys.errno(c.unlockpt(self.primary_fd)) != .SUCCESS) {
            return error.UnlockPtFailed;
        }

        const ptsname_err = sys.errno(c.ptsname_r(
            self.primary_fd,
            &self.replica_name,
            self.replica_name.len,
        ));
        if (ptsname_err != .SUCCESS) {
            return error.PtsNameFailed;
        }

        self.replica_fd = sys.open(&self.replica_name, .{ .ACCMODE = .RDWR, .NOCTTY = true });
        if (sys.errno(self.replica_fd) != .SUCCESS) return error.OpenReplicaFailed;
        errdefer _ = sys.close(self.replica_fd);

        // Configure the line discipline on the replica. On macOS/BSD the
        // master (ptm) fd rejects termios ioctls with ENOTTY; only the
        // replica carries the terminal attributes, so this must run on
        // `replica_fd', not `primary_fd'.
        var attrs: c.termios = undefined;
        if (c.tcgetattr(self.replica_fd, &attrs) != 0) return error.TcgetattrFailed;

        // Enable UTF-8 mode so backspace erases multi-byte characters.
        attrs.c_iflag |= c.IUTF8;
        // Disable XON/XOFF flow control so C-q (DC1) and C-s (DC3) pass
        // through to the application instead of being swallowed by the
        // line discipline. Ghostel's send-next-key escape hatch and the
        // direct C-q binding rely on these bytes reaching the child.
        attrs.c_iflag &= ~@as(@TypeOf(attrs.c_iflag), c.IXON);
        if (c.tcsetattr(self.replica_fd, c.TCSANOW, &attrs) != 0) return error.TcsetattrFailed;

        return self;
    }

    pub fn resize(self: *@This(), ws: backend_types.WinSize) !void {
        const size = c.winsize{
            .ws_col = ws.cols,
            .ws_row = ws.rows,
            .ws_xpixel = ws.xpixel,
            .ws_ypixel = ws.ypixel,
        };
        switch (sys.errno(c.ioctl(self.primary_fd, c.TIOCSWINSZ, &size))) {
            .SUCCESS, .IO, .NXIO => {},
            else => return error.PtyResizeFailed,
        }
    }

    pub fn closePrimary(self: *@This()) void {
        if (self.primary_fd != -1) {
            _ = sys.close(self.primary_fd);
            self.primary_fd = -1;
        }
    }

    /// Foreground process-group id of the PTY, or null when the query fails
    /// or there is no foreground group.  `TIOCGPGRP` must run on the primary:
    /// a separately opened replica fd is not the caller's controlling terminal,
    /// so the kernel rejects the ioctl there with ENOTTY.
    pub fn foregroundPgid(self: *@This()) ?i32 {
        if (self.primary_fd == -1) return null;
        var pgid: c.pid_t = undefined;
        if (sys.errno(c.ioctl(self.primary_fd, c.TIOCGPGRP, &pgid)) != .SUCCESS) return null;
        if (pgid <= 0) return null;
        return @intCast(pgid);
    }

    pub fn closeReplica(self: *@This()) void {
        if (self.replica_fd != -1) {
            _ = sys.close(self.replica_fd);
            self.replica_fd = -1;
        }
    }

    pub fn replicaName(self: *@This()) []const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(&self.replica_name)));
    }

    pub fn setupReplica(self: *@This()) !void {
        if (sys.errno(sys.setsid()) != .SUCCESS) return error.SetSidFailed;
        if (sys.errno(c.ioctl(self.replica_fd, c.TIOCSCTTY)) != .SUCCESS) return error.CttyFailed;

        if (sys.errno(sys.dup2(self.replica_fd, sys.STDIN_FILENO)) != .SUCCESS) {
            return error.ReplicaFdSetupFailed;
        }
        if (sys.errno(sys.dup2(self.replica_fd, sys.STDOUT_FILENO)) != .SUCCESS) {
            return error.ReplicaFdSetupFailed;
        }
        if (sys.errno(sys.dup2(self.replica_fd, sys.STDERR_FILENO)) != .SUCCESS) {
            return error.ReplicaFdSetupFailed;
        }
    }

    pub fn deinit(self: *@This()) void {
        self.closePrimary();
        self.closeReplica();
    }
};

alloc: Allocator,
pty: Pty,
wake_pipe: [2]sys.fd_t = .{ -1, -1 },
waiter: *Waiter,

// The backend moves during initialization and retirement. Keep the waiter's
// shared state at a stable address until deinitAndWait joins its thread.
const Waiter = struct {
    child: *ChildProcess,
    thread: std.Thread = undefined,
    exited: std.atomic.Value(bool) = .init(false),
    exit_code: u32 = undefined,

    fn start(self: *Waiter, wake_fd: sys.fd_t) !void {
        self.thread = std.Thread.spawn(.{}, run, .{ self, wake_fd }) catch |err| {
            // No waiter owns the child yet. Do not leak it if thread creation
            // fails, including children that ignore terminal hangup.
            self.child.terminate() catch |kill_err| {
                log.err("Failed to terminate child after thread creation failed: {any}", .{kill_err});
            };
            _ = self.child.wait() catch |wait_err| blk: {
                log.err("Failed to wait for child after thread creation failed: {any}", .{wait_err});
                break :blk 255;
            };
            return err;
        };
    }

    fn hasExited(self: *const Waiter) bool {
        return self.exited.load(.acquire);
    }

    fn wait(self: *Waiter) u32 {
        self.thread.join();
        return self.exit_code;
    }

    fn run(self: *Waiter, wake_fd: sys.fd_t) void {
        self.exit_code = self.child.wait() catch |err| blk: {
            log.err("Failed to wait for native child: {any}", .{err});
            break :blk 255;
        };
        self.exited.store(true, .release);
        _ = writeWithRetry(wake_fd, "X");
    }
};

/// Reference-counted child identity with serialized termination and reaping.
/// The child must not be reaped outside this control.
pub const ChildProcess = struct {
    const Child = @This();
    pub const Handle = sys.pid_t;

    alloc: Allocator,
    io: std.Io,
    refcount: RefCount(Child) = .init(1),
    handle: Handle,
    mutex: std.Io.Mutex = .init,
    exited: bool = false,

    pub fn destroy(self: *Child) void {
        self.alloc.destroy(self);
    }

    pub fn pidValue(self: *const Child) i64 {
        return @intCast(self.handle);
    }

    /// Send SIGKILL without waiting. No-op after reaping.
    pub fn terminate(self: *Child) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.exited) return;

        std.debug.assert(self.handle > 0);
        switch (sys.errno(sys.kill(self.handle, .KILL))) {
            // The unreaped child reserves its PID, so ESRCH means it is already gone.
            .SUCCESS, .SRCH => {},
            else => return error.ChildTerminationFailed,
        }
    }

    /// Wait for exit, reap the child, and return its status (128+N for signal N).
    /// Must be called exactly once. May run concurrently with terminate.
    pub fn wait(self: *Child) !u32 {
        // WNOWAIT prevents reaping, not blocking: observeExit waits for exit
        // without holding the mutex needed to terminate a live child. Keep its
        // error pending until termination is disabled under that mutex too.
        const observed = self.observeExit();

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // No subsequent terminate call may use the PID, even if another reaper
        // unexpectedly consumed the child and waitid reported ECHILD.
        self.exited = true;
        try observed;

        // The exited, unreaped child reserves its PID until this consuming wait.
        // Both the state transition and reaping are serialized with terminate.
        while (true) {
            var status: c_int = undefined;
            switch (sys.errno(sys.waitpid(self.handle, &status, 0))) {
                .SUCCESS => {
                    if (c.WIFEXITED(status)) return @intCast(c.WEXITSTATUS(status));
                    if (c.WIFSIGNALED(status)) return @intCast(128 + c.WTERMSIG(status));
                },
                .INTR => continue,
                else => return error.ChildWaitFailed,
            }
        }
    }

    fn observeExit(self: *Child) !void {
        std.debug.assert(self.handle > 0);
        var info: c.siginfo_t = undefined;
        while (true) {
            switch (sys.errno(c.waitid(c.P_PID, @intCast(self.handle), &info, c.WEXITED | c.WNOWAIT))) {
                .SUCCESS => return,
                .INTR => continue,
                else => |err| {
                    std.log.err("waitid for child {} failed: {any}", .{ self.handle, err });
                    return error.ChildWaitFailed;
                },
            }
        }
    }
};

pub const EventWriter = struct {
    pub const Fd = sys.fd_t;

    fd: Fd,

    pub fn init(fd: Fd) !EventWriter {
        return .{ .fd = fd };
    }

    pub fn write(self: *EventWriter, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = writeWithRetry(self.fd, data[written..data.len]);
            if (n <= 0) return error.EventWriteFailed;
            written += @intCast(n);
        }
    }

    pub fn close(self: *EventWriter) void {
        if (self.fd == -1) return;
        _ = sys.close(self.fd);
        self.fd = -1;
    }

    pub fn onThreadEnter(self: *EventWriter) void {
        if (@hasDecl(sys.F, "SETNOSIGPIPE")) {
            _ = fcntl(self.fd, sys.F.SETNOSIGPIPE, 1) catch |err| {
                log.warn("Unable to set SETNOSIGPIPE: {any}", .{err});
            };
        }

        var set: c.sigset_t = undefined;
        _ = c.sigemptyset(&set);
        _ = c.sigaddset(&set, c.SIGPIPE);
        _ = sys.errno(c.pthread_sigmask(c.SIG_BLOCK, &set, null));
    }

    pub fn onThreadExit() void {
        var pending: c.sigset_t = undefined;
        _ = c.sigpending(&pending);
        if (c.sigismember(&pending, c.SIGPIPE) != 0) {
            var wait_sigs: c.sigset_t = undefined;
            _ = c.sigemptyset(&wait_sigs);
            _ = c.sigaddset(&wait_sigs, c.SIGPIPE);
            var sig: c_int = undefined;
            _ = c.sigwait(&wait_sigs, &sig);
        }
    }
};

fn fcntl(fd: sys.fd_t, cmd: c_int, arg: c_int) !c_int {
    const result = sys.fcntl(fd, cmd, arg);
    return if (sys.errno(result) == .SUCCESS) result else error.FcntlFailed;
}

fn writeWithRetry(fd: sys.fd_t, data: []const u8) isize {
    while (true) {
        const written = sys.write(fd, data.ptr, data.len);
        if (sys.errno(written) != .INTR) return written;
    }
}

fn pollWithRetry(pollfds: []sys.pollfd, timeout: c_int) c_int {
    while (true) {
        const result = sys.poll(pollfds.ptr, @intCast(pollfds.len), timeout);
        if (sys.errno(result) != .INTR) return result;
    }
}

fn failChild(msg: []const u8, err: []const u8) noreturn {
    _ = sys.write(sys.STDERR_FILENO, msg.ptr, msg.len);
    _ = sys.write(sys.STDERR_FILENO, ": ", 2);
    _ = sys.write(sys.STDERR_FILENO, err.ptr, err.len);
    std.c._exit(1);
}

pub fn init(alloc: Allocator, io: std.Io, size: backend_types.WinSize, params: backend_types.ProcessParams) !Self {
    const waiter = try alloc.create(Waiter);
    errdefer alloc.destroy(waiter);
    const child = try alloc.create(ChildProcess);
    errdefer alloc.destroy(child);

    var self = Self{ .alloc = alloc, .pty = try .init(), .waiter = waiter };
    errdefer self.pty.deinit();
    try self.pty.resize(size);

    var arena_allocator = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const env = try params.env.createPosixBlock(arena, .{});
    const args = try arena.allocSentinel(?[*:0]const u8, params.args.len, null);
    for (params.args, 0..) |arg, i| args[i] = arg;

    if (sys.errno(sys.pipe(&self.wake_pipe)) != .SUCCESS) {
        return error.PipeCreationFailed;
    }
    errdefer {
        _ = sys.close(self.wake_pipe[0]);
        _ = sys.close(self.wake_pipe[1]);
    }

    // This is racy but benign. pipe2 would be better but doesn't exist on macOS.
    for (self.wake_pipe) |fd| {
        _ = try fcntl(fd, sys.F.SETFD, sys.FD_CLOEXEC);
    }

    const flags = try fcntl(self.pty.primary_fd, sys.F.GETFL, 0);
    _ = try fcntl(
        self.pty.primary_fd,
        sys.F.SETFL,
        flags | @as(u32, @bitCast(sys.O{ .NONBLOCK = true })),
    );

    const pid = sys.fork();
    if (sys.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid != 0) {
        // This is the parent, child started successfully.
        self.pty.closeReplica();
        child.* = .{ .alloc = alloc, .io = io, .handle = pid };
        waiter.* = .{ .child = child };
        try waiter.start(self.wake_pipe[1]);
        return self;
    }

    // This is the child.
    self.pty.setupReplica() catch |err| {
        failChild("Failed to set up PTY replica", @errorName(err));
    };

    if (params.cwd) |cwd| {
        const result = sys.errno(sys.chdir(cwd));
        if (result != .SUCCESS) {
            failChild("Failed to change working directory", @tagName(result));
        }
    }

    const err = sys.execve(params.file, args, env.slice);

    // The above never returns on success, if we're here it means we failed.
    failChild("Failed to start subprocess", @tagName(sys.errno(err)));
}

pub fn childHandle(self: *const Self) *ChildProcess {
    return self.waiter.child;
}

pub fn resize(self: *Self, size: backend_types.WinSize) !void {
    try self.pty.resize(size);
}

pub fn foregroundPgid(self: *Self) ?i32 {
    return self.pty.foregroundPgid();
}

pub fn write(
    self: *Self,
    data: []const u8,
    cancellation: ?backend_types.CancellationToken,
) !backend_types.WriteResult {
    if (data.len == 0) return .{ .written = 0 };

    const chunk = data[0..@min(data.len, WRITE_CHUNK_SIZE)];
    while (true) {
        const written = writeWithRetry(self.pty.primary_fd, chunk);
        if (written == 0) return error.IoFailed;
        switch (sys.errno(written)) {
            .SUCCESS => return .{ .written = @intCast(written) },

            .PIPE, .IO, .SRCH, .NXIO => return .interrupted,

            .AGAIN => {
                var pollfds = [_]sys.pollfd{
                    .{
                        .fd = self.pty.primary_fd,
                        .events = sys.POLL.OUT,
                        .revents = undefined,
                    },
                    .{
                        .fd = self.wake_pipe[0],
                        .events = sys.POLL.IN,
                        .revents = undefined,
                    },
                };
                const timeout: i32 = if (cancellation) |token|
                    @intCast(@min(
                        token.poll_interval.toMilliseconds(),
                        @as(u32, @intCast(std.math.maxInt(i32))),
                    ))
                else
                    -1;
                const ready = pollWithRetry(&pollfds, timeout);
                if (sys.errno(ready) != .SUCCESS) return error.IoFailed;
                if (ready == 0) {
                    try cancellation.?.check();
                    continue;
                }
                if (pollfds[1].revents != 0) return .interrupted;
                continue;
            },

            else => return error.IoFailed,
        }
    }
}

pub fn drain(self: *Self, stream: anytype) !bool {
    var buf: [4096]u8 = undefined;

    var pollfds = [_]sys.pollfd{
        .{
            .fd = self.pty.primary_fd,
            .events = sys.POLL.IN,
            .revents = undefined,
        },
        .{
            .fd = self.wake_pipe[0],
            .events = sys.POLL.IN,
            .revents = undefined,
        },
    };
    if (sys.errno(pollWithRetry(&pollfds, -1)) != .SUCCESS) {
        return error.PollFailed;
    }
    const exited = self.waiter.hasExited();
    const wake_requested = pollfds[1].revents != 0;
    const pty_hung_up = pollfds[0].revents & sys.POLL.HUP != 0;
    if (wake_requested and !exited) return false;

    // Child exit is independent of PTY hangup: background jobs can keep the
    // replica open. Keep reading until EAGAIN, EOF, or an error before stopping
    // on child exit; the buffer size only limits each individual read.
    const eof = exited or pty_hung_up;
    while (true) {
        const len = sys.read(self.pty.primary_fd, &buf, buf.len);
        if (len == 0) return !eof;
        switch (sys.errno(len)) {
            .SUCCESS => try stream.nextSlice(buf[0..@intCast(len)]),
            .INTR => continue,
            .AGAIN => return !eof,
            .BADF, .IO => return false,
            else => return error.ReadFailed,
        }
    }
}

pub fn finishDrain(_: *Self, _: anytype) !void {}

pub fn requestStop(self: *Self) void {
    if (self.wake_pipe[1] != -1) {
        _ = writeWithRetry(self.wake_pipe[1], "X");
    }
}

pub fn replicaName(self: *Self) []const u8 {
    return self.pty.replicaName();
}

pub fn deinitAndWait(self: *Self) u32 {
    self.pty.deinit();
    // PTY closure can precede child exit. Keep the state and wake pipe alive
    // until the waiter has published the status and finished its wakeup write.
    const exit_code = self.waiter.wait();
    self.waiter.child.refcount.release();
    self.alloc.destroy(self.waiter);
    _ = sys.close(self.wake_pipe[0]);
    _ = sys.close(self.wake_pipe[1]);
    return exit_code;
}

test "child exit wakeup drains queued output without waiting for hangup" {
    const testing = std.testing;
    var output_pipe: [2]sys.fd_t = undefined;
    try testing.expectEqual(sys.E.SUCCESS, sys.errno(sys.pipe(&output_pipe)));
    defer for (output_pipe) |fd| {
        _ = sys.close(fd);
    };
    _ = try fcntl(output_pipe[0], sys.F.SETFL, @as(u32, @bitCast(sys.O{ .NONBLOCK = true })));

    var wake_pipe: [2]sys.fd_t = undefined;
    try testing.expectEqual(sys.E.SUCCESS, sys.errno(sys.pipe(&wake_pipe)));
    defer for (wake_pipe) |fd| {
        _ = sys.close(fd);
    };

    var waiter: Waiter = .{ .child = undefined };
    var backend: Self = .{
        .alloc = testing.allocator,
        .pty = .{ .primary_fd = output_pipe[0] },
        .wake_pipe = wake_pipe,
        .waiter = &waiter,
    };
    var stream: struct {
        data: std.ArrayList(u8) = .empty,

        pub fn nextSlice(self: *@This(), bytes: []const u8) !void {
            try self.data.appendSlice(testing.allocator, bytes);
        }
    } = .{};
    defer stream.data.deinit(testing.allocator);

    const output = "final stdout and stderr";
    try testing.expectEqual(@as(isize, output.len), writeWithRetry(output_pipe[1], output));
    waiter.exited.store(true, .release);
    backend.requestStop();

    // Keep the output writer open: only the exit wakeup can terminate drain.
    try testing.expect(!try backend.drain(&stream));
    try testing.expectEqualStrings(output, stream.data.items);
}

const TestChild = struct {
    child: *ChildProcess,
    release_fd: sys.fd_t,
    waited: bool = false,

    fn init(exit_code: u8) !@This() {
        var pipe: [2]sys.fd_t = undefined;
        if (sys.errno(sys.pipe(&pipe)) != .SUCCESS) return error.PipeCreationFailed;
        errdefer for (pipe) |fd| {
            _ = sys.close(fd);
        };
        const child = try std.testing.allocator.create(ChildProcess);
        errdefer std.testing.allocator.destroy(child);

        const pid = sys.fork();
        if (sys.errno(pid) != .SUCCESS) return error.ForkFailed;
        if (pid == 0) {
            _ = sys.close(pipe[1]);
            var byte: [1]u8 = undefined;
            while (sys.errno(sys.read(pipe[0], &byte, 1)) == .INTR) {}
            std.c._exit(exit_code);
        }
        child.* = .{ .alloc = std.testing.allocator, .io = std.testing.io, .handle = pid };
        _ = sys.close(pipe[0]);
        return .{ .child = child, .release_fd = pipe[1] };
    }

    fn allowExit(self: *@This()) void {
        _ = sys.close(self.release_fd);
        self.release_fd = -1;
    }

    fn wait(self: *@This()) !u32 {
        const status = try self.child.wait();
        self.waited = true;
        return status;
    }

    fn deinit(self: *@This()) void {
        if (!self.waited) {
            self.child.terminate() catch |err| std.log.err("test child termination failed: {any}", .{err});
            _ = self.wait() catch |err| blk: {
                std.log.err("test child wait failed: {any}", .{err});
                break :blk 255;
            };
        }
        if (self.release_fd != -1) _ = sys.close(self.release_fd);
        self.child.refcount.release();
    }
};

test "observing exit leaves the child waitable until serialized reaping" {
    var child = try TestChild.init(23);
    defer child.deinit();
    child.allowExit();
    try child.child.observeExit();

    // A consuming wait in observeExit would make this fail with ECHILD.
    var info: c.siginfo_t = undefined;
    try std.testing.expectEqual(sys.E.SUCCESS, sys.errno(c.waitid(
        c.P_PID,
        @intCast(child.child.handle),
        &info,
        c.WEXITED | c.WNOWAIT,
    )));
    try child.child.terminate();
    try std.testing.expectEqual(@as(u32, 23), try child.wait());
}

test "termination after reaping cannot target a replacement PID" {
    var original = try TestChild.init(23);
    defer original.deinit();
    original.allowExit();
    try std.testing.expectEqual(@as(u32, 23), try original.wait());

    var replacement = try TestChild.init(77);
    defer replacement.deinit();
    // Model PID reuse deterministically with a second child, not kernel PID
    // churn. Any kill through the old control must leave this child alone.
    original.child.handle = replacement.child.handle;
    try original.child.terminate();
    replacement.allowExit();
    try std.testing.expectEqual(@as(u32, 77), try replacement.wait());
}

test "termination before reaping reports the child's signal status" {
    var child = try TestChild.init(23);
    defer child.deinit();
    try child.child.terminate();
    try std.testing.expectEqual(@as(u32, 137), try child.wait());
}

test "native spawn releases allocations on allocation failure" {
    const Exercise = struct {
        fn spawn(alloc: Allocator) !void {
            var env: std.process.Environ.Map = .init(alloc);
            defer env.deinit();
            var args = [_][:0]const u8{ "/bin/sh", "-c", "exit 0" };
            var backend = try Self.init(alloc, std.testing.io, .{ .rows = 24, .cols = 80 }, .{
                .file = args[0],
                .args = &args,
                .env = &env,
            });
            _ = backend.deinitAndWait();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Exercise.spawn, .{});
}
