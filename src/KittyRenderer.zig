//! Kitty placement layout and lazy, row-local image composition.
//! No Lisp values survive a module call here: Emacs owns the image cache.
const std = @import("std");
const gt = @import("ghostty-vt");
const emacs = @import("emacs.zig");
const pixels = @import("image_composition.zig");
const png = @import("png.zig");
const ppm = @import("ppm.zig");
const style_face = @import("style_face.zig");
const Self = @This();
const Allocator = std.mem.Allocator;
const Storage = gt.kitty.graphics.ImageStorage;

alloc: Allocator,
frames: [2]Frame,
current: u1 = 0,
options: Options = .{},
canvas: std.ArrayList(u8) = .empty,
visible: std.ArrayList(u8) = .empty,
resize_scratch: pixels.Scratch = .{},

// Clear everything on overflow. Buffer properties retain any images still shown.
const cache_limit = 256;

pub const Format = union(enum) {
    none,
    png,
    ppm: gt.color.RGB,
};

/// Physical cell geometry derived from ghostel--set-size's logical dimensions
/// and pixel_scale. Planning and composition use physical pixels; only Emacs
/// image descriptors and display slices use logical pixels.
pub const Options = struct {
    cell_width: u32 = 1,
    cell_height: u32 = 1,
    pixel_scale: u32 = 1,
    /// Row gap in physical pixels. Included in cell layout height, but excluded
    /// from the row bitmap and visibility testing because Emacs adds the gap
    /// when displaying each row.
    line_spacing: u32 = 0,
    image_ascent_percent: ?u8 = null,
    format: Format = .none,
};

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
    /// Null until a query finalizes this indexed row.
    raster_key: ?[]const u8 = null,
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

