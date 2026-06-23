const builtin = @import("builtin");
const std = @import("std");

const Backend = switch (builtin.os.tag) {
    .windows => @import("ConPtyProcess.zig"),
    else => @import("PosixPtyProcess.zig"),
};

const Self = @This();

backend: Backend,

pub const ProcessParams = Backend.ProcessParams;
pub const EventWriter = Backend.EventWriter;

pub fn init(alloc: std.mem.Allocator, initial_cols: u16, initial_rows: u16, params: ProcessParams) !Self {
    return .{ .backend = try Backend.init(alloc, initial_cols, initial_rows, params) };
}

pub fn pidValue(self: *const Self) i64 {
    return self.backend.pidValue();
}

pub fn resize(self: *Self, cols: u16, rows: u16) !void {
    try self.backend.resize(cols, rows);
}

pub fn write(self: *Self, data: []const u8) !void {
    try self.backend.write(data);
}

pub fn read(self: *Self, buf: []u8) !usize {
    return try self.backend.read(buf);
}

pub fn requestStop(self: *Self, thread: std.Thread) void {
    self.backend.requestStop(thread);
}

pub fn replicaName(self: *Self) []const u8 {
    return self.backend.replicaName();
}

pub fn deinitAndWait(self: *Self) u8 {
    return self.backend.deinitAndWait();
}
