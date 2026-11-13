//! Kitty placement layout and lazy, row-local image composition.
//! No Lisp values survive a module call here: Emacs owns the image cache.
const std = @import("std");
const gt = @import("ghostty-vt");
const emacs = @import("emacs.zig");
const pixels = @import("image_composition.zig");
const png = @import("png.zig");
const ppm = @import("ppm.zig");
const Self = @This();
const Allocator = std.mem.Allocator;
const Storage = gt.kitty.graphics.ImageStorage;

alloc: Allocator,
frames: [2]Frame,
current: u1 = 0,
enabled: bool = false,
ppm_background: ?gt.color.RGB = null,
display_cell_width: u32 = 1,
display_cell_height: u32 = 1,
reported_cell_width: u32 = 1,
reported_cell_height: u32 = 1,
canvas: std.ArrayList(u8) = .empty,
visible: std.ArrayList(u8) = .empty,
resize_scratch: pixels.Scratch = .{},

// Clear everything on overflow. Buffer properties retain any images still shown.
const cache_limit = 256;

const RowKey = struct {
    node: *gt.PageList.List.Node,
    serial: u64,
    y: gt.size.CellCountInt,

    fn init(pin: gt.Pin) RowKey {
        return .{ .node = pin.node, .serial = pin.node.serial, .y = pin.y };
    }
};

const SliceKey = struct {
    image_id: u32,
    generation: u64,
    z: i32,
    source: Storage.Placement.SourceRect,
    dest: pixels.Destination,
    clip: ?pixels.Destination,
};

const Slice = struct {
    image_id: u32,
    generation: u64,
    placement_id: u32,
    source: Storage.Placement.SourceRect,
    dest: pixels.Destination,
    clip: ?pixels.Destination = null,
    z: i32,

    fn key(self: Slice, canvas_x: i64) SliceKey {
        var dest = self.dest;
        dest.x -= canvas_x;
        var clip = self.clip;
        if (clip) |*c| c.x -= canvas_x;
        return .{
            .image_id = self.image_id,
            .generation = self.generation,
            .z = self.z,
            .source = self.source,
            .dest = dest,
            .clip = clip,
        };
    }

    fn lessThan(_: void, a: Slice, b: Slice) bool {
        if (a.z != b.z) return a.z < b.z;
        if (a.image_id != b.image_id) return a.image_id < b.image_id;
        return a.placement_id < b.placement_id;
    }
};

const Plan = struct {
    slices: std.ArrayList(Slice) = .empty,
    first_col: u32 = 0,
    end_col: u32 = 0,
    raster_key: []const u8 = &.{},
};

