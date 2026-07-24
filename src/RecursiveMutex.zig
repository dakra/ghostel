const std = @import("std");
const Self = @This();

mutex: std.Io.Mutex = .init,
thread_id: std.Thread.Id = unlocked,
lock_count: usize = 0,

const unlocked = std.math.maxInt(std.Thread.Id);

pub fn lock(self: *Self, io: std.Io) !void {
    const current = std.Thread.getCurrentId();
    if (@atomicLoad(std.Thread.Id, &self.thread_id, .unordered) != current) {
        try self.mutex.lock(io);
        @atomicStore(std.Thread.Id, &self.thread_id, current, .unordered);
    }
    self.lock_count += 1;
}

pub fn lockUncancelable(self: *Self, io: std.Io) void {
    const current = std.Thread.getCurrentId();
    if (@atomicLoad(std.Thread.Id, &self.thread_id, .unordered) != current) {
        self.mutex.lockUncancelable(io);
        @atomicStore(std.Thread.Id, &self.thread_id, current, .unordered);
    }
    self.lock_count += 1;
}

pub fn unlock(self: *Self, io: std.Io) void {
    self.lock_count -= 1;
    if (self.lock_count == 0) {
        @atomicStore(std.Thread.Id, &self.thread_id, unlocked, .unordered);
        self.mutex.unlock(io);
    }
}
