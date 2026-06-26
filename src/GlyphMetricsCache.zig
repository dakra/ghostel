const std = @import("std");
const Allocator = std.mem.Allocator;

const gt = @import("ghostty-vt");

const StyleId = @FieldType(gt.page.Cell, "style_id");

const Self = @This();

cache: std.HashMapUnmanaged(
    Key,
    Metrics,
    *const Self,
    std.hash_map.default_max_load_percentage,
) = .empty,

utf8_buf: std.ArrayList(u8) = .empty,

pub const Key = struct {
    page_serial: u64,
    style_id: StyleId,
    utf8: union(enum) {
        borrowed: []const u8,
        owned: struct {
            start_offset: usize,
            end_offset: usize,
        },
    },

    pub fn utf8Slice(self: @This(), buf: []const u8) []const u8 {
        return switch (self.utf8) {
            .borrowed => |b| b,
            .owned => |o| buf[o.start_offset..o.end_offset],
        };
    }

    pub fn borrowed(self: @This(), buf: []const u8) @This() {
        var copy = self;
        copy.utf8 = .{ .borrowed = self.utf8Slice(buf) };
        return copy;
    }
};

pub const Metrics = packed struct {
    width: u16,
    ascent: u16,
    descent: u16,
    pixel_size: u16,
};

pub fn put(self: *Self, alloc: Allocator, key: Key, metrics: Metrics) !void {
    std.debug.assert(key.utf8 == .borrowed);

    if (self.cache.getEntryContext(key, self)) |entry| {
        entry.value_ptr.* = metrics;
    } else {
        var owned_key = key;
        const start = self.utf8_buf.items.len;
        try self.utf8_buf.appendSlice(alloc, key.utf8.borrowed);
        const end = self.utf8_buf.items.len;
        owned_key.utf8 = .{ .owned = .{ .start_offset = start, .end_offset = end } };
        try self.cache.putNoClobberContext(alloc, owned_key, metrics, self);
    }
}

pub fn get(self: *Self, key: Key) ?Metrics {
    std.debug.assert(key.utf8 == .borrowed);
    return self.cache.getContext(key, self);
}

pub fn hash(self: Self, key: Key) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, key.page_serial);
    std.hash.autoHash(&hasher, key.style_id);
    std.hash.autoHashStrat(
        &hasher,
        key.utf8Slice(self.utf8_buf.items),
        .Deep,
    );
    return hasher.final();
}

pub fn eql(self: Self, a: Key, b: Key) bool {
    return a.page_serial == b.page_serial and
        a.style_id == b.style_id and
        std.mem.eql(
            u8,
            a.utf8Slice(self.utf8_buf.items),
            b.utf8Slice(self.utf8_buf.items),
        );
}

pub fn deinit(self: *@This(), alloc: Allocator) void {
    self.cache.deinit(alloc);
    self.utf8_buf.deinit(alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testKey(page_serial: u64, style_id: StyleId, utf8: []const u8) Key {
    return .{
        .page_serial = page_serial,
        .style_id = style_id,
        .utf8 = .{ .borrowed = utf8 },
    };
}

test "GlyphMetricsCache: put and then get" {
    var cache: Self = .{};
    defer cache.deinit(testing.allocator);

    const key = testKey(1, 2, "A");
    const metrics: Metrics = .{ .width = 10, .ascent = 12, .descent = 8, .pixel_size = 14 };

    try cache.put(testing.allocator, key, metrics);

    try testing.expectEqual(metrics, cache.get(key).?);
}

test "GlyphMetricsCache: put, replace, and then get" {
    var cache: Self = .{};
    defer cache.deinit(testing.allocator);

    const key = testKey(1, 2, "A");
    const initial: Metrics = .{ .width = 10, .ascent = 12, .descent = 8, .pixel_size = 14 };
    const replacement: Metrics = .{ .width = 30, .ascent = 22, .descent = 18, .pixel_size = 24 };

    try cache.put(testing.allocator, key, initial);
    const utf8_buf_len = cache.utf8_buf.items.len;
    try cache.put(testing.allocator, key, replacement);

    try testing.expectEqual(replacement, cache.get(key).?);
    try testing.expectEqual(utf8_buf_len, cache.utf8_buf.items.len);
}

test "GlyphMetricsCache: get non-existing" {
    var cache: Self = .{};
    defer cache.deinit(testing.allocator);

    try testing.expectEqual(null, cache.get(testKey(1, 2, "A")));
}