/// Image and logical slice dimensions borrowed by the text renderer.
pub const Row = struct {
    const Span = struct { start_col: u32, end_col: u32, display: emacs.Value };

    first_col: u32,
    image: emacs.Value,
    mask: []const u8,
    cell_width: u32,
    image_height: u32,

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
                self.row.image_height,
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

pub fn prepare(
    self: *Self,
    env: emacs.Env,
    term: *gt.Terminal,
    logical_cell_width: u32,
    logical_cell_height: u32,
    pixel_scale: u32,
    font_ascent: ?u32,
) !void {
    const has_images = term.screens.active.kitty_images.placements.count() > 0;
    self.options = .{
        .pixel_scale = pixel_scale,
        .cell_width = try std.math.mul(u32, logical_cell_width, pixel_scale),
        .cell_height = try std.math.mul(u32, logical_cell_height, pixel_scale),
    };
    if (has_images and env.isNotNil(env.f("display-graphic-p", .{}))) {
        if (env.isNotNil(env.f("image-type-available-p", .{emacs.sym.png}))) {
            self.options.format = .png;
        } else if (env.isNotNil(env.f("image-type-available-p", .{emacs.sym.pbm}))) {
            self.options.format = .{ .ppm = try style_face.getGhostelDefaultColor(env, ":background") };
        }
        if (self.options.format != .none) {
            const spacing = std.math.cast(u32, env.cast(i64, env.f("ghostel--line-spacing-pixels", .{}))) orelse
                return error.OutOfRange;
            self.options.line_spacing = try std.math.mul(u32, spacing, pixel_scale);
            if (font_ascent) |ascent| {
                self.options.image_ascent_percent = imageAscentPercent(self.imageHeight() / pixel_scale, ascent);
            }
        }
    }
    try env.checkNonLocalExit();
    const next = &self.frames[self.current ^ 1];
    next.clear();
    std.debug.assert(pixel_scale > 0 and self.options.cell_width > 0 and self.options.cell_height > 0);
    if (self.options.format != .none) try self.preparePinned(next, term);

    self.current ^= 1;
}

pub fn isRowDirty(self: *Self, term: *gt.Terminal, pin: gt.Pin) !bool {
    const new_plan = try self.getPlan(term, pin);
    const old_plan = self.frames[self.current ^ 1].rows.get(RowKey.init(pin));
    if (old_plan == null or new_plan == null) return old_plan != null or new_plan != null;
    const before = old_plan.?.raster_key orelse return true;
    const after = new_plan.?.raster_key.?;
    return old_plan.?.first_col != new_plan.?.first_col or !std.mem.eql(u8, before, after);
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

fn getPlan(self: *Self, term: *gt.Terminal, pin: gt.Pin) !?*Plan {
    if (self.options.format == .none) return null;
    const frame = &self.frames[self.current];
    const key = RowKey.init(pin);
    var plan = frame.rows.getPtr(key);
    if (plan) |p| {
        if (p.raster_key != null) return p;
    }

    if (pin.rowAndCell().row.kitty_virtual_placeholder) {
        const storage = &term.screens.active.kitty_images;
        var placeholders = PlaceholderIterator.init(pin);
        while (placeholders.next()) |run| {
            const image = storage.images.getPtr(run.image_id) orelse continue;
            if (image.renderData().isPending()) continue;
            const target = storage.placeholderTarget(run.image_id, run.placement_id) orelse continue;
            if (target.placement.location != .virtual) continue;
            try self.addVirtual(frame, run, target.key, target.placement, image);
        }
        // Adding a row can grow the map and invalidate the earlier pointer.
        plan = frame.rows.getPtr(key);
    }

    if (plan) |p| try self.finishPlan(frame.arena.allocator(), pin, p);
    return plan;
}

fn imageHeight(self: *const Self) u32 {
    return @max(self.options.pixel_scale, self.options.cell_height -| self.options.line_spacing);
}

fn imageAscentPercent(height: u32, ascent: u32) ?u8 {
    if (height == 0 or ascent > height) return null;

    // W32 Emacs can round `center` a pixel away from the text baseline,
    // growing the row. Use an exact integer percentage if Emacs can represent
    // it, testing the next percentage too in case floating-point rounding
    // makes its truncation undershoot.
    const first: u32 = @intCast((@as(u64, ascent) * 100 + height - 1) / height);
    for (first..@min(first + 2, 101)) |percent| {
        const pixels_up: u32 = @intFromFloat(@as(f64, @floatFromInt(height)) *
            (@as(f64, @floatFromInt(percent)) / 100.0));
        if (pixels_up == ascent) return @intCast(percent);
    }
    return null;
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
    // Without an explicit grid, round up to whole physical-size cells.
    const grid_cols = if (target.columns > 0)
        target.columns
    else
        (source_rect.width - 1) / self.options.cell_width + 1;
    const grid_rows = if (target.rows > 0)
        target.rows
    else
        (source_rect.height - 1) / self.options.cell_height + 1;
    if (run.col >= grid_cols or run.row >= grid_rows) return;

    const grid_width = std.math.mul(u32, grid_cols, self.options.cell_width) catch return;
    const grid_height = std.math.mul(u32, grid_rows, self.options.cell_height) catch return;
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
    // Padding centers the fitted image within the grid, in physical pixels.
    const letterbox_x = (grid_width - fitted_width) / 2;
    const letterbox_y = (grid_height - fitted_height) / 2;
    const run_width_cells = @min(run.width, grid_cols - run.col);
    // clip and dest use physical pixels relative to the terminal row's top-left.
    const clip: pixels.Destination = .{
        .x = @as(i64, run.pin.x) * self.options.cell_width,
        .y = 0,
        .width = try std.math.mul(u32, run_width_cells, self.options.cell_width),
        .height = self.options.cell_height,
    };
    // Subtract the run's position within the placement grid to locate the full
    // grid's origin, then add the padding to locate the image within that grid.
    const dest: pixels.Destination = .{
        .x = clip.x - @as(i64, run.col) * self.options.cell_width + letterbox_x,
        .y = -@as(i64, run.row) * self.options.cell_height + letterbox_y,
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
    const y_from_anchor_px = @as(i64, offset_cells_v) * self.options.cell_height + cell_offset.y;
    const first_row_offset = @divFloor(y_from_anchor_px, self.options.cell_height);

    const col = @as(i64, anchor_pin.x) + offset_cells_h;
    // Retained rows can be wider than the anchor row, but none can contain
    // this column. The bound also keeps the following pixel arithmetic in i64.
    if (col >= std.math.maxInt(gt.size.CellCountInt)) return;
    // The full image's y is relative to the current row; its dimensions stay
    // fixed as we walk rows.
    var dest: pixels.Destination = .{
        .x = col * self.options.cell_width + cell_offset.x,
        .y = @mod(y_from_anchor_px, self.options.cell_height),
        .width = pixel_size.width,
        .height = pixel_size.height,
    };
    const first_row_pin = if (first_row_offset >= 0)
        anchor_pin.down(@intCast(first_row_offset)) orelse return
    else switch (anchor_pin.upOverflow(@intCast(-first_row_offset))) {
        .offset => |pin| pin,
        .overflow => |overflow| clipped: {
            // The first image row predates retained history. Begin at the oldest
            // retained row, with the image shifted up by the missing row count.
            const clipped_rows = @as(i64, @intCast(overflow.remaining));
            dest.y -= clipped_rows * self.options.cell_height;
            break :clipped overflow.end;
        },
    };
    var rows = first_row_pin.rowIterator(.right_down, null);
    while (dest.y + dest.height > 0) : (dest.y -= self.options.cell_height) {
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
    const row_width = @as(i64, pin.node.cols()) * self.options.cell_width;
    const left = if (clip) |c| @max(dest.x, c.x) else dest.x;
    const right = if (clip) |c| @min(dest.x + dest.width, c.x + c.width) else dest.x + dest.width;
    const top = if (clip) |c| @max(dest.y, c.y) else dest.y;
    const bottom = if (clip) |c| @min(dest.y + dest.height, c.y + c.height) else dest.y + dest.height;
    if (@max(0, left) >= @min(row_width, right) or
        @max(0, top) >= @min(self.options.cell_height, bottom)) return;
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
    var left: i64 = @as(i64, row_cols) * self.options.cell_width;
    var right: i64 = 0;
    for (plan.slices.items) |slice| {
        const x0 = if (slice.clip) |c| @max(slice.dest.x, c.x) else slice.dest.x;
        const x1 = if (slice.clip) |c|
            @min(slice.dest.x + slice.dest.width, c.x + c.width)
        else
            slice.dest.x + slice.dest.width;
        left = @min(left, @max(0, x0));
        right = @max(right, @min(@as(i64, row_cols) * self.options.cell_width, x1));
    }
    plan.first_col = @intCast(@divFloor(left, self.options.cell_width));
    plan.end_col = @intCast(@divFloor(
        right + self.options.cell_width - 1,
        self.options.cell_width,
    ));

    // Include both cells when an image edge intersects a wide character.
    const cells = pin.node.page().getCells(pin.rowAndCell().row);
    if (cells[plan.first_col].wide == .spacer_tail and plan.first_col > 0) plan.first_col -= 1;
    if (cells[plan.end_col - 1].wide == .wide and plan.end_col < cells.len) plan.end_col += 1;

    var key: std.ArrayList(u8) = .empty;
    try appendKey(alloc, &key, self.options);
    try appendKey(alloc, &key, plan.end_col - plan.first_col);
    const canvas_x = @as(i64, plan.first_col) * self.options.cell_width;
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
        .@"union" => {
            try appendKey(alloc, key, @backingInt(std.meta.activeTag(value)));
            switch (value) {
                inline else => |payload| try appendKey(alloc, key, payload),
            }
        },
        .bool => try appendKey(alloc, key, @intFromBool(value)),
        .void => {},
        .optional => {
            try appendKey(alloc, key, @intFromBool(value != null));
            if (value) |present| try appendKey(alloc, key, present);
        },
        .int => |info| {
            const byte_count = (info.bits + 7) / 8;
            const Stored = @Int(info.signedness, byte_count * 8);
            var bytes: [byte_count]u8 = undefined;
            std.mem.writeInt(Stored, &bytes, value, .little);
            try key.appendSlice(alloc, &bytes);
        },
        else => @compileError("Unsupported cache key value type"),
    }
}

/// Return the image spans to display in pin's row, or null if there are none.
/// The returned mask is valid until the next getRow call. Image handles are
/// valid only during the current module call.
pub fn getRow(self: *Self, env: emacs.Env, term: *gt.Terminal, pin: gt.Pin) !?Row {
    const plan = (try self.getPlan(term, pin)) orelse return null;
    const cache = env.symbolValue("ghostel--kitty-image-cache");
    const key = env.makeUnibyteString(plan.raster_key.?);
    var raster = env.f("gethash", .{ key, cache });
    try env.checkNonLocalExit();
    if (env.isNil(raster)) {
        raster = self.makeRaster(env, term, plan.*) catch |err| switch (err) {
            // Cache an omitted raster so excessive geometry cannot block text.
            error.ImageTooLarge => env.f("vector", .{ env.nil(), env.nil() }),
            else => return err,
        };
        if (env.cast(usize, env.f("hash-table-count", .{cache})) >= cache_limit)
            _ = env.f("clrhash", .{cache});
        _ = env.f("puthash", .{ key, raster, cache });
        try env.checkNonLocalExit();
    }
    return self.layoutRow(env, pin, plan.*, raster);
}

/// Cache one image and its pre-layout visibility mask, both owned by Emacs.
fn makeRaster(self: *Self, env: emacs.Env, term: *gt.Terminal, plan: Plan) !emacs.Value {
    const cols = plan.end_col - plan.first_col;
    const cell_width = self.options.cell_width;
    const height = self.imageHeight();
    const width = std.math.mul(u32, cols, cell_width) catch return error.ImageTooLarge;
    const canvas_x = @as(i64, plan.first_col) * cell_width;
    try self.canvas.resize(self.alloc, pixels.byteLength(width, height) catch return error.ImageTooLarge);
    const canvas = self.canvas.items;
    @memset(canvas, 0);
    for (plan.slices.items) |slice| {
        self.drawSlice(term, canvas, width, height, canvas_x, slice) catch |err| switch (err) {
            // Retain other layers and text when this layer exceeds the bounded
            // resampling budget. Allocation failures still propagate normally.
            error.ImageTooLarge => continue,
            else => return err,
        };
    }
    try self.visible.resize(self.alloc, cols + 1);
    const visible = self.visible.items[0..cols];
    for (visible, 0..) |*value, col| {
        value.* = @intFromBool(pixels.cellVisible(canvas, width, height, cell_width, @intCast(col)));
    }
    if (std.mem.indexOfScalar(u8, visible, 1) == null) {
        return env.f("vector", .{ env.nil(), env.nil() });
    }
    const mask = env.makeUnibyteString(visible);
    const image = try self.createImage(env, canvas, width, height);
    return env.f("vector", .{ image, mask });
}

/// Encode a premultiplied row and return its Lisp-owned image descriptor.
fn createImage(self: *Self, env: emacs.Env, canvas: []u8, width: u32, height: u32) !emacs.Value {
    const data = switch (self.options.format) {
        .none => unreachable,
        .png => png_data: {
            pixels.unpremultiply(canvas);
            break :png_data try png.encode(self.alloc, canvas, width, height, width * 4);
        },
        .ppm => |background| try ppm.encode(self.alloc, canvas, width, height, .{
            background.r, background.g, background.b,
        }),
    };
    defer self.alloc.free(data);
    const bytes = env.makeUnibyteString(data);
    const ascent = if (self.options.image_ascent_percent) |percent|
        env.makeValue(percent)
    else
        env.makeValue(emacs.sym.center);
    const image = env.f("create-image", .{
        bytes,
        switch (self.options.format) {
            .none => unreachable,
            .png => emacs.sym.png,
            .ppm => emacs.sym.pbm,
        },
        env.t(),
        emacs.sym.@":scale",
        1.0 / @as(f64, @floatFromInt(self.options.pixel_scale)),
        emacs.sym.@":ascent",
        ascent,
    });
    try env.checkNonLocalExit();
    if (env.isNil(image)) return error.ImageCreationFailed;
    return image;
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
        .cell_width = self.options.cell_width / self.options.pixel_scale,
        .image_height = self.imageHeight() / self.options.pixel_scale,
    };
}

fn drawSlice(
    self: *Self,
    term: *gt.Terminal,
    canvas: []u8,
    width: u32,
    height: u32,
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
        height,
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

test "image ascent reproduces the text baseline when representable" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(@as(?u8, 80), imageAscentPercent(25, 20));
    try expectEqual(@as(?u8, 79), imageAscentPercent(33, 26));
    try expectEqual(@as(?u8, 59), imageAscentPercent(50, 29));
    try expectEqual(@as(?u8, 100), imageAscentPercent(25, 25));
    try expectEqual(null, imageAscentPercent(200, 151));
    try expectEqual(null, imageAscentPercent(25, 26));
}

test "raster keys distinguish output options, image changes, geometry, and clipping" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try gt.Terminal.init(testing.io, alloc, .{ .cols = 32, .rows = 1 });
    defer term.deinit(alloc);
    const pin = term.screens.active.pages.getTopLeft(.screen);
    const Input = struct { options: Options, slice: Slice };
    const original: Input = .{
        .options = .{
            .cell_width = 2,
            .cell_height = 4,
            .format = .{ .ppm = .{ .r = 1, .g = 2, .b = 3 } },
        },
        .slice = .{
            .image_id = 1,
            .generation = 2,
            .placement_id = 99,
            .z = -3,
            .source = .{ .x = 4, .y = 5, .width = 6, .height = 7 },
            .dest = .{ .x = 0, .y = -1, .width = 10, .height = 6 },
            .clip = .{ .x = 2, .y = 0, .width = 4, .height = 3 },
        },
    };
    var renderer: Self = .{
        .alloc = alloc,
        .options = original.options,
        .frames = .{ .{ .arena = .init(alloc) }, .{ .arena = .init(alloc) } },
    };
    defer renderer.deinit();
    const arena = renderer.frames[0].arena.allocator();
    var overlap = original.slice;
    overlap.image_id = 9;
    overlap.z = -2;
    var baseline: Plan = .{};
    try baseline.slices.appendSlice(arena, &.{ original.slice, overlap });
    try renderer.finishPlan(arena, pin, &baseline);

    var variants: [14]Input = @splat(original);
    variants[0].slice.image_id += 1;
    variants[1].slice.generation += 1;
    // Move past the other layer to change compositing order.
    variants[2].slice.z += 2;
    variants[3].slice.source.x += 1;
    variants[4].slice.dest.y += 1;
    variants[5].slice.clip.?.width += 1;
    variants[6].slice.clip = null;
    variants[7].options.cell_width += 1;
    variants[8].options.cell_height += 1;
    variants[9].options.pixel_scale += 1;
    variants[10].options.format = .png;
    variants[11].options.format.ppm.b += 1;
    variants[12].options.line_spacing += 1;
    variants[13].options.image_ascent_percent = 75;
    for (variants) |variant| {
        renderer.options = variant.options;
        var plan: Plan = .{};
        try plan.slices.appendSlice(arena, &.{ variant.slice, overlap });
        try renderer.finishPlan(arena, pin, &plan);
        try testing.expect(!std.mem.eql(u8, baseline.raster_key.?, plan.raster_key.?));
    }
}

test "cache keys use compact fields and preserve full integer ranges" {
    const testing = std.testing;
    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(testing.allocator);
    try appendKey(testing.allocator, &key, true);
    try appendKey(testing.allocator, &key, Format{ .ppm = .{ .r = 255, .g = 0, .b = 128 } });
    try appendKey(testing.allocator, &key, @as(u32, std.math.maxInt(u32)));
    try appendKey(testing.allocator, &key, @as(i32, std.math.minInt(i32)));
    try appendKey(testing.allocator, &key, @as(u64, std.math.maxInt(u64)));
    try appendKey(testing.allocator, &key, @as(i64, std.math.minInt(i64)));
    try testing.expectEqual(@as(usize, 29), key.items.len);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 255, 0, 128 }, key.items[0..5]);
    try testing.expectEqual(std.math.maxInt(u32), std.mem.readInt(u32, key.items[5..9], .little));
    try testing.expectEqual(std.math.minInt(i32), std.mem.readInt(i32, key.items[9..13], .little));
    try testing.expectEqual(std.math.maxInt(u64), std.mem.readInt(u64, key.items[13..21], .little));
    try testing.expectEqual(std.math.minInt(i64), std.mem.readInt(i64, key.items[21..29], .little));
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
        try renderer.drawSlice(&term, &canvas, 1, 1, case.canvas_x, .{
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

test "physical clipping and row offsets preserve source pixels" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try gt.Terminal.init(testing.io, alloc, .{
        .cols = 4,
        .rows = 5,
        .kitty_image_storage_limit = 1000,
    });
    defer term.deinit(alloc);
    var source: [4 * 4 * 4]u8 = undefined;
    for (0..4) |y| {
        for (0..4) |x| {
            @memcpy(source[(y * 4 + x) * 4 ..][0..4], &[_]u8{ @intCast(x * 60), @intCast(y * 60), 0, 255 });
        }
    }
    const screen = term.screens.active;
    try screen.kitty_images.addImage(testing.io, alloc, screen, .{
        .id = 1,
        .width = 4,
        .height = 4,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, &source) },
    });
    var renderer: Self = .{
        .alloc = alloc,
        .frames = .{ .{ .arena = .init(alloc) }, .{ .arena = .init(alloc) } },
    };
    defer renderer.deinit();
    var canvas: [4 * 2 * 4]u8 = @splat(0);
    try renderer.drawSlice(&term, &canvas, 4, 2, 2, .{
        .image_id = 1,
        .generation = 0,
        .placement_id = 1,
        .source = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
        .dest = .{ .x = 2, .y = -2, .width = 4, .height = 4 },
        .clip = .{ .x = 4, .y = 0, .width = 2, .height = 2 },
        .z = 0,
    });
    for (0..2) |y| {
        try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), canvas[y * 16 ..][0..8]);
        try testing.expectEqualSlices(u8, source[((y + 2) * 4 + 2) * 4 ..][0..8], canvas[y * 16 + 8 ..][0..8]);
    }
    try testing.expect(!pixels.cellVisible(&canvas, 4, 2, 2, 0));
    try testing.expect(pixels.cellVisible(&canvas, 4, 2, 2, 1));
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

