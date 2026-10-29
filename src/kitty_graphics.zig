/// Kitty Graphics Protocol support via libghostty-vt.
///
/// Queries libghostty's authoritative placement and image state during
/// each redraw cycle, converts pixel data to PPM for Emacs display,
/// and calls into Elisp to apply image overlays.
const std = @import("std");
const Allocator = std.mem.Allocator;
const emacs = @import("emacs.zig");
const GhostelTerm = @import("GhostelTerm.zig");
const gt = @import("ghostty-vt");
const png = @import("png.zig");
const ppm = @import("ppm.zig");

/// Query all visible kitty graphics placements from libghostty and
/// emit them to Elisp during redraw.
pub fn emitPlacements(env: emacs.Env, term: *GhostelTerm) !void {
    const storage = &term.terminal.screens.active.kitty_images;
    var iterator = storage.placements.iterator();
    // Iterate over all placements. Per-placement errors skip that placement only.
    while (iterator.next()) |entry| {
        emitOnePlacement(
            env,
            term,
            storage,
            entry.key_ptr,
            entry.value_ptr,
        ) catch continue;
    }
    emitVirtualRuns(env, term, storage);
}

const PlacementIterator = struct {
    row_it: gt.PageList.RowIterator,
    row: ?gt.Pin,

    const Run = struct {
        placement: gt.kitty.graphics.unicode.IncompletePlacement,
        pin: gt.Pin,

        fn complete(self: Run) gt.kitty.graphics.unicode.Placement {
            return .{
                .pin = self.pin,
                .image_id = self.placement.imageId(),
                .placement_id = self.placement.placement_id orelse 0,
                .col = self.placement.col orelse 0,
                .row = self.placement.row orelse 0,
                .width = self.placement.width,
                .height = 1,
            };
        }
    };

    fn init(pin: gt.Pin, limit: ?gt.Pin) PlacementIterator {
        var row_it = pin.rowIterator(.right_down, limit);
        const row = row_it.next();
        return .{ .row_it = row_it, .row = row };
    }

    fn next(self: *PlacementIterator) ?gt.kitty.graphics.unicode.Placement {
        while (self.row) |*row| {
            if (!row.rowAndCell().row.kitty_virtual_placeholder) {
                self.row = self.row_it.next();
                continue;
            }

            var run: ?Run = null;
            const cells = row.cells(.right);
            for (cells, row.x..) |*cell, x| {
                row.x = @intCast(x);

                if (cell.codepoint() != gt.kitty.graphics.unicode.placeholder) {
                    if (run) |prev| return prev.complete();
                    continue;
                }

                const style = row.style(cell);
                const placement = gt.kitty.graphics.unicode.IncompletePlacement.init(
                    &style,
                    row.grapheme(cell) orelse &.{},
                );
                if (run) |*prev| {
                    if (!prev.placement.append(&placement)) return prev.complete();
                } else {
                    run = .{ .placement = placement.start(), .pin = row.* };
                }
            }

            self.row = self.row_it.next();
            if (run) |prev| return prev.complete();
        }

        return null;
    }
};

fn placementIterator(pin: gt.Pin, limit: ?gt.Pin) PlacementIterator {
    return .init(pin, limit);
}

/// Emit one Elisp call per unicode placeholder run from the row this
/// redraw's render started at down to the last active row, covering rows
/// that left the active area since the previous redraw.
fn emitVirtualRuns(env: emacs.Env, term: *GhostelTerm, storage: *const gt.kitty.graphics.ImageStorage) void {
    if (storage.placements.count() == 0) return;
    const pages = &term.terminal.screens.active.pages;
    const top = term.renderer.rendered_from orelse return;
    const bottom = pages.getBottomRight(.active) orelse return;
    const bottom_y = (pages.pointFromPin(.screen, bottom) orelse return).screen.y;
    var it = placementIterator(top, bottom);
    // Image data handed to Emacs, per image id, for this redraw only.
    var images: std.AutoHashMapUnmanaged(u32, emacs.Value) = .empty;
    defer images.deinit(term.alloc);
    // Per-run errors skip that run only.
    while (it.next()) |run| {
        emitVirtualRun(env, term, storage, &run, bottom_y, &images) catch continue;
    }
}

fn emitVirtualRun(
    env: emacs.Env,
    term: *GhostelTerm,
    storage: *const gt.kitty.graphics.ImageStorage,
    run: *const gt.kitty.graphics.unicode.Placement,
    bottom_y: u32,
    images: *std.AutoHashMapUnmanaged(u32, emacs.Value),
) !void {
    const image = storage.images.getPtr(run.image_id) orelse return error.ImageNotFound;
    const target = storage.placeholderTarget(run.image_id, run.placement_id) orelse return error.PlacementNotFound;
    if (target.placement.location != .virtual) return error.PlacementNotFound;

    const t = &term.terminal;
    const grid_cols = if (target.placement.columns > 0) target.placement.columns else try cellsFor(image.width, t.width_px, t.cols);
    const grid_rows = if (target.placement.rows > 0) target.placement.rows else try cellsFor(image.height, t.height_px, t.rows);

    // Elisp locates the run by counting placeholders on its row.
    var ordinal: u32 = 0;
    for (run.pin.cells(.left)[0..run.pin.x]) |*cell| {
        if (cell.codepoint() == gt.kitty.graphics.unicode.placeholder) ordinal += 1;
    }
    const pin_screen = t.screens.active.pages.pointFromPin(.screen, run.pin) orelse return error.NotVisible;

    const val = images.get(run.image_id) orelse val: {
        const data = try getImageData(term.alloc, image, ppm.Rect.full(image.width, image.height));
        defer term.alloc.free(data);
        const v = env.makeUnibyteString(data) orelse return error.MakeString;
        try images.put(term.alloc, run.image_id, v);
        break :val v;
    };
    _ = env.f("ghostel--kitty-display-virtual", .{
        val,
        bottom_y - pin_screen.screen.y,
        ordinal,
        run.row,
        run.col,
        run.width,
        grid_cols,
        grid_rows,
    });
}

