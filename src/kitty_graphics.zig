/// Kitty Graphics Protocol support via the libghostty C API.
///
/// Queries libghostty's authoritative placement and image state during
/// each redraw cycle, converts pixel data to PPM for Emacs display,
/// and calls into Elisp to apply image overlays.
const std = @import("std");
const emacs = @import("emacs.zig");
const Terminal = @import("terminal.zig");
const gt = @import("ghostty.zig");
const ppm = @import("ppm.zig");

/// Query all visible kitty graphics placements from libghostty and
/// emit them to Elisp for display.  Called after render_state_update()
/// during each redraw.
pub fn emitPlacements(env: emacs.Env, term: *Terminal) !void {
    // Obtain the kitty graphics handle from the terminal.
    const graphics = try gt.terminal_data.get(gt.KittyGraphics, term.terminal, gt.DATA_KITTY_GRAPHICS);

    // Create a placement iterator.
    var iterator: gt.KittyGraphicsPlacementIterator = undefined;
    try gt.toError(gt.c.ghostty_kitty_graphics_placement_iterator_new(null, &iterator));
    defer gt.c.ghostty_kitty_graphics_placement_iterator_free(iterator);

    // Populate it from the storage.
    try gt.kitty_graphics_data.read(graphics, gt.c.GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &iterator);

    // Iterate over all placements. Per-placement errors skip that placement only.
    while (gt.c.ghostty_kitty_graphics_placement_next(iterator)) {
        emitOnePlacement(env, term, graphics, iterator) catch continue;
    }
}

fn emitOnePlacement(
    env: emacs.Env,
    term: *Terminal,
    graphics: gt.KittyGraphics,
    iterator: gt.KittyGraphicsPlacementIterator,
) !void {
    // Get image ID and check if virtual.
    const image_id = try gt.kitty_placement_data.get(u32, iterator, gt.c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID);
    // Failure to query is_virtual would silently misclassify the
    // placement as non-virtual; for virtuals, render_info reports
    // viewport_visible=false and we'd silently drop the image.
    const is_virtual = try gt.kitty_placement_data.get(bool, iterator, gt.c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL);

    // Look up the image.
    const image = gt.c.ghostty_kitty_graphics_image(graphics, image_id) orelse return error.ImageNotFound;

    if (is_virtual) {
        // Virtual placements (yazi-style U+10EEEE unicode placeholders).
        // The API doesn't provide viewport positions — Elisp searches
        // the buffer for placeholder characters.
        const emacs_data = try getImageData(image);
        defer if (emacs_data.allocated) std.heap.c_allocator.free(emacs_data.data);

        const img_val = env.makeUnibyteString(emacs_data.data) orelse return error.MakeString;
        var args = [_]emacs.Value{
            img_val,
            if (emacs_data.is_png) env.t() else env.nil(),
        };
        _ = env.funcall(emacs.sym.@"ghostel--kitty-display-virtual", &args);
        return;
    }

    // Non-virtual: get render info for viewport position.
    var info = std.mem.zeroes(gt.KittyGraphicsPlacementRenderInfo);
    info.size = @sizeOf(gt.KittyGraphicsPlacementRenderInfo);
    if (gt.c.ghostty_kitty_graphics_placement_render_info(
        iterator,
        image,
        term.terminal,
        &info,
    ) != gt.SUCCESS) return error.RenderInfo;

    if (!info.viewport_visible) return error.NotVisible;

    const emacs_data = try getImageData(image);
    defer if (emacs_data.allocated) std.heap.c_allocator.free(emacs_data.data);

    const img_val = env.makeUnibyteString(emacs_data.data) orelse return error.MakeString;
    // viewport_row is relative to the visible viewport; ghostel materializes
    // scrollback above the viewport in the buffer, so the absolute buffer
    // row is viewport_row + scrollback_in_buffer.  Compute it on this side
    // so the elisp callback can do a single forward-line from point-min.
    const abs_row: i64 = @as(i64, @intCast(info.viewport_row)) +
        @as(i64, @intCast(term.renderer.rows_in_buffer - term.renderer.size.rows));
    _ = env.f("ghostel--kitty-display-image", .{
        img_val,
        if (emacs_data.is_png) env.t() else env.nil(),
        abs_row,
        info.viewport_col,
        info.grid_cols,
        info.grid_rows,
        info.pixel_width,
        info.pixel_height,
        info.source_x,
        info.source_y,
        info.source_width,
        info.source_height,
    });
}