test "row queries finalize plans on demand and track image changes" {
    const testing = std.testing;
    const Frames = struct {
        fn advance(renderer: *Self, term: *gt.Terminal, format: Format) !void {
            renderer.options.format = format;
            const next = &renderer.frames[renderer.current ^ 1];
            next.clear();
            if (format != .none) try renderer.preparePinned(next, term);
            renderer.current ^= 1;
        }
    };
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
    try Frames.advance(&renderer, &term, .png);
    const plans = &renderer.frames[renderer.current].rows;
    try testing.expectEqual(@as(usize, 1), plans.count());
    try testing.expect(plans.get(RowKey.init(anchor.*)).?.raster_key == null);
    try testing.expect(!(try renderer.isRowDirty(&term, active)));
    try testing.expectEqual(@as(usize, 1), plans.count());
    try testing.expect(try renderer.isRowDirty(&term, placeholder));
    try testing.expect(try renderer.isRowDirty(&term, placeholder));
    try testing.expectEqual(@as(usize, 2), plans.count());
    try testing.expectEqual(@as(usize, 1), plans.get(RowKey.init(placeholder)).?.slices.items.len);
    try testing.expect(plans.get(RowKey.init(placeholder)).?.raster_key != null);
    try testing.expect(plans.get(RowKey.init(anchor.*)).?.raster_key == null);
    try testing.expect(!plans.contains(RowKey.init(unrequested)));
    try testing.expect(try renderer.isRowDirty(&term, anchor.*));
    try testing.expect(plans.get(RowKey.init(anchor.*)).?.raster_key != null);
    try testing.expect(try renderer.isRowDirty(&term, placeholder));
    try testing.expect(!(try renderer.isRowDirty(&term, active)));

    screen.pages.clearDirty();
    try Frames.advance(&renderer, &term, .png);
    try testing.expect(!(try renderer.isRowDirty(&term, anchor.*)));
    try testing.expect(!(try renderer.isRowDirty(&term, placeholder)));
    storage.images.getPtr(1).?.generation += 1;
    try Frames.advance(&renderer, &term, .png);
    try testing.expect(try renderer.isRowDirty(&term, anchor.*));
    try testing.expect(!(try renderer.isRowDirty(&term, placeholder)));
    try testing.expect(!anchor.isDirty());

    anchor.x = 3;
    try Frames.advance(&renderer, &term, .png);
    try testing.expect(try renderer.isRowDirty(&term, anchor.*));
    try testing.expect(!(try renderer.isRowDirty(&term, placeholder)));
    try testing.expect(!anchor.isDirty());

    try Frames.advance(&renderer, &term, .none);
    try testing.expect(try renderer.isRowDirty(&term, anchor.*));
    try testing.expect(try renderer.isRowDirty(&term, placeholder));
    try testing.expect(!anchor.isDirty());
    try Frames.advance(&renderer, &term, .none);
    try testing.expect(!(try renderer.isRowDirty(&term, anchor.*)));
    try testing.expect(!(try renderer.isRowDirty(&term, placeholder)));

    try Frames.advance(&renderer, &term, .png);
    const deleted_row = anchor.*;
    try testing.expect(renderer.frames[renderer.current].rows.get(RowKey.init(deleted_row)).?.raster_key == null);
    storage.delete(testing.io, alloc, &term, .{ .id = .{ .image_id = 1, .placement_id = 1, .delete = true } });
    try Frames.advance(&renderer, &term, .png);
    try testing.expect(try renderer.isRowDirty(&term, deleted_row));
}

