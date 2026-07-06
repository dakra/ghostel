const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const gt = @import("ghostty-vt");

const GhostelHandler = @import("handler.zig").GhostelHandler;
const FixedArrayList = @import("fixed_array_list.zig").FixedArrayList;

const Backend = switch (builtin.os.tag) {
    .windows => @import("ConPtyProcess.zig"),
    else => @import("PosixPtyProcess.zig"),
};
const EventWriter = Backend.EventWriter;

const Self = @This();

const log = std.log.scoped(.NativeProcessHandler);
pub const ChannelFd = EventWriter.Fd;
pub const ProcessParams = Backend.ProcessParams;

backend_mutex: std.Thread.Mutex = .{},
backend: ?Backend,
event_writer: EventWriter,
alloc: Allocator,
pid: i64,
replica_name: []u8,
// Buffer event notifications so large terminal updates can be reported with
// few writes to Emacs.
event_buf: FixedArrayList(u8, 16 * 1024) = .{},

term_mutex: std.Thread.Mutex.Recursive = .init,
term: *gt.Terminal,
stream: gt.Stream(GhostelHandler(*Self)),

quit: bool = false,
thread: std.Thread,

const LockedStream = struct {
    process: *Self,
    drained: bool = false,

    pub fn nextSlice(self: *LockedStream, data: []const u8) void {
        self.process.term_mutex.lock();
        defer self.process.term_mutex.unlock();
        self.drained = true;
        self.process.stream.nextSlice(data);
    }
};

pub fn init(
    self: *Self,
    alloc: Allocator,
    initial_cols: u16,
    initial_rows: u16,
    params: ProcessParams,
    term: *gt.Terminal,
    event_fd: ChannelFd,
) !void {
    var backend = try Backend.init(alloc, initial_cols, initial_rows, params);
    errdefer _ = backend.deinitAndWait();

    var event_writer = try EventWriter.init(event_fd);
    errdefer event_writer.close();

    var stream: @TypeOf(self.stream) = .initAlloc(alloc, .init(self, term));
    errdefer stream.deinit();

    const replica_name = try alloc.dupe(u8, backend.replicaName());
    errdefer alloc.free(replica_name);

    self.* = .{
        .backend = backend,
        .event_writer = event_writer,
        .alloc = alloc,
        .pid = backend.pidValue(),
        .replica_name = replica_name,
        .term = term,
        .stream = stream,
        .thread = undefined,
    };
    self.thread = try std.Thread.spawn(.{}, Self.run, .{self});
}

pub fn lockTerm(self: *Self) void {
    self.term_mutex.lock();
}

pub fn unlockTerm(self: *Self) void {
    self.term_mutex.unlock();
}

pub fn ptyWrite(self: *Self, data: []const u8) !void {
    self.backend_mutex.lock();
    defer self.backend_mutex.unlock();

    if (self.backend) |*backend| return backend.write(data);
    return error.ProcessExited;
}

pub fn resizePty(self: *Self, cols: u16, rows: u16) !void {
    self.backend_mutex.lock();
    defer self.backend_mutex.unlock();

    if (self.backend) |*backend| try backend.resize(cols, rows);
}

pub fn isBackendAlive(self: *Self) bool {
    self.backend_mutex.lock();
    defer self.backend_mutex.unlock();

    return self.backend != null;
}

pub fn effect(self: *Self, comptime func: []const u8, args: anytype) void {
    self.effectFallible(func, args) catch |err| {
        log.err("Failed to write to event pipe: {s}", .{@errorName(err)});
    };
}

pub fn replicaName(self: *Self) []const u8 {
    return self.replica_name;
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
    const backend = blk: {
        self.backend_mutex.lock();
        defer self.backend_mutex.unlock();

        const backend = self.backend orelse return;
        self.backend = null;
        break :blk backend;
    };

    // The reader thread must not waitpid here: it may be joined from Emacs
    // during buffer teardown, and blocking that path would freeze Emacs.  Hand
    // the child and event writer to a detached reaper instead. The channel stays
    // open until the reaper observes child exit, mirroring Emacs process
    // lifetime semantics for the Lisp-side pipe process.
    const reaper_thread = std.Thread.spawn(
        .{ .stack_size = 1024 * 1024 },
        reapChild,
        .{ backend, self.event_writer },
    ) catch |err| {
        log.err("Failed to spawn reaper thread: {any}", .{err});
        return;
    };
    reaper_thread.detach();
}

fn loop(self: *Self) !void {
    while (try self.loopOnce()) {}
}

fn loopOnce(self: *Self) !bool {
    if (@atomicLoad(bool, &self.quit, .monotonic)) return false;

    var stream = LockedStream{ .process = self };
    const eof = try self.backend.?.drain(&stream);
    if (stream.drained) try self.notifyVtUpdate();
    return !eof;
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
    try self.event_writer.write(self.event_buf.items());
    self.event_buf.resize(0);
}

fn reapChild(process: Backend, event_writer: EventWriter) void {
    var proc = process;
    var writer = event_writer;
    const exit_code = proc.deinitAndWait();

    // A bare number is not a terminal callback; the Elisp event filter treats
    // it as the child's exit status and deletes the pipe process to run its
    // sentinel. Closing the fd after the write releases Emacs' pipe once the
    // native child is truly gone.
    var exit_code_buf: [3]u8 = undefined;
    const str = std.fmt.bufPrint(&exit_code_buf, "{}", .{exit_code}) catch unreachable;
    writer.write(str) catch |err| {
        log.warn("Failed to write native child exit event: {any}", .{err});
    };
    writer.close();
}

pub fn deinit(self: *Self) void {
    @atomicStore(bool, &self.quit, true, .monotonic);
    self.backend_mutex.lock();
    if (self.backend) |*backend| {
        backend.requestStop(self.thread);
    }
    self.backend_mutex.unlock();
    self.thread.join();

    self.stream.deinit();
    self.alloc.free(self.replica_name);
}
