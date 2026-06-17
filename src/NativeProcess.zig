const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const c = @cImport({
    @cInclude("signal.h");
    @cInclude("fcntl.h");
});

const gt = @import("ghostty-vt");

const PtyProcess = @import("PtyProcess.zig");
const GhostelHandler = @import("handler.zig").GhostelHandler;
const FixedArrayList = @import("fixed_array_list.zig").FixedArrayList;

const Self = @This();

const log = std.log.scoped(.NativeProcessHandler);

process: PtyProcess,
event_pipe: posix.fd_t = -1,
// Buffer event notifications so large terminal updates can be reported with
// few writes to Emacs.
event_buf: FixedArrayList(u8, 16 * 1024) = .{},

term_mutex: std.Thread.Mutex = .{},
term: *gt.Terminal,
stream: gt.Stream(GhostelHandler(*Self)),

quit_pipe: [2]posix.fd_t = .{ -1, -1 },
thread: std.Thread,

pub fn init(
    self: *Self,
    alloc: Allocator,
    process: PtyProcess,
    term: *gt.Terminal,
    event_pipe: posix.fd_t,
) !void {
    const pipe = try posix.pipe();
    errdefer {
        posix.close(pipe[0]);
        posix.close(pipe[1]);
    }

    self.* = .{
        .process = process,
        .event_pipe = event_pipe,
        .term = term,
        .stream = .initAlloc(alloc, .init(self, term)),
        .quit_pipe = pipe,
        .thread = try std.Thread.spawn(.{}, Self.run, .{self}),
    };
}

pub fn lockTerm(self: *Self) void {
    self.term_mutex.lock();
}

pub fn unlockTerm(self: *Self) void {
    self.term_mutex.unlock();
}

pub fn ptyWrite(self: *Self, data: []const u8) !void {
    return self.process.pty.write(data);
}

pub fn funcall(self: *Self, comptime func: []const u8, args: anytype) void {
    self.funcallFallible(func, args) catch |err| {
        log.err("Failed to write to event pipe: {s}", .{@errorName(err)});
    };
}

pub fn replicaName(self: *Self) []const u8 {
    return self.process.pty.replicaName();
}

fn funcallFallible(self: *Self, comptime func: []const u8, args: anytype) !void {
    try self.writeEvent("(");
    try self.writeEvent(func);
    inline for (std.meta.fields(@TypeOf(args))) |field| {
        try self.writeEvent(" ");
        try self.writeEventLispValue(@field(args, field.name));
    }
    try self.writeEvent(")");
}

fn writeEventLispValue(self: *Self, val: anytype) !void {
    const T = @TypeOf(val);
    const ty = @typeInfo(T);
    switch (ty) {
        .pointer => try self.writeEventLispString(val),
        .optional => if (val) |v| try self.writeEventLispValue(v) else try self.writeEvent("nil"),
        .int => try self.writeEventLispNumber(val),
        else => @compileError(std.fmt.comptimePrint("Non-supported type: {}", .{T})),
    }
}

fn writeEventLispNumber(self: *Self, val: anytype) !void {
    var buf: [1024]u8 = undefined;
    const str = try std.fmt.bufPrintZ(&buf, "{}", .{val});
    try self.writeEvent(str);
}

fn writeEventLispString(self: *Self, str: []const u8) !void {
    try self.writeEvent("\"");
    for (str) |ch| {
        switch (ch) {
            '\\' => try self.writeEvent("\\\\"),
            '\n' => try self.writeEvent("\\n"),
            '"' => try self.writeEvent("\\\""),
            else => try self.writeEvent(&[_]u8{ch}),
        }
    }
    try self.writeEvent("\"");
}

fn run(self: *Self) void {
    self.blockSigpipe();
    defer drainSigpipe();

    self.loop() catch |err| {
        log.warn("ghostel: error in read loop: {any}", .{err});
    };

    _ = self.process.deinitAndWait();

    self.writeEvent("(delete-process ghostel--event-pipe)") catch {};
    self.flushEvents() catch {};
    posix.close(self.event_pipe);
}

fn blockSigpipe(self: *Self) void {
    // On macOS and platforms that have it, set F_SETNOSIGPIPE
    if (@hasDecl(posix.F, "SETNOSIGPIPE")) {
        _ = posix.fcntl(self.event_pipe, posix.F.SETNOSIGPIPE, 1) catch |err| {
            log.warn("Unable to set SETNOSIGPIPE: {any}", .{err});
        };
    }
    // Linux doesn't have F_SETNOSIGPIPE so mask the SIGPIPE
    // and drain it at the end.
    var set: c.sigset_t = undefined;
    _ = c.sigemptyset(&set);
    _ = c.sigaddset(&set, posix.SIG.PIPE);
    _ = posix.errno(c.pthread_sigmask(c.SIG_BLOCK, &set, null));
}

fn drainSigpipe() void {
    // On Linux, clear any SIGPIPE that is pending. This doesn't work on macOS
    // but on macOS we have F_SETNOSIGPIPE instead and the code below is noop.
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

fn loop(self: *Self) !void {
    const fd = self.process.pty.primary_fd;
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(
        fd,
        posix.F.SETFL,
        flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
    );

    while (try self.loopOnce()) {}
}

fn loopOnce(self: *Self) !bool {
    var pollfds = [_]posix.pollfd{
        .{
            .fd = self.process.pty.primary_fd,
            .events = posix.POLL.IN,
            .revents = undefined,
        },
        .{
            .fd = self.quit_pipe[0],
            .events = posix.POLL.IN,
            .revents = undefined,
        },
    };

    var buf: [1024]u8 = undefined;
    _ = try posix.poll(&pollfds, -1);

    while (true) {
        const len = posix.read(self.process.pty.primary_fd, &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            error.NotOpenForReading, error.InputOutput => return false,
            else => return err,
        };

        if (len == 0) break;

        {
            self.term_mutex.lock();
            defer self.term_mutex.unlock();

            self.stream.nextSlice(buf[0..len]);
        }
    }

    if (pollfds[0].revents & posix.POLL.HUP != 0 or
        pollfds[1].revents & posix.POLL.IN != 0)
    {
        return false;
    }

    try self.notifyVtUpdate();
    return true;
}

fn notifyVtUpdate(self: *Self) !void {
    if (self.event_buf.len == 0) try self.writeEvent("()");
    try self.flushEvents();
}

fn writeEvent(self: *Self, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const space = self.event_buf.unusedCapacity();
        if (space == 0) {
            try self.flushEvents();
            continue;
        }

        const n = @min(data.len - written, space);
        try self.event_buf.appendSlice(data[written..(written + n)]);
        written += n;
    }
}

fn flushEvents(self: *Self) !void {
    var written: usize = 0;
    while (written < self.event_buf.len) {
        written += try posix.write(
            self.event_pipe,
            self.event_buf.items()[written..self.event_buf.len],
        );
    }
    self.event_buf.resize(0);
}

pub fn deinit(self: *Self) void {
    _ = posix.write(self.quit_pipe[1], "X") catch {};
    self.thread.join();
    self.stream.deinit();
    posix.close(self.quit_pipe[1]);
    posix.close(self.quit_pipe[0]);
}
