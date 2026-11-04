const std = @import("std");

/// Intrusive atomic reference count. Parent must embed a `refcount` field
/// and provide `pub fn destroy(*Parent) void`, called on the final release.
pub fn RefCount(comptime Parent: type) type {
    return struct {
        const Self = @This();

        count: std.atomic.Value(usize),

        pub fn init(initial: usize) Self {
            std.debug.assert(initial > 0);
            return .{ .count = .init(initial) };
        }

        /// Acquire an additional reference to Parent. An existing reference
        /// must keep Parent alive throughout this call.
        pub fn retain(self: *Self) void {
            const previous = self.count.fetchAdd(1, .monotonic);
            std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
        }

        /// Releases ownership and may destroy Parent. Do not access self afterward.
        pub fn release(self: *Self) void {
            const previous = self.count.fetchSub(1, .acq_rel);
            std.debug.assert(previous > 0);
            if (previous == 1) {
                const parent: *Parent = @alignCast(@fieldParentPtr("refcount", self));
                parent.destroy();
            }
        }
    };
}

test "final release recovers an aligned parent from an embedded counter" {
    const Owner = struct {
        marker: u8 align(64) = 17,
        refcount: RefCount(@This()) = .init(1),
        destroyed: bool = false,

        pub fn destroy(self: *@This()) void {
            std.debug.assert(self.marker == 17);
            self.destroyed = true;
        }
    };
    var owner: Owner = .{};
    owner.refcount.retain();
    owner.refcount.release();
    try std.testing.expect(!owner.destroyed);
    owner.refcount.release();
    try std.testing.expect(owner.destroyed);
}

test "initial ownership can consist of multiple references" {
    const Owner = struct {
        refcount: RefCount(@This()) = .init(2),
        destructions: usize = 0,

        pub fn destroy(self: *@This()) void {
            self.destructions += 1;
        }
    };
    var owner: Owner = .{};
    owner.refcount.release();
    try std.testing.expectEqual(@as(usize, 0), owner.destructions);
    owner.refcount.release();
    try std.testing.expectEqual(@as(usize, 1), owner.destructions);
}

test "concurrent final release destroys once and observes all owners' writes" {
    const owners = 8;
    const Owner = struct {
        refcount: RefCount(@This()) = .init(owners),
        values: [owners]usize = @splat(0),
        sum: usize = 0,
        destructions: usize = 0,

        fn run(self: *@This(), index: usize) void {
            self.values[index] = index;
            self.refcount.release();
        }

        pub fn destroy(self: *@This()) void {
            for (self.values) |value| self.sum += value;
            self.destructions += 1;
        }
    };
    var owner: Owner = .{};
    var threads: [owners]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer for (threads[0..spawned]) |thread| thread.join();
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Owner.run, .{ &owner, index });
        spawned += 1;
    }
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(usize, 1), owner.destructions);
    try std.testing.expectEqual(@as(usize, 28), owner.sum);
}