const Frame = struct {
    arena: std.heap.ArenaAllocator,
    rows: std.AutoHashMapUnmanaged(RowKey, Plan) = .empty,

    fn clear(self: *Frame) void {
        self.rows.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    fn deinit(self: *Frame, alloc: Allocator) void {
        self.rows.deinit(alloc);
        self.arena.deinit();
    }
};

pub const Row = struct {
    const Span = struct { start_col: u32, end_col: u32, display: emacs.Value };

    first_col: u32,
    image: emacs.Value,
    mask: []const u8,
    cell_width: u32,
    cell_height: u32,

    pub const Iterator = struct {
        env: emacs.Env,
        row: Row,
        col: u32 = 0,
        current: ?Span = null,

        fn next(self: *Iterator) ?Span {
            const mask = self.row.mask;
            while (self.col < mask.len and mask[self.col] == 0) self.col += 1;
            if (self.col == mask.len) return null;

            const start = self.col;
            while (self.col < mask.len and mask[self.col] != 0) self.col += 1;
            const end = self.col;
            const crop = self.env.list(.{
                emacs.sym.slice,
                start * self.row.cell_width,
                0,
                (end - start) * self.row.cell_width,
                self.row.cell_height,
            });
            const display = self.env.list(.{ crop, self.row.image });
            return .{
                .start_col = self.row.first_col + start,
                .end_col = self.row.first_col + end,
                .display = display,
            };
        }

        /// Visit columns in increasing order, advancing past completed spans.
        pub fn imageAt(self: *Iterator, col: usize) ?emacs.Value {
            while (self.current) |span| {
                if (col < span.start_col) return null;
                if (col < span.end_col) return span.display;
                self.current = self.next();
            }
            return null;
        }
    };

    pub fn iterator(self: Row, env: emacs.Env) Iterator {
        var it = Iterator{ .env = env, .row = self };
        it.current = it.next();
        return it;
    }
};

pub fn init(alloc: Allocator, env: emacs.Env) Self {
    env.defvarLocal("ghostel--kitty-image-cache", env.f("make-hash-table", .{
        emacs.sym.@":test", emacs.sym.equal,
    }));
    return .{
        .alloc = alloc,
        .frames = .{
            .{ .arena = .init(alloc) },
            .{ .arena = .init(alloc) },
        },
    };
}

pub fn deinit(self: *Self) void {
    for (&self.frames) |*frame| frame.deinit(self.alloc);
    self.canvas.deinit(self.alloc);
    self.visible.deinit(self.alloc);
    self.resize_scratch.deinit(self.alloc);
}

/// Prepare pinned layout for all retained rows. Placeholder layout is added
/// per row by `prepareRow`; pixels are realized only by `getRow`.
pub fn prepare(
    self: *Self,
    term: *gt.Terminal,
    display_cell_width: u32,
    display_cell_height: u32,
    enabled: bool,
    ppm_background: ?gt.color.RGB,
) !void {
    const next = &self.frames[self.current ^ 1];
    next.clear();
    self.enabled = enabled;
    self.ppm_background = ppm_background;
    self.display_cell_width = @max(1, display_cell_width);
    self.display_cell_height = @max(1, display_cell_height);
    self.reported_cell_width = @max(1, term.width_px / term.cols);
    self.reported_cell_height = @max(1, term.height_px / term.rows);
    const screen = term.screens.active;
    const storage = &screen.kitty_images;

    if (enabled and storage.placements.count() > 0) {
        try self.preparePinned(next, term);
        var plans = next.rows.iterator();
        while (plans.next()) |entry| {
            const pin: gt.Pin = .{ .node = entry.key_ptr.node, .y = entry.key_ptr.y };
            try self.finishPlan(next.arena.allocator(), pin, entry.value_ptr);
        }
    }

    self.current ^= 1;
}

/// Compare plans only for a live row supplied by the text renderer.
/// Previous map keys may outlive their pages and are never dereferenced.
/// Text-layout changes are tracked separately by libghostty's dirty flags.
pub fn isRowDirty(self: *const Self, pin: gt.Pin) bool {
    const key = RowKey.init(pin);
    const old_plan = self.frames[self.current ^ 1].rows.get(key);
    const new_plan = self.frames[self.current].rows.get(key);
    const before = if (old_plan) |plan| plan.raster_key else &.{};
    const after = if (new_plan) |plan| plan.raster_key else &.{};
    const moved = old_plan != null and new_plan != null and old_plan.?.first_col != new_plan.?.first_col;
    return moved or !std.mem.eql(u8, before, after);
}

fn preparePinned(self: *Self, frame: *Frame, term: *gt.Terminal) !void {
    const storage = &term.screens.active.kitty_images;
    var it = storage.placements.iterator();
    while (it.next()) |entry| {
        const image = storage.images.getPtr(entry.key_ptr.image_id) orelse continue;
        if (image.renderData().isPending()) continue;
        const placement = entry.value_ptr;
        switch (placement.location) {
            .virtual => {},
            .pin => |pin| try self.addPinned(frame, term, entry.key_ptr.*, placement.*, image, pin.*, 0, 0),
            .relative => |relative| {
                const chain = storage.resolveChain(relative) orelse continue;
                // Relative placements rooted in placeholders remain unsupported.
                if (chain.root.location != .pin) continue;
                try self.addPinned(
                    frame,
                    term,
                    entry.key_ptr.*,
                    placement.*,
                    image,
                    chain.root.location.pin.*,
                    chain.horizontal_offset,
                    chain.vertical_offset,
                );
            },
        }
    }
}

/// Add placeholder layout once for a row visited by Renderer, before its dirty
/// check. Unvisited rows are never scanned for placeholders.
pub fn prepareRow(self: *Self, term: *gt.Terminal, pin: gt.Pin) !void {
    const storage = &term.screens.active.kitty_images;
    if (!self.enabled or storage.placements.count() == 0 or
        !pin.rowAndCell().row.kitty_virtual_placeholder) return;
    const frame = &self.frames[self.current];
    var placeholders = PlaceholderIterator.init(pin);
    while (placeholders.next()) |run| {
        const image = storage.images.getPtr(run.image_id) orelse continue;
        if (image.renderData().isPending()) continue;
        const target = storage.placeholderTarget(run.image_id, run.placement_id) orelse continue;
        if (target.placement.location != .virtual) continue;
        try self.addVirtual(frame, run, target.key, target.placement, image);
    }
    if (frame.rows.getPtr(RowKey.init(pin))) |plan|
        try self.finishPlan(frame.arena.allocator(), pin, plan);
}

fn scaleX(self: *const Self, value: u32) i64 {
    return scaleDimension(value, self.display_cell_width, self.reported_cell_width);
}

fn scaleY(self: *const Self, value: u32) i64 {
    return scaleDimension(value, self.display_cell_height, self.reported_cell_height);
}

fn scaleDimension(value: u32, numerator: u32, denominator: u32) i64 {
    return @intCast((@as(u64, value) * numerator + denominator / 2) / denominator);
}

fn addVirtual(
    self: *Self,
    frame: *Frame,
    run: gt.kitty.graphics.unicode.Placement,
    key: Storage.PlacementKey,
    target: Storage.Placement,
    image: *const gt.kitty.graphics.Image,
) !void {
    // Like Kitty, virtual prototypes fit the full image. Placeholder coordinates
    // select fragments; the prototype's source-crop fields do not apply.
    const source_rect: Storage.Placement.SourceRect = .{
        .x = 0,
        .y = 0,
        .width = image.width,
        .height = image.height,
    };
    if (source_rect.width == 0 or source_rect.height == 0) return;
    // Without an explicit grid, round up to whole reported-size cells.
    const grid_cols = if (target.columns > 0)
        target.columns
    else
        (source_rect.width - 1) / self.reported_cell_width + 1;
    const grid_rows = if (target.rows > 0)
        target.rows
    else
        (source_rect.height - 1) / self.reported_cell_height + 1;
    if (run.col >= grid_cols or run.row >= grid_rows) return;

    const grid_width = std.math.mul(u32, grid_cols, self.display_cell_width) catch return;
    const grid_height = std.math.mul(u32, grid_rows, self.display_cell_height) catch return;
    // Scale the full source rectangle to fit the whole placement grid.
    // Each run clips that same scaled image to its own cells; scaling separate
    // source crops could round differently at their shared edges.
    const fit_to_width = @as(u64, source_rect.width) * grid_height > @as(u64, source_rect.height) * grid_width;
    const fitted_width: u32 = if (fit_to_width)
        grid_width
    else
        @intCast(scaleDimension(source_rect.width, grid_height, source_rect.height));
    const fitted_height: u32 = if (fit_to_width)
        @intCast(scaleDimension(source_rect.height, grid_width, source_rect.width))
    else
        grid_height;
    // Padding centers the fitted image within the grid, in display pixels.
    const letterbox_x = (grid_width - fitted_width) / 2;
    const letterbox_y = (grid_height - fitted_height) / 2;
    const run_width_cells = @min(run.width, grid_cols - run.col);
    // clip and dest use display pixels relative to the terminal row's top-left.
    const clip: pixels.Destination = .{
        .x = @as(i64, run.pin.x) * self.display_cell_width,
        .y = 0,
        .width = try std.math.mul(u32, run_width_cells, self.display_cell_width),
        .height = self.display_cell_height,
    };
    // Subtract the run's position within the placement grid to locate the full
    // grid's origin, then add the padding to locate the image within that grid.
    const dest: pixels.Destination = .{
        .x = clip.x - @as(i64, run.col) * self.display_cell_width + letterbox_x,
        .y = -@as(i64, run.row) * self.display_cell_height + letterbox_y,
        .width = fitted_width,
        .height = fitted_height,
    };

    try self.addSlice(frame, run.pin, key, image, target.z, source_rect, dest, clip);
}

fn addPinned(
    self: *Self,
    frame: *Frame,
    term: *gt.Terminal,
    key: Storage.PlacementKey,
    placement: Storage.Placement,
    image: *const gt.kitty.graphics.Image,
    anchor_pin: gt.Pin,
    offset_cells_h: i32,
    offset_cells_v: i32,
) !void {
    if (anchor_pin.garbage) return;
    const pixel_size = placement.pixelSize(image.*, term);
    const cell_offset = placement.cellOffset(term);
    const source_rect = placement.sourceRect(image.*);
    const y_from_anchor_px = @as(i64, offset_cells_v) * self.display_cell_height +
        self.scaleY(cell_offset.y);
    const first_row_offset = @divFloor(y_from_anchor_px, self.display_cell_height);

    // Convert reported-pixel geometry to display pixels. The full image's y is
    // relative to the current row; its dimensions stay fixed as we walk rows.
    var dest: pixels.Destination = .{
        .x = (@as(i64, anchor_pin.x) + offset_cells_h) * self.display_cell_width +
            self.scaleX(cell_offset.x),
        .y = @mod(y_from_anchor_px, self.display_cell_height),
        .width = std.math.cast(u32, self.scaleX(pixel_size.width)) orelse return,
        .height = std.math.cast(u32, self.scaleY(pixel_size.height)) orelse return,
    };
    const first_row_pin = if (first_row_offset >= 0)
        anchor_pin.down(@intCast(first_row_offset)) orelse return
    else switch (anchor_pin.upOverflow(@intCast(-first_row_offset))) {
        .offset => |pin| pin,
        .overflow => |overflow| clipped: {
            // The first image row predates retained history. Begin at the oldest
            // retained row, with the image shifted up by the missing row count.
            const clipped_rows = @as(i64, @intCast(overflow.remaining));
            dest.y -= clipped_rows * self.display_cell_height;
            break :clipped overflow.end;
        },
    };
    var rows = first_row_pin.rowIterator(.right_down, null);
    while (dest.y + dest.height > 0) : (dest.y -= self.display_cell_height) {
        const row_pin = rows.next() orelse break;
        try self.addSlice(
            frame,
            row_pin,
            key,
            image,
            placement.z,
            source_rect,
            dest,
            null,
        );
    }
}

fn addSlice(
    self: *Self,
    frame: *Frame,
    pin: gt.Pin,
    key: Storage.PlacementKey,
    image: *const gt.kitty.graphics.Image,
    z: i32,
    source: Storage.Placement.SourceRect,
    dest: pixels.Destination,
    clip: ?pixels.Destination,
) !void {
    if (dest.width == 0 or dest.height == 0 or source.width == 0 or source.height == 0) return;
    const row_width = @as(i64, pin.node.cols()) * self.display_cell_width;
    const left = if (clip) |c| @max(dest.x, c.x) else dest.x;
    const right = if (clip) |c| @min(dest.x + dest.width, c.x + c.width) else dest.x + dest.width;
    const top = if (clip) |c| @max(dest.y, c.y) else dest.y;
    const bottom = if (clip) |c| @min(dest.y + dest.height, c.y + c.height) else dest.y + dest.height;
    if (@max(0, left) >= @min(row_width, right) or
        @max(0, top) >= @min(self.display_cell_height, bottom)) return;
    const result = try frame.rows.getOrPut(self.alloc, RowKey.init(pin));
    if (!result.found_existing) result.value_ptr.* = .{};
    try result.value_ptr.slices.append(frame.arena.allocator(), .{
        .image_id = key.image_id,
        .generation = image.generation,
        .placement_id = key.placement_id.id,
        .source = source,
        .dest = dest,
        .clip = clip,
        .z = z,
    });
}

fn finishPlan(self: *Self, alloc: Allocator, pin: gt.Pin, plan: *Plan) !void {
    std.mem.sort(Slice, plan.slices.items, {}, Slice.lessThan);
    const row_cols = pin.node.cols();
    var left: i64 = @as(i64, row_cols) * self.display_cell_width;
    var right: i64 = 0;
    for (plan.slices.items) |slice| {
        const x0 = if (slice.clip) |c| @max(slice.dest.x, c.x) else slice.dest.x;
        const x1 = if (slice.clip) |c|
            @min(slice.dest.x + slice.dest.width, c.x + c.width)
        else
            slice.dest.x + slice.dest.width;
        left = @min(left, @max(0, x0));
        right = @max(right, @min(@as(i64, row_cols) * self.display_cell_width, x1));
    }
    plan.first_col = @intCast(@divFloor(left, self.display_cell_width));
    plan.end_col = @intCast(@divFloor(right + self.display_cell_width - 1, self.display_cell_width));

    // Include both cells when an image edge intersects a wide character.
    const cells = pin.node.page().getCells(pin.rowAndCell().row);
    if (cells[plan.first_col].wide == .spacer_tail and plan.first_col > 0) plan.first_col -= 1;
    if (cells[plan.end_col - 1].wide == .wide and plan.end_col < cells.len) plan.end_col += 1;

    var key: std.ArrayList(u8) = .empty;
    try appendKey(alloc, &key, self.ppm_background);
    try appendKey(alloc, &key, self.display_cell_width);
    try appendKey(alloc, &key, self.display_cell_height);
    try appendKey(alloc, &key, plan.end_col - plan.first_col);
    const canvas_x = @as(i64, plan.first_col) * self.display_cell_width;
    for (plan.slices.items) |slice| {
        try appendKey(alloc, &key, slice.key(canvas_x));
    }
    plan.raster_key = key.items;
}

fn appendKey(alloc: Allocator, key: *std.ArrayList(u8), value: anytype) Allocator.Error!void {
    switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => |info| inline for (info.field_names) |name| {
            try appendKey(alloc, key, @field(value, name));
        },
        .optional => {
            try appendKey(alloc, key, @intFromBool(value != null));
            if (value) |present| try appendKey(alloc, key, present);
        },
        .int, .comptime_int => {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(i64, &bytes, @intCast(value), .little);
            try key.appendSlice(alloc, &bytes);
        },
        else => @compileError("Cache keys must contain only integers, structs, and optionals"),
    }
}