/// Image bytes ready to hand to Emacs.
///
/// Lifetime: when `allocated` is false, `data` aliases libghostty-owned
/// storage and is only valid until libghostty mutates the image table
/// (e.g. an evicting transmit, a delete command, or storage trimming).
/// Use it synchronously — copy via `makeUnibyteString` and drop the
/// reference before yielding control back to libghostty.  When
/// `allocated` is true, `data` is owned by `c_allocator` and the caller
/// must free it.
const ImageData = struct {
    data: []const u8,
    is_png: bool,
    allocated: bool,
};

fn getImageData(image: gt.KittyGraphicsImage) !ImageData {
    var format: gt.KittyImageFormat = undefined;
    var compression: gt.KittyImageCompression = undefined;
    var img_width: u32 = 0;
    var img_height: u32 = 0;
    var data_ptr: [*]const u8 = undefined;
    var data_len: usize = 0;

    const keys = [_]gt.c.GhosttyKittyGraphicsImageData{
        gt.c.GHOSTTY_KITTY_IMAGE_DATA_FORMAT,
        gt.c.GHOSTTY_KITTY_IMAGE_DATA_COMPRESSION,
        gt.c.GHOSTTY_KITTY_IMAGE_DATA_WIDTH,
        gt.c.GHOSTTY_KITTY_IMAGE_DATA_HEIGHT,
        gt.c.GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR,
        gt.c.GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN,
    };
    var values = [_]?*anyopaque{
        @ptrCast(&format),
        @ptrCast(&compression),
        @ptrCast(&img_width),
        @ptrCast(&img_height),
        @ptrCast(&data_ptr),
        @ptrCast(&data_len),
    };
    if (gt.c.ghostty_kitty_graphics_image_get_multi(
        image,
        keys.len,
        &keys,
        @ptrCast(&values),
        null,
    ) != gt.SUCCESS) return error.ImageData;

    // libghostty decompresses images at transmit time, so by the time
    // we read out the data here it should always be in the .none state.
    // Refuse explicitly so a future libghostty change that defers
    // decompression doesn't silently hand us garbage bytes that Emacs
    // would try to render as PNG/PPM.
    if (compression != gt.c.GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE) {
        return error.UnsupportedCompression;
    }

    if (data_len == 0 or img_width == 0 or img_height == 0) return error.EmptyImage;

    const pixel_data = data_ptr[0..data_len];
    // Alpha is dropped, not composited (see ppm.createPpm doc comment).
    // PNG payloads in normal operation never reach the PNG branch here:
    // libghostty's PNG decode hook (sys.zig) decodes them to RGBA at
    // transmit time, so format arrives as RGBA and we go through the
    // PPM path with channels=4.  The PNG branch stays for the case
    // where the decode hook is uninstalled or rejected the payload.
    const ppm_alloc = std.heap.c_allocator;
    return switch (format) {
        gt.c.GHOSTTY_KITTY_IMAGE_FORMAT_PNG => .{ .data = pixel_data, .is_png = true, .allocated = false },
        gt.c.GHOSTTY_KITTY_IMAGE_FORMAT_RGBA => .{
            .data = ppm.createPpm(ppm_alloc, pixel_data, img_width, img_height, 4) orelse return error.PpmConvert,
            .is_png = false,
            .allocated = true,
        },
        gt.c.GHOSTTY_KITTY_IMAGE_FORMAT_RGB => .{
            .data = ppm.createPpm(ppm_alloc, pixel_data, img_width, img_height, 3) orelse return error.PpmConvert,
            .is_png = false,
            .allocated = true,
        },
        gt.c.GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA => .{
            .data = ppm.createPpm(ppm_alloc, pixel_data, img_width, img_height, 2) orelse return error.PpmConvert,
            .is_png = false,
            .allocated = true,
        },
        gt.c.GHOSTTY_KITTY_IMAGE_FORMAT_GRAY => .{
            .data = ppm.createPpm(ppm_alloc, pixel_data, img_width, img_height, 1) orelse return error.PpmConvert,
            .is_png = false,
            .allocated = true,
        },
        else => return error.UnsupportedFormat,
    };
}
