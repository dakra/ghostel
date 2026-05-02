const std = @import("std");
const builtin = @import("builtin");

/// Minimalist array list implementation with fixed inline storage. Exists due
/// to poor ergonomics with builtin Zig stdlib types and not wanting external
/// dependencies.
pub fn FixedArrayList(comptime T: type, comptime buffer_capacity: usize) type {
    return struct {
        const Self = @This();

        pub const capacity = buffer_capacity;

        buffer: [capacity]T = undefined,
        len: usize = 0,

        /// Appends a single item
        pub fn append(self: *Self, value: T) error{Overflow}!void {
            if (self.len >= capacity) return error.Overflow;

            self.buffer[self.len] = value;
            self.len += 1;
        }

        /// Resizes the array, adding n uninitialized elements and returns a
        /// slice to those elements. Errors on overflow.
        pub fn addManyAsSlice(self: *Self, n: usize) error{Overflow}![]T {
            const begin = self.len;
            try self.addMany(n);
            return self.buffer[begin..(begin + n)];
        }

        /// Resizes the array, adding n uninitialized elements.
        pub fn addMany(self: *Self, n: usize) error{Overflow}!void {
            if (self.len + n > capacity) return error.Overflow;
            self.len += n;
        }

        /// Returns a slice of the remaining capacity.
        pub fn unusedCapacitySlice(self: *Self) []T {
            return self.buffer[self.len..capacity];
        }

        /// Returns the remaining capacity
        pub fn unusedCapacity(self: *const Self) usize {
            return capacity - self.len;
        }

        /// Returns the last item. If empty, undefined behavior.
        pub fn lastPtr(self: *Self) *T {
            if (comptime builtin.mode == .Debug) std.debug.assert(self.len > 0);
            return &self.buffer[self.len - 1];
        }

        /// Returns a mutable slice to the items
        pub fn items(self: *Self) []T {
            return self.buffer[0..self.len];
        }

        /// Returns a const slice to the items
        pub fn constItems(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }

        /// Sets the size to the given size. If the size is larger than the
        /// current length, the new items remain uninitialized. If the size is
        /// larger than capacity, undefined behavior.
        pub fn resize(self: *Self, len: usize) void {
            if (comptime builtin.mode == .Debug) std.debug.assert(len <= capacity);
            self.len = len;
        }
    };
}

test "empty on init" {
    const list: FixedArrayList(i32, 10) = .{};
    try std.testing.expectEqual(0, list.len);
}

test "append: adds an element" {
    var list: FixedArrayList(i32, 10) = .{};
    try list.append(123);
    try std.testing.expectEqual(1, list.len);
    try std.testing.expectEqual(123, list.buffer[0]);
}

test "append: errors on overflow" {
    var list: FixedArrayList(i32, 2) = .{};
    try list.append(123);
    try list.append(456);
    try std.testing.expectError(error.Overflow, list.append(789));
}

test "addManyAsSlice: returns slice at end" {
    var list: FixedArrayList(i32, 100) = .{};
    try list.append(123);
    try list.append(456);
    const expected = list.buffer[list.len..12];
    const slice = try list.addManyAsSlice(10);
    try std.testing.expectEqual(expected, slice);
}

test "addManyAsSlice: overflows on error" {
    var list: FixedArrayList(i32, 10) = .{};
    try list.append(123);
    try list.append(456);
    try std.testing.expectError(error.Overflow, list.addManyAsSlice(10));
}

test "addMany: increases length" {
    var list: FixedArrayList(i32, 100) = .{};
    try list.append(123);
    try list.append(456);
    try list.addMany(10);
    try std.testing.expectEqual(12, list.len);
}

test "addMany: overflows on error" {
    var list: FixedArrayList(i32, 10) = .{};
    try list.append(123);
    try list.append(456);
    try std.testing.expectError(error.Overflow, list.addMany(10));
}

test "unusedCapacitySlice: returns slice of rest" {
    var list: FixedArrayList(i32, 10) = .{};
    try list.append(123);
    try list.append(456);
    const expected = list.buffer[list.len..10];
    try std.testing.expectEqual(expected, list.unusedCapacitySlice());
}

test "unusedCapacity: returns amount of space left" {
    var list: FixedArrayList(i32, 10) = .{};
    try list.append(123);
    try list.append(456);
    try std.testing.expectEqual(8, list.unusedCapacity());
}

test "lastPtr: returns pointer to last element" {
    var list: FixedArrayList(i32, 10) = .{};
    try list.append(123);
    try list.append(456);
    const expected = &list.buffer[list.len - 1];
    try std.testing.expectEqual(expected, list.lastPtr());
}

test "items: returns a slice to valid items" {
    var list: FixedArrayList(i32, 10) = .{};
    try list.append(123);
    try list.append(456);
    try std.testing.expectEqual(list.buffer[0..2], list.items());
}

test "constItems: returns a slice to valid items" {
    var list: FixedArrayList(i32, 10) = .{};
    try list.append(123);
    try list.append(456);
    try std.testing.expectEqual(list.buffer[0..2], list.constItems());
}

test "resize: shrinks length to given size" {
    var list: FixedArrayList(i32, 10) = .{};
    try list.append(123);
    try list.append(456);
    try list.append(789);

    list.resize(2);
    try std.testing.expectEqual(2, list.len);
}

test "resize: grows length to given size" {
    var list: FixedArrayList(i32, 10) = .{};
    try list.append(123);
    try list.append(456);
    try list.append(789);

    list.resize(5);
    try std.testing.expectEqual(5, list.len);
}