/// Reuse cached image pixels and lay out the current row, or return null when
/// there is no visible raster.
/// The returned mask borrows storage until the next getRow call. Image handles
/// are valid only within this module call; Lisp owns cached images between calls.
pub fn getRow(self: *Self, env: emacs.Env, term: *gt.Terminal, pin: gt.Pin) !?Row {
    const plan = self.frames[self.current].rows.get(RowKey.init(pin)) orelse
        return null;
    const cache = env.symbolValue("ghostel--kitty-image-cache");
    const key = env.makeUnibyteString(plan.raster_key);
    var raster = env.f("gethash", .{ key, cache });
    try env.checkNonLocalExit();
    if (env.isNil(raster)) {
        raster = self.makeRaster(env, term, plan) catch |err| switch (err) {
            // Cache an omitted raster so excessive geometry cannot block text.
            error.ImageTooLarge => env.f("vector", .{ env.nil(), env.nil() }),
            else => return err,
        };
        if (env.cast(usize, env.f("hash-table-count", .{cache})) >= cache_limit)
            _ = env.f("clrhash", .{cache});
        _ = env.f("puthash", .{ key, raster, cache });
        try env.checkNonLocalExit();
    }
    return self.layoutRow(env, pin, plan, raster);
}

/// Cache one image and its pre-layout visibility mask, both owned by Emacs.
fn makeRaster(self: *Self, env: emacs.Env, term: *gt.Terminal, plan: Plan) !emacs.Value {
    const cols = plan.end_col - plan.first_col;
    const width = try std.math.mul(u32, cols, self.display_cell_width);
    const canvas_x = @as(i64, plan.first_col) * self.display_cell_width;
    try self.canvas.resize(self.alloc, try pixels.byteLength(width, self.display_cell_height));
    const canvas = self.canvas.items;
    @memset(canvas, 0);
    for (plan.slices.items) |slice| {
        self.drawSlice(term, canvas, width, canvas_x, slice) catch |err| switch (err) {
            // Retain other layers and text when this layer exceeds the bounded
            // resampling budget. Allocation failures still propagate normally.
            error.ImageTooLarge => continue,
            else => return err,
        };
    }
    try self.visible.resize(self.alloc, cols + 1);
    const visible = self.visible.items[0..cols];
    for (visible, 0..) |*value, col| {
        value.* = @intFromBool(pixels.cellVisible(canvas, width, self.display_cell_height, self.display_cell_width, @intCast(col)));
    }
    if (std.mem.indexOfScalar(u8, visible, 1) == null) {
        return env.f("vector", .{ env.nil(), env.nil() });
    }
    const mask = env.makeUnibyteString(visible);
    const data = if (self.ppm_background) |bg|
        try ppm.encode(self.alloc, canvas, width, self.display_cell_height, .{ bg.r, bg.g, bg.b })
    else png_data: {
        pixels.unpremultiply(canvas);
        break :png_data try png.encode(self.alloc, canvas, width, self.display_cell_height, width * 4);
    };
    defer self.alloc.free(data);
    const bytes = env.makeUnibyteString(data);
    const image = env.f("create-image", .{
        bytes,
        if (self.ppm_background != null) emacs.sym.pbm else emacs.sym.png,
        env.t(),
        emacs.sym.@":scale",
        1,
        emacs.sym.@":ascent",
        emacs.sym.center,
    });
    try env.checkNonLocalExit();
    if (env.isNil(image)) return error.ImageCreationFailed;
    return env.f("vector", .{ image, mask });
}