test "pinned images retain physical subcell sizes and offsets" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try gt.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 5 });
    defer term.deinit(alloc);
    var renderer: Self = .{
        .alloc = alloc,
        .frames = .{ .{ .arena = .init(alloc) }, .{ .arena = .init(alloc) } },
    };
    defer renderer.deinit();
    var anchor = term.screens.active.pages.getTopLeft(.screen);
    const image: gt.kitty.graphics.Image = .{ .id = 1, .width = 1, .height = 1 };
    const placement: Storage.Placement = .{
        .location = .{ .pin = &anchor },
        .x_offset = 1,
        .y_offset = 1,
    };
    const key: Storage.PlacementKey = .{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    };
    for ([_]u32{ 2, 3 }) |scale| {
        term.width_px = term.cols * scale;
        term.height_px = term.rows * scale;
        renderer.options = .{ .cell_width = scale, .cell_height = scale, .pixel_scale = scale };
        const frame = &renderer.frames[0];
        frame.clear();
        try renderer.addPinned(frame, &term, key, placement, &image, anchor, 0, 0);
        const plan = frame.rows.getPtr(RowKey.init(anchor)).?;
        try testing.expectEqualDeep(pixels.Destination{ .x = 1, .y = 1, .width = 1, .height = 1 }, plan.slices.items[0].dest);
        try renderer.finishPlan(frame.arena.allocator(), anchor, plan);
        try testing.expectEqual(@as(u32, 0), plan.first_col);
        try testing.expectEqual(@as(u32, 1), plan.end_col);
    }
}

