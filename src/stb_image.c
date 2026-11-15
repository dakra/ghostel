/* stb_image implementation — PNG-only build for kitty graphics.
 *
 * Vendored from: https://github.com/nothings/stb
 * Version:       v2.30 (see header comment in vendor/stb/stb_image.h)
 * Vendored:      2026-04 */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#include "stb_image.h"

#include "stb_resize.h"

static void *ghostel_resize_alloc(size_t size, void *context)
{
    GhostelResizeScratch *scratch = context;
    return scratch->acquire(scratch->context, size);
}

/* Context-backed memory stays owned by the caller between resizes. */
#define STBIR_MALLOC(size, context) ghostel_resize_alloc(size, context)
#define STBIR_FREE(ptr, context) ((void)(ptr), (void)(context))
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image_resize.h"

extern unsigned char *ghostel_png_compress(const unsigned char *data, int data_len,
                                          int *out_len, int quality);

/* Zig's compressor propagates allocation failures instead of asserting. */
#define STBIW_ZLIB_COMPRESS ghostel_png_compress
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"