fn layoutRow(self: *Self, env: emacs.Env, pin: gt.Pin, plan: Plan, raster: emacs.Value) !?Row {
    const image = env.vecGet(raster, 0);
    if (env.isNil(image)) return null;

    const cols = plan.end_col - plan.first_col;
    try self.visible.resize(self.alloc, cols + 1);
    const mask = try env.extractString(env.vecGet(raster, 1), self.visible.items);
    std.debug.assert(mask.len == cols);
    const cells = pin.node.page().getCells(pin.rowAndCell().row)[plan.first_col..plan.end_col];

    var col: usize = 0;
    while (col < cols) {
        if (cells[col].wide == .wide and col + 1 < cols) {
            const visible = mask[col] | mask[col + 1];
            self.visible.items[col] = visible;
            self.visible.items[col + 1] = visible;
            col += 2;
        } else col += 1;
    }

    return .{
        .first_col = plan.first_col,
        .image = image,
        .mask = mask,
        .cell_width = self.display_cell_width,
        .cell_height = self.display_cell_height,
    };
}

fn drawSlice(
    self: *Self,
    term: *gt.Terminal,
    canvas: []u8,
    width: u32,
    canvas_x: i64,
    slice: Slice,
) !void {
    const image = term.screens.active.kitty_images.images.getPtr(slice.image_id).?;
    const data = image.renderData().bytes().?;
    const channels: u32 = switch (image.format) {
        .rgb => 3,
        .rgba => 4,
        .gray => 1,
        .gray_alpha => 2,
        .png => unreachable,
    };
    var dest = slice.dest;
    dest.x -= canvas_x;
    var clip = slice.clip;
    if (clip) |*c| c.x -= canvas_x;
    try pixels.draw(
        self.alloc,
        &self.resize_scratch,
        canvas,
        width,
        self.display_cell_height,
        .{ .data = data, .width = image.width, .height = image.height, .channels = channels },
        slice.source,
        dest,
        clip,
    );
}

