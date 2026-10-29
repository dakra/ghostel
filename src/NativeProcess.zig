const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const gt = @import("ghostty-vt");

const backend_types = @import("backend_types.zig");
const emacs = @import("emacs.zig");
const GhostelHandler = @import("handler.zig").GhostelHandler;
const GhostelTerm = @import("GhostelTerm.zig");
const FixedArrayList = @import("fixed_array_list.zig").FixedArrayList;

const Backend = switch (builtin.os.tag) {
    .windows => @import("ConPtyProcess.zig"),
    else => @import("PosixPtyProcess.zig"),
};
const EventWriter = Backend.EventWriter;

const Self = @This();

const log = std.log.scoped(.NativeProcessHandler);
const cancellation_poll_interval: std.Io.Duration = .fromMilliseconds(20);
var active_readers: std.atomic.Value(usize) = .init(0);

pub const ChannelFd = EventWriter.Fd;
pub const ProcessParams = backend_types.ProcessParams;

alloc: Allocator,
io: std.Io,
// The terminal's process handle and the detached reader each own a reference.
refcount: std.atomic.Value(usize) = .init(2),

backend_handoff_mutex: std.Io.Mutex = .init,
write_mutex: std.Io.Mutex = .init,
backend: ?Backend,
event_writer: EventWriter,
pid: i64,
replica_name: [:0]u8,
// Buffer event notifications so large terminal updates can be reported with
// few writes to Emacs.
event_buf: FixedArrayList(u8, 16 * 1024) = .{},

owner: *GhostelTerm,
stream: gt.Stream(GhostelHandler(*Self)),

quit: bool = false,

const LockedStream = struct {
    process: *Self,

    pub fn nextSlice(self: *LockedStream, data: []const u8) !void {
        try self.process.owner.lock();
        defer self.process.owner.unlock();
        self.process.stream.nextSlice(data);
    }
};

pub fn init(
    self: *Self,
    alloc: Allocator,
    io: std.Io,
    size: backend_types.WinSize,
    params: ProcessParams,
    owner: *GhostelTerm,
    event_fd: ChannelFd,
) !void {
    var backend = try Backend.init(alloc, io, size, params);
    errdefer _ = backend.deinitAndWait();

    var event_writer = try EventWriter.init(event_fd);
    errdefer event_writer.close();

    var stream: @TypeOf(self.stream) = .init(.{ .allocator = alloc, .handler = .init(alloc, owner, self) });
    errdefer stream.deinit();

    const replica_name = try alloc.dupeZ(u8, backend.replicaName());
    errdefer alloc.free(replica_name);

    self.* = .{
        .alloc = alloc,
        .io = io,
        .backend = backend,
        .event_writer = event_writer,
        .pid = backend.pidValue(),
        .replica_name = replica_name,
        .owner = owner,
        .stream = stream,
    };
    owner.retain();
    errdefer owner.release();
    if (builtin.mode == .Debug) _ = active_readers.fetchAdd(1, .monotonic);
    errdefer if (builtin.mode == .Debug) {
        _ = active_readers.fetchSub(1, .release);
    };
    const thread = try std.Thread.spawn(.{}, Self.run, .{self});
    thread.detach();
}

pub fn ptyWrite(self: *Self, env: emacs.Env, data: []const u8) !void {
    while (!self.write_mutex.tryLock()) {
        try env.checkQuit();
        try std.Io.sleep(self.io, cancellation_poll_interval, std.Io.Clock.awake);
    }
    defer self.write_mutex.unlock(self.io);

    var cancellation_env = env;
    const cancellation = backend_types.CancellationToken{
        .context = &cancellation_env,
        .check_fn = checkEmacsQuit,
        .poll_interval = cancellation_poll_interval,
    };

    var offset: usize = 0;
    while (offset < data.len) {
        switch (try self.ptyWriteBackend(data[offset..], cancellation)) {
            .written => |n| {
                offset += n;
                try env.checkQuit();
            },
            .interrupted => return,
        }
    }
}

pub fn ptyWriteFromTerminal(self: *Self, data: []const u8) void {
    // This callback runs with the terminal locked. Serialize it behind
    // cancellable Emacs input, but never wait for space in the PTY input queue.
    const backend = if (self.backend) |*backend| backend else return;

    self.write_mutex.lock(self.io) catch return;
    defer self.write_mutex.unlock(self.io);

    const cancellation = backend_types.CancellationToken{
        .context = self,
        .check_fn = rejectTerminalReplyWait,
        .poll_interval = .fromMilliseconds(0),
    };

    var offset: usize = 0;
    while (offset < data.len) {
        if (@atomicLoad(bool, &self.quit, .monotonic)) return;
        const write_result = backend.write(data[offset..], cancellation) catch |err| switch (err) {
            error.TerminalReplyWouldBlock => return,
            else => {
                log.err("ghostel: Failed to write to PTY from terminal: {any}", .{err});
                return;
            },
        };
        switch (write_result) {
            .written => |n| offset += n,
            .interrupted => return,
        }
    }
}

fn rejectTerminalReplyWait(_: *const anyopaque) !void {
    return error.TerminalReplyWouldBlock;
}

fn ptyWriteBackend(
    self: *Self,
    data: []const u8,
    cancellation: ?backend_types.CancellationToken,
) !backend_types.WriteResult {
    try self.backend_handoff_mutex.lock(self.io);
    defer self.backend_handoff_mutex.unlock(self.io);

    return if (self.backend) |*backend|
        backend.write(data, cancellation)
    else
        .interrupted;
}