test "virtual fragments preserve physical letterbox dimensions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try gt.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 5 });
    defer term.deinit(alloc);
    var renderer: Self = .{
        .alloc = alloc,
        .frames = .{ .{ .arena = .init(alloc) }, .{ .arena = .init(alloc) } },
    };
    defer renderer.deinit();
    var pin = term.screens.active.pages.getTopLeft(.screen);
    pin.x = 3;
    const image: gt.kitty.graphics.Image = .{ .id = 1, .width = 3, .height = 2 };
    const key: Storage.PlacementKey = .{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    };
    for ([_]u32{ 2, 3 }) |scale| {
        renderer.options = .{ .cell_width = scale, .cell_height = scale, .pixel_scale = scale };
        const frame = &renderer.frames[0];
        frame.clear();
        try renderer.addVirtual(frame, .{
            .pin = pin,
            .image_id = 1,
            .placement_id = 1,
            .col = 1,
            .row = 0,
            .width = 1,
            .height = 1,
        }, key, .{ .location = .virtual, .columns = 2, .rows = 1 }, &image);
        const slice = frame.rows.get(RowKey.init(pin)).?.slices.items[0];
        try testing.expectEqualDeep(pixels.Destination{
            .x = 2 * scale,
            .y = 0,
            .width = (3 * scale + 1) / 2,
            .height = scale,
        }, slice.dest);
        try testing.expectEqualDeep(pixels.Destination{
            .x = 3 * scale,
            .y = 0,
            .width = scale,
            .height = scale,
        }, slice.clip.?);
    }
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
        .options = .{ .cell_width = 2, .cell_height = 3 },
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
    try renderer.addPinned(frame, &term, key, placement, &image, anchor, std.math.maxInt(i32), 0);
    anchor.garbage = true;
    try renderer.addPinned(frame, &term, key, placement, &image, anchor, 0, 0);
    try testing.expectEqual(@as(usize, 0), frame.rows.count());
}

test "pinned placements with empty source crops create no slices" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try gt.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 5 });
    defer term.deinit(alloc);
    term.width_px = 640;
    term.height_px = 160;
    var renderer: Self = .{
        .alloc = alloc,
        .frames = .{ .{ .arena = .init(alloc) }, .{ .arena = .init(alloc) } },
        .options = .{ .cell_width = 32, .cell_height = 32, .pixel_scale = 32 },
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