/// Contiguous placeholder runs within one row, preserving omitted diacritics
/// and leaving intervening ordinary text outside the runs.
const PlaceholderIterator = struct {
    pin: gt.Pin,

    fn init(pin: gt.Pin) PlaceholderIterator {
        return .{ .pin = .{ .node = pin.node, .y = pin.y } };
    }

    fn next(self: *PlaceholderIterator) ?gt.kitty.graphics.unicode.Placement {
        const pin = &self.pin;
        var run: ?gt.kitty.graphics.unicode.IncompletePlacement = null;
        var origin: gt.Pin = undefined;
        while (pin.x < pin.node.cols()) {
            const cell = pin.rowAndCell().cell;
            if (cell.codepoint() != gt.kitty.graphics.unicode.placeholder) {
                if (run != null) break;
                pin.x += 1;
                continue;
            }
            const style = pin.style(cell);
            const placement = gt.kitty.graphics.unicode.IncompletePlacement.init(
                &style,
                pin.grapheme(cell) orelse &.{},
            );
            if (run) |*previous| {
                if (!previous.append(&placement)) break;
            } else {
                origin = pin.*;
                run = placement.start();
            }
            pin.x += 1;
        }
        if (run) |placement| return .{
            .pin = origin,
            .image_id = placement.imageId(),
            .placement_id = placement.placement_id orelse 0,
            .col = placement.col orelse 0,
            .row = placement.row orelse 0,
            .width = placement.width,
            .height = 1,
        };
        return null;
    }
};

