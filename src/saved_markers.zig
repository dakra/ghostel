const std = @import("std");
const Allocator = std.mem.Allocator;

const gt = @import("ghostty-vt");

const emacs = @import("emacs.zig");
const utils = @import("utils.zig");

pub const SavedMarker = struct {
    pos: usize,
    pin: ?*gt.Pin = null,

    pub fn pinPos(self: *SavedMarker, screen: *gt.Screen, env: emacs.Env) void {
        if (utils.bufferPosToPin(screen, env, self.pos)) |pin| {
            self.pin = screen.pages.trackPin(pin) catch null;
        }
    }

    pub fn unpinPos(self: *SavedMarker, screen: *gt.Screen, env: emacs.Env) void {
        if (self.pin) |pin| {
            self.pos = utils.pinToBufferPos(screen, env, pin.*) orelse self.pos;
            screen.pages.untrackPin(pin);
            self.pin = null;
        }
    }

    pub fn adjustRegion(
        self: *SavedMarker,
        start: usize,
        old_len: usize,
        new_len: usize,
    ) void {
        if (self.pos < start) return;

        const old_end = start + old_len;
        const new_end = start + new_len;
        if (self.pos < old_end) {
            if (self.pos >= new_end) self.pos = new_end;
        } else {
            self.pos -= old_end;
            self.pos += new_end;
        }
    }
};

pub const SavedBufferMarkers = struct {
    const Window = struct {
        window: emacs.Value,
        point: SavedMarker,
        start: SavedMarker,
    };

    windows: std.ArrayList(Window) = .empty,
    mark: ?SavedMarker = null,

    pub fn save(self: *SavedBufferMarkers, alloc: Allocator, env: emacs.Env) !void {
        const mark_val = env.f("marker-position", .{env.f("mark-marker", .{})});
        if (env.isNotNil(mark_val)) {
            self.mark = .{ .pos = env.cast(usize, mark_val) };
        }

        var windows = env.f("get-buffer-window-list", .{ env.nil(), env.nil(), env.t() });
        while (!env.isNil(windows)) : (windows = env.f("cdr", .{windows})) {
            const window = env.f("car", .{windows});

            try self.windows.append(alloc, .{
                .window = window,
                .point = .{
                    .pos = env.cast(usize, env.f("window-point", .{window})),
                },
                .start = .{
                    .pos = env.cast(usize, env.f("window-start", .{window})),
                },
            });
        }
    }

    pub fn adjustRegion(
        self: *SavedBufferMarkers,
        start: usize,
        old_len: usize,
        new_len: usize,
    ) void {
        if (self.mark) |*mark| {
            mark.adjustRegion(start, old_len, new_len);
        }

        for (self.windows.items) |*win| {
            win.point.adjustRegion(start, old_len, new_len);
            win.start.adjustRegion(start, old_len, new_len);
        }
    }

    pub fn pin(self: *SavedBufferMarkers, screen: *gt.Screen, env: emacs.Env) void {
        if (self.mark) |*mark| {
            mark.pinPos(screen, env);
        }

        for (self.windows.items) |*win| {
            win.point.pinPos(screen, env);
            win.start.pinPos(screen, env);
        }
    }

    fn unpin(self: *SavedBufferMarkers, screen: *gt.Screen, env: emacs.Env) void {
        if (self.mark) |*mark| {
            mark.unpinPos(screen, env);
        }

        for (self.windows.items) |*win| {
            win.point.unpinPos(screen, env);
            win.start.unpinPos(screen, env);
        }
    }

    pub fn restoreAndClear(
        self: *SavedBufferMarkers,
        screen: *gt.Screen,
        env: emacs.Env,
    ) void {
        self.unpin(screen, env);

        if (self.mark) |mark| {
            _ = env.f(
                "set-marker",
                .{ env.f("mark-marker", .{}), mark.pos },
            );
            self.mark = null;
        }

        for (self.windows.items) |w| {
            _ = env.f("set-window-point", .{ w.window, w.point.pos });
            _ = env.f("set-window-start", .{ w.window, w.start.pos, env.t() });
        }

        self.windows.clearRetainingCapacity();
    }

    pub fn deinit(self: *SavedBufferMarkers, alloc: Allocator) void {
        self.windows.deinit(alloc);
    }
};
