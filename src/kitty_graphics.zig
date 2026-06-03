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
const ppm = @import("ppm.zig");

/// Query all visible kitty graphics placements from libghostty and
/// emit them to Elisp for display.  Called after render_state_update()
/// during each redraw.
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
        .virtual => {
            const emacs_data = try getImageData(term.alloc, image);
            defer if (emacs_data.allocated) term.alloc.free(emacs_data.data);

            // Virtual placements (yazi-style U+10EEEE unicode placeholders).
            // The API doesn't provide viewport positions — Elisp searches
            // the buffer for placeholder characters.
            const img_val = env.makeUnibyteString(emacs_data.data) orelse return error.MakeString;
            var args = [_]emacs.Value{
                img_val,
                if (emacs_data.is_png) env.t() else env.nil(),
            };
            _ = env.funcall(emacs.sym.@"ghostel--kitty-display-virtual", &args);
        },
        .pin => |pin| {
            // Most of this is taken from libghostty C API wrapper
            const pixel_size = placement.pixelSize(image.*, &term.terminal);
            const grid_size = placement.gridSize(image.*, &term.terminal);
            const pages = &term.terminal.screens.active.pages;
            const pin_screen = pages.pointFromPin(.screen, pin.*) orelse return error.NotVisible;
            const active_tl = pages.getTopLeft(.active);
            const active_screen = pages.pointFromPin(.screen, active_tl) orelse return error.NotVisible;
            const active_row: i32 = @as(i32, @intCast(pin_screen.screen.y)) -
                @as(i32, @intCast(active_screen.screen.y));
            const active_col: i32 = @intCast(pin_screen.screen.x);
            const rows_i32: i32 = @intCast(grid_size.rows);
            const term_rows: i32 = @intCast(term.terminal.rows);
            const visible = active_row + rows_i32 > 0 and active_row < term_rows;

            // Non-virtual: get render info for viewport position.
            if (!visible) return error.NotVisible;

            const emacs_data = try getImageData(term.alloc, image);
            defer if (emacs_data.allocated) term.alloc.free(emacs_data.data);

            const img_val = env.makeUnibyteString(emacs_data.data) orelse return error.MakeString;
            _ = env.f("ghostel--kitty-display-image", .{
                img_val,
                if (emacs_data.is_png) env.t() else env.nil(),
                pin_screen.screen.y,
                active_col,
                grid_size.cols,
                grid_size.rows,
                pixel_size.width,
                pixel_size.height,
                @min(placement.source_x, image.width),
                @min(placement.source_y, image.height),
                placement.source_width,
                placement.source_height,
            });
        },
    }
}

/// Image bytes ready to hand to Emacs.
///
/// Lifetime: when `allocated` is false, `data` aliases libghostty-owned
/// storage and is only valid until libghostty mutates the image table
/// (e.g. an evicting transmit, a delete command, or storage trimming).
/// Use it synchronously — copy via `makeUnibyteString` and drop the
/// reference before yielding control back to libghostty.  When
/// `allocated` is true, `data` is owned by the caller's allocator and the
/// caller must free it.
const ImageData = struct {
    data: []const u8,
    is_png: bool,
    allocated: bool,
};

fn getImageData(alloc: Allocator, image: *const gt.kitty.graphics.Image) !ImageData {
    // libghostty decompresses images at transmit time, so by the time
    // we read out the data here it should always be in the .none state.
    // Refuse explicitly so a future libghostty change that defers
    // decompression doesn't silently hand us garbage bytes that Emacs
    // would try to render as PNG/PPM.
    if (image.compression != .none) return error.UnsupportedCompression;

    if (image.data.len == 0 or image.width == 0 or image.height == 0) return error.EmptyImage;
    // Alpha is dropped, not composited (see ppm.createPpm doc comment).
    // PNG payloads in normal operation never reach the PNG branch here:
    // libghostty's PNG decode hook (sys.zig) decodes them to RGBA at
    // transmit time, so format arrives as RGBA and we go through the
    // PPM path with channels=4.  The PNG branch stays for the case
    // where the decode hook is uninstalled or rejected the payload.
    return switch (image.format) {
        .png => .{ .data = image.data, .is_png = true, .allocated = false },
        .rgba => .{
            .data = ppm.createPpm(alloc, image.data, image.width, image.height, 4) orelse return error.PpmConvert,
            .is_png = false,
            .allocated = true,
        },
        .rgb => .{
            .data = ppm.createPpm(alloc, image.data, image.width, image.height, 3) orelse return error.PpmConvert,
            .is_png = false,
            .allocated = true,
        },
        .gray_alpha => .{
            .data = ppm.createPpm(alloc, image.data, image.width, image.height, 2) orelse return error.PpmConvert,
            .is_png = false,
            .allocated = true,
        },
        .gray => .{
            .data = ppm.createPpm(alloc, image.data, image.width, image.height, 1) orelse return error.PpmConvert,
            .is_png = false,
            .allocated = true,
        },
    };
}