test "raster keys distinguish image changes, geometry, and optional clipping" {
    const testing = std.testing;
    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(testing.allocator);
    const slice: Slice = .{
        .image_id = 1,
        .generation = 2,
        .placement_id = 99,
        .z = -3,
        .source = .{ .x = 4, .y = 5, .width = 6, .height = 7 },
        .dest = .{ .x = -8, .y = -9, .width = 10, .height = 11 },
        .clip = .{ .x = -12, .y = -13, .width = 14, .height = 15 },
    };
    try appendKey(testing.allocator, &key, slice.key(0));

    var variants: [7]Slice = @splat(slice);
    variants[0].image_id += 1;
    variants[1].generation += 1;
    variants[2].z += 1;
    variants[3].source.x += 1;
    variants[4].dest.y += 1;
    variants[5].clip.?.width += 1;
    variants[6].clip = null;
    var changed: std.ArrayList(u8) = .empty;
    defer changed.deinit(testing.allocator);
    for (variants) |variant| {
        changed.clearRetainingCapacity();
        try appendKey(testing.allocator, &changed, variant.key(0));
        try testing.expect(!std.mem.eql(u8, key.items, changed.items));
    }
}

test "slice keys normalize horizontal position and exclude placement identity" {
    const testing = std.testing;
    const slice: Slice = .{
        .image_id = 1,
        .generation = 2,
        .placement_id = 3,
        .z = 0,
        .source = .{ .x = 0, .y = 0, .width = 8, .height = 4 },
        .dest = .{ .x = 20, .y = -2, .width = 8, .height = 4 },
        .clip = .{ .x = 24, .y = 0, .width = 4, .height = 2 },
    };
    var moved = slice;
    moved.placement_id = 99;
    moved.dest.x += 16;
    moved.clip.?.x += 16;
    try testing.expect(std.meta.eql(slice.key(16), moved.key(32)));
    moved.clip.?.x += 1;
    try testing.expect(!std.meta.eql(slice.key(16), moved.key(32)));
}

test "raster clipping retains the correct pixels at terminal edges" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try gt.Terminal.init(testing.io, alloc, .{
        .cols = 4,
        .rows = 5,
        .kitty_image_storage_limit = 1000,
    });
    defer term.deinit(alloc);
    const screen = term.screens.active;
    try screen.kitty_images.addImage(testing.io, alloc, screen, .{
        .id = 1,
        .width = 2,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 255, 0, 0, 255, 0, 0, 255, 255 }) },
    });
    var renderer: Self = .{
        .alloc = alloc,
        .frames = .{ .{ .arena = .init(alloc) }, .{ .arena = .init(alloc) } },
    };
    defer renderer.deinit();
    const Case = struct { dest_x: i64, canvas_x: i64, rgba: [4]u8 };
    for ([_]Case{
        .{ .dest_x = -1, .canvas_x = 0, .rgba = .{ 0, 0, 255, 255 } },
        .{ .dest_x = 3, .canvas_x = 3, .rgba = .{ 255, 0, 0, 255 } },
    }) |case| {
        var canvas: [4]u8 = @splat(0);
        try renderer.drawSlice(&term, &canvas, 1, case.canvas_x, .{
            .image_id = 1,
            .generation = 0,
            .placement_id = 1,
            .source = .{ .x = 0, .y = 0, .width = 2, .height = 1 },
            .dest = .{ .x = case.dest_x, .y = 0, .width = 2, .height = 1 },
            .z = 0,
        });
        try testing.expectEqualSlices(u8, &case.rgba, &canvas);
    }
}

test "virtual grids and fragments use full image dimensions despite prototype crops" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try gt.Terminal.init(testing.io, alloc, .{ .cols = 8, .rows = 3 });
    defer term.deinit(alloc);
    var renderer: Self = .{
        .alloc = alloc,
        .frames = .{ .{ .arena = .init(alloc) }, .{ .arena = .init(alloc) } },
    };
    defer renderer.deinit();
    const frame = &renderer.frames[0];
    const image: gt.kitty.graphics.Image = .{ .id = 1, .width = 4, .height = 2 };
    const pin = term.screens.active.pages.getTopLeft(.screen);
    const key: Storage.PlacementKey = .{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    };
    for ([_]u32{ 0, 2 }) |grid_scale| {
        frame.clear();
        try renderer.addVirtual(frame, .{
            .pin = pin,
            .image_id = 1,
            .placement_id = 1,
            .col = 3,
            .row = 1,
            .width = 1,
            .height = 1,
        }, key, .{
            .location = .virtual,
            .columns = 4 * grid_scale,
            .rows = 2 * grid_scale,
            .source_x = std.math.maxInt(u32),
            .source_y = std.math.maxInt(u32),
            .source_width = 1,
            .source_height = 1,
        }, &image);
        const plan = frame.rows.get(RowKey.init(pin)).?;
        try testing.expectEqual(@as(usize, 1), plan.slices.items.len);
        const slice = plan.slices.items[0];
        try testing.expectEqualDeep(Storage.Placement.SourceRect{
            .x = 0,
            .y = 0,
            .width = 4,
            .height = 2,
        }, slice.source);
        const fitted_scale = @max(1, grid_scale);
        try testing.expectEqual(4 * fitted_scale, slice.dest.width);
        try testing.expectEqual(2 * fitted_scale, slice.dest.height);
        try testing.expectEqual(@as(i64, -3), slice.dest.x);
        try testing.expectEqual(@as(i64, -1), slice.dest.y);
    }
}