fn checkEmacsQuit(context: *const anyopaque) !void {
    const env: *const emacs.Env = @ptrCast(@alignCast(context));
    try env.checkQuit();
}

pub fn resizePty(self: *Self, size: backend_types.WinSize) !void {
    try self.backend_handoff_mutex.lock(self.io);
    defer self.backend_handoff_mutex.unlock(self.io);

    if (self.backend) |*backend| try backend.resize(size);
}

pub fn foregroundPgid(self: *Self) !?i32 {
    try self.backend_handoff_mutex.lock(self.io);
    defer self.backend_handoff_mutex.unlock(self.io);

    if (self.backend) |*backend| return backend.foregroundPgid();
    return null;
}

// Overflow flushing may release the terminal lock. Arguments must remain
// valid and unchanged while Emacs accesses the terminal.
pub fn effect(self: *Self, comptime func: []const u8, args: anytype) void {
    self.effectFallible(func, args) catch |err| {
        log.err("ghostel: Failed to write to event pipe: {s}", .{@errorName(err)});
    };
}

pub fn replicaName(self: *Self) [*:0]const u8 {
    return self.replica_name.ptr;
}

pub fn pidValue(self: *Self) i64 {
    return self.pid;
}

fn effectFallible(self: *Self, comptime func: []const u8, args: anytype) !void {
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
    self.event_writer.onThreadEnter();
    defer EventWriter.onThreadExit();

    self.loop() catch |err| {
        log.warn("ghostel: error in read loop: {any}", .{err});
    };

    var backend = self.retireBackend() orelse unreachable;

    var final_stream = LockedStream{ .process = self };
    backend.finishDrain(&final_stream) catch |err| {
        log.warn("ghostel: error finishing read loop: {any}", .{err});
    };
    self.notifyVtUpdate() catch |err| {
        log.warn("ghostel: error notifying final terminal update: {any}", .{err});
    };

    // No parser callback can use the terminal after stream destruction. Drop
    // its reader reference before waiting for a potentially SIGHUP-ignoring
    // child, so only the backend and event channel need to outlive the buffer.
    self.owner.mutex.lockUncancelable(self.io);
    self.stream.deinit();
    self.owner.unlock();
    self.owner.release();
    const event_writer = self.event_writer;
    self.release();
    if (builtin.mode == .Debug) _ = active_readers.fetchSub(1, .release);

    // This detached thread now reaps the child itself. Keep the channel open
    // until actual child exit, and send the status after all terminal events.
    finishEventChannel(event_writer, backend.deinitAndWait());
}

fn loop(self: *Self) !void {
    while (try self.loopOnce()) {}
}

fn loopOnce(self: *Self) !bool {
    if (@atomicLoad(bool, &self.quit, .monotonic)) return false;

    // The reader thread exclusively owns backend retirement, so self.backend is
    // stable here without the handoff mutex.
    if (self.backend) |*backend| {
        var stream = LockedStream{ .process = self };
        const keep_going = try backend.drain(&stream);
        try self.notifyVtUpdate();
        return keep_going;
    }

    return false;
}

fn retireBackend(self: *Self) ?Backend {
    self.backend_handoff_mutex.lockUncancelable(self.io);
    defer self.backend_handoff_mutex.unlock(self.io);

    const backend = self.backend orelse return null;
    self.backend = null;
    return backend;
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
            // Only effects can overflow this buffer, under LockedStream's
            // single terminal lock. notifyVtUpdate writes "()" into an empty
            // buffer. Emacs may need the terminal lock to drain the pipe.
            std.debug.assert(self.owner.mutex.lock_count == 1);
            self.owner.unlock();
            defer self.owner.mutex.lockUncancelable(self.io);
            try self.flushEvents();
            continue;
        }

        const n = @min(data.len - written, space);
        try self.event_buf.appendSlice(data[written..(written + n)]);
        written += n;
    }
}

fn flushEvents(self: *Self) !void {
    try self.event_writer.write(self.event_buf.items());
    self.event_buf.resize(0);
}

fn finishEventChannel(event_writer: EventWriter, exit_code: u32) void {
    var writer = event_writer;

    // A bare number is not a terminal callback; the Elisp event filter treats
    // it as the child's exit status and deletes the pipe process to run its
    // sentinel. Closing the fd after the write releases Emacs' pipe.
    var exit_code_buf: [11]u8 = undefined;
    const str = std.fmt.bufPrint(&exit_code_buf, "{}\n", .{exit_code}) catch unreachable;
    writer.write(str) catch |err| {
        log.warn("ghostel: Failed to write native child exit event: {any}", .{err});
    };
    writer.close();
}

pub fn requestStop(self: *Self) void {
    @atomicStore(bool, &self.quit, true, .monotonic);

    self.backend_handoff_mutex.lockUncancelable(self.io);
    defer self.backend_handoff_mutex.unlock(self.io);
    if (self.backend) |*backend| backend.requestStop();
}

/// Debug shutdown only: release Emacs references before waiting for reader
/// allocations to be freed. This does not wait for child exit.
pub fn waitForReaders() void {
    while (active_readers.load(.acquire) != 0) std.Thread.yield() catch {};
}

pub fn release(self: *Self) void {
    if (self.refcount.fetchSub(1, .acq_rel) != 1) return;
    self.alloc.free(self.replica_name);
    self.alloc.destroy(self);
}