/// Cells covering `px` pixels at the terminal's cell pitch.
fn cellsFor(px: u32, total_px: u32, count: usize) !u32 {
    const cell: u32 = @intCast(total_px / count);
    if (cell == 0) return error.NoCellSize;
    return (px + cell - 1) / cell;
}

fn emitOnePlacement(
    env: emacs.Env,
    term: *GhostelTerm,
    storage: *const gt.kitty.graphics.ImageStorage,
    key: *const gt.kitty.graphics.ImageStorage.PlacementKey,
    placement: *const gt.kitty.graphics.ImageStorage.Placement,
) !void {
    const image = storage.images.getPtr(key.image_id) orelse return error.ImageNotFound;
    switch (placement.location) {
        // Drawn from its placeholder runs by emitVirtualRuns.
        .virtual => return,
        .pin => |pin| try emitPinned(env, term, image, placement, pin, 0, 0),
        .relative => |rel| {
            // An unresolvable chain is never drawn.
            const chain = storage.resolveChain(rel) orelse return error.NotVisible;
            switch (chain.root.location) {
                .pin => |root_pin| try emitPinned(
                    env,
                    term,
                    image,
                    placement,
                    root_pin,
                    chain.horizontal_offset,
                    chain.vertical_offset,
                ),
                // Not implemented: kitty anchors these at the top-left
                // placeholder cell of the parent's runs.
                .virtual => return error.NotVisible,
                .relative => unreachable,
            }
        },
    }
}

/// Emit a placement anchored at PIN, offset by H_OFF/V_OFF cells.
fn emitPinned(
    env: emacs.Env,
    term: *GhostelTerm,
    image: *const gt.kitty.graphics.Image,
    placement: *const gt.kitty.graphics.ImageStorage.Placement,
    pin: *const gt.PageList.Pin,
    h_off: i32,
    v_off: i32,
) !void {
    const pixel_size = placement.pixelSize(image.*, &term.terminal);
    const grid_size = placement.gridSize(image.*, &term.terminal);
    const pages = &term.terminal.screens.active.pages;
    // A pruned anchor page leaves the pin parked at (0,0) until reaped.
    if (pin.garbage) return error.NotVisible;
    const pin_screen = pages.pointFromPin(.screen, pin.*) orelse return error.NotVisible;
    const active_tl = pages.getTopLeft(.active);
    const active_screen = pages.pointFromPin(.screen, active_tl) orelse return error.NotVisible;
    // i64: protocol offsets and grid sizes are unbounded.  Elisp clips negatives.
    const screen_row: i64 = @as(i64, @intCast(pin_screen.screen.y)) + v_off;
    const active_row: i64 = screen_row - @as(i64, @intCast(active_screen.screen.y));
    const active_col: i64 = @as(i64, @intCast(pin_screen.screen.x)) + h_off;
    const visible = active_row + grid_size.rows > 0 and active_row < term.terminal.rows and
        active_col + grid_size.cols > 0 and active_col < term.terminal.cols;

    if (!visible) return error.NotVisible;

    // Emacs crops only post-scale, so crop before it sees the pixels.
    const src = placement.sourceRect(image.*);
    const data = try getImageData(term.alloc, image, .{ .x = src.x, .y = src.y, .width = src.width, .height = src.height });
    defer term.alloc.free(data);

    const img_val = env.makeUnibyteString(data) orelse return error.MakeString;
    _ = env.f("ghostel--kitty-display-image", .{
        img_val,
        screen_row,
        active_col,
        grid_size.cols,
        grid_size.rows,
        pixel_size.width,
        pixel_size.height,
    });
}

/// Image bytes of the RECT sub-rectangle of IMAGE, owned by `alloc`:
/// PNG when RECT has a transparent pixel (PPM has no alpha), else PPM.
fn getImageData(alloc: Allocator, image: *const gt.kitty.graphics.Image, rect: ppm.Rect) ![]const u8 {
    // Decompression happens at transmit time; anything else is a libghostty change.
    if (image.compression != .none) return error.UnsupportedCompression;
    // Chunked transmissions still in flight have no complete bytes yet.
    const data = image.renderData().bytes() orelse return error.EmptyImage;
    if (data.len == 0 or image.width == 0 or image.height == 0) return error.EmptyImage;
    // PNG is decoded to RGBA at transmit time by the hook in module.zig.
    const channels: u32 = switch (image.format) {
        .png => unreachable,
        .rgba => 4,
        .rgb => 3,
        .gray_alpha => 2,
        .gray => 1,
    };
    if (png.hasTransparency(data, image.width, image.height, channels, rect))
        return png.encode(alloc, data, image.width, image.height, channels, rect) orelse error.PngEncode;
    return ppm.createPpm(alloc, data, image.width, image.height, channels, rect) orelse error.PpmConvert;
}