test "pinned plans are eager and placeholder plans are limited to requested rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try gt.Terminal.init(testing.io, alloc, .{
        .cols = 20,
        .rows = 5,
        .max_scrollback_bytes = 100_000,
        .kitty_image_storage_limit = 1000,
    });
    defer term.deinit(alloc);
    term.width_px = 20;
    term.height_px = 5;
    const screen = term.screens.active;
    const storage = &screen.kitty_images;
    // Metadata-only images make any accidental pixel realization fail.
    try storage.addImage(testing.io, alloc, screen, .{ .id = 1, .width = 1, .height = 1 });
    try storage.addImage(testing.io, alloc, screen, .{ .id = 2, .width = 1, .height = 1 });
    const anchor = try screen.pages.trackPin(screen.pages.getTopLeft(.active));
    try storage.addPlacement(testing.io, alloc, screen, 1, 1, .{
        .location = .{ .pin = anchor },
    });
    try storage.addPlacement(testing.io, alloc, screen, 2, 1, .{
        .location = .virtual,
        .columns = 1,
        .rows = 1,
    });
    screen.cursorAbsolute(0, 1);
    try term.setAttribute(.{ .direct_color_fg = .{ .r = 0, .g = 0, .b = 2 } });
    try term.print(gt.kitty.graphics.unicode.placeholder);
    screen.cursorAbsolute(0, 2);
    try term.print(gt.kitty.graphics.unicode.placeholder);
    try term.scrollUp(5);
    const placeholder = screen.pages.getTopLeft(.screen).down(1).?;
    const unrequested = placeholder.down(1).?;
    const active = screen.pages.getTopLeft(.active);
    try testing.expect(anchor.node != active.node or anchor.y != active.y);

    var renderer: Self = .{
        .alloc = alloc,
        .frames = .{ .{ .arena = .init(alloc) }, .{ .arena = .init(alloc) } },
    };
    defer renderer.deinit();
    try renderer.prepare(&term, 1, 1, true, null);
    const plans = &renderer.frames[renderer.current].rows;
    try testing.expectEqual(@as(usize, 1), plans.count());
    try testing.expect(plans.contains(RowKey.init(anchor.*)));
    try renderer.prepareRow(&term, active);
    try testing.expectEqual(@as(usize, 1), plans.count());
    try renderer.prepareRow(&term, placeholder);
    try testing.expectEqual(@as(usize, 2), plans.count());
    try testing.expectEqual(@as(usize, 1), plans.get(RowKey.init(placeholder)).?.slices.items.len);
    try testing.expect(!plans.contains(RowKey.init(unrequested)));
    try testing.expect(renderer.isRowDirty(anchor.*));
    try testing.expect(renderer.isRowDirty(placeholder));
    try testing.expect(!renderer.isRowDirty(active));

    screen.pages.clearDirty();
    try renderer.prepare(&term, 1, 1, true, null);
    try renderer.prepareRow(&term, placeholder);
    try testing.expect(!renderer.isRowDirty(anchor.*));
    storage.images.getPtr(1).?.generation += 1;
    try renderer.prepare(&term, 1, 1, true, null);
    try renderer.prepareRow(&term, placeholder);
    try testing.expect(renderer.isRowDirty(anchor.*));
    try testing.expect(!renderer.isRowDirty(placeholder));
    try testing.expect(!anchor.isDirty());

    anchor.x = 3;
    try renderer.prepare(&term, 1, 1, true, null);
    try renderer.prepareRow(&term, placeholder);
    try testing.expect(renderer.isRowDirty(anchor.*));
    try testing.expect(!anchor.isDirty());

    try renderer.prepare(&term, 1, 1, false, null);
    try renderer.prepareRow(&term, placeholder);
    try testing.expect(renderer.isRowDirty(anchor.*));
    try testing.expect(renderer.isRowDirty(placeholder));
    try testing.expect(!anchor.isDirty());
    try renderer.prepare(&term, 1, 1, false, null);
    try testing.expect(!renderer.isRowDirty(anchor.*));
    try testing.expect(!renderer.isRowDirty(placeholder));
}

test "reported-to-display scaling uses independent axes and refreshed cell metrics" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try gt.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 5 });
    defer term.deinit(alloc);
    term.width_px = 160;
    term.height_px = 60;
    var renderer: Self = .{
        .alloc = alloc,
        .frames = .{ .{ .arena = .init(alloc) }, .{ .arena = .init(alloc) } },
    };
    defer renderer.deinit();

    try renderer.prepare(&term, 4, 3, false, null);
    try testing.expectEqual(@as(i64, 4), renderer.scaleX(8));
    try testing.expectEqual(@as(i64, 3), renderer.scaleY(12));
    try testing.expectEqual(@as(i64, 2), renderer.scaleX(3));
    try testing.expectEqual(@as(i64, 1), renderer.scaleY(3));
    try testing.expectEqual(@as(i64, 0), renderer.scaleY(0));

    term.width_px = 320;
    term.height_px = 120;
    try renderer.prepare(&term, 4, 3, false, null);
    try testing.expectEqual(@as(i64, 4), renderer.scaleX(16));
    try testing.expectEqual(@as(i64, 3), renderer.scaleY(24));
}

test "pin-relative offsets clip above retained rows without shifting image sampling" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try gt.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 5 });
    defer term.deinit(alloc);
    term.width_px = 40;
    term.height_px = 15;
    var renderer: Self = .{
        .alloc = alloc,
        .frames = .{ .{ .arena = .init(alloc) }, .{ .arena = .init(alloc) } },
        .display_cell_width = 2,
        .display_cell_height = 3,
        .reported_cell_width = 2,
        .reported_cell_height = 3,
    };
    defer renderer.deinit();
    const frame = &renderer.frames[0];
    const image: gt.kitty.graphics.Image = .{ .id = 1, .width = 1, .height = 1 };
    const top = term.screens.active.pages.getTopLeft(.screen);
    var anchor = top.down(1).?;
    anchor.x = 4;
    const placement: Storage.Placement = .{
        .location = .{ .pin = &anchor },
        .columns = 4,
        .rows = 5,
        .x_offset = 1,
        .y_offset = 1,
    };
    const key: Storage.PlacementKey = .{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    };
    try renderer.addPinned(frame, &term, key, placement, &image, anchor, -5, -2);
    try testing.expectEqual(@as(usize, 4), frame.rows.count());
    for (0..4) |i| {
        const plan = frame.rows.get(RowKey.init(top.down(i).?)).?;
        try testing.expectEqual(@as(usize, 1), plan.slices.items.len);
        const dest = plan.slices.items[0].dest;
        try testing.expectEqual(@as(i64, -1), dest.x);
        try testing.expectEqual(-2 - @as(i64, @intCast(i)) * 3, dest.y);
        try testing.expectEqual(@as(u32, 7), dest.width);
        try testing.expectEqual(@as(u32, 14), dest.height);
    }
    frame.clear();
    try renderer.addPinned(frame, &term, key, placement, &image, anchor, 0, -100);
    try renderer.addPinned(frame, &term, key, placement, &image, anchor, 0, std.math.maxInt(i32));
    anchor.garbage = true;
    try renderer.addPinned(frame, &term, key, placement, &image, anchor, 0, 0);
    try testing.expectEqual(@as(usize, 0), frame.rows.count());
}

test "pinned placements with empty sources or rounded destinations create no slices" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try gt.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 5 });
    defer term.deinit(alloc);
    term.width_px = 640;
    term.height_px = 160;
    var renderer: Self = .{
        .alloc = alloc,
        .frames = .{ .{ .arena = .init(alloc) }, .{ .arena = .init(alloc) } },
        .display_cell_width = 1,
        .display_cell_height = 1,
        .reported_cell_width = 32,
        .reported_cell_height = 32,
    };
    defer renderer.deinit();
    const frame = &renderer.frames[0];
    const image: gt.kitty.graphics.Image = .{ .id = 1, .width = 1, .height = 1 };
    var anchor = term.screens.active.pages.getTopLeft(.screen);
    const key: Storage.PlacementKey = .{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    };
    for ([_]Storage.Placement{
        .{ .location = .{ .pin = &anchor } },
        .{ .location = .{ .pin = &anchor }, .source_x = 1, .columns = 1, .rows = 1 },
        .{ .location = .{ .pin = &anchor }, .source_y = 1, .columns = 1, .rows = 1 },
    }) |placement| {
        try renderer.addPinned(frame, &term, key, placement, &image, anchor, 0, 0);
        try testing.expectEqual(@as(usize, 0), frame.rows.count());
    }
}

test "pinned row slices walk across page boundaries and stop at the retained end" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try gt.Terminal.init(testing.io, alloc, .{ .cols = 80, .rows = 1000 });
    defer term.deinit(alloc);
    term.width_px = 80;
    term.height_px = 1000;
    var renderer: Self = .{
        .alloc = alloc,
        .frames = .{ .{ .arena = .init(alloc) }, .{ .arena = .init(alloc) } },
    };
    defer renderer.deinit();
    const frame = &renderer.frames[0];
    const first = term.screens.active.pages.getTopLeft(.screen);
    try testing.expect(first.node.next != null);
    var anchor = first.down(first.node.rows() - 2).?;
    const placement: Storage.Placement = .{
        .location = .{ .pin = &anchor },
        .columns = 2,
        .rows = 4,
    };
    const image: gt.kitty.graphics.Image = .{ .id = 1, .width = 1, .height = 1 };
    const key: Storage.PlacementKey = .{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    };
    try renderer.addPinned(frame, &term, key, placement, &image, anchor, 0, 0);
    try testing.expectEqual(@as(usize, 4), frame.rows.count());
    for (0..4) |i| {
        const pin = anchor.down(i).?;
        const plan = frame.rows.get(RowKey.init(pin)).?;
        try testing.expectEqual(-@as(i64, @intCast(i)), plan.slices.items[0].dest.y);
    }
    frame.clear();
    anchor = first.down(999).?;
    try renderer.addPinned(frame, &term, key, placement, &image, anchor, 0, 0);
    try testing.expectEqual(@as(usize, 1), frame.rows.count());
}
