# Vendored stb image helpers

Each header contains its upstream license (MIT or public domain).

- `stb_image.h`: existing PNG decoder, v2.30.
- `stb_image_resize.h`: v0.97, copied unchanged from Ghostel's pinned
  Ghostty dependency `b2c78c9bd9bc88a16d9c3769b0fb17ddde1b78b1`,
  `src/stb/stb_image_resize.h`. Its subpixel API lets row bands share the
  full placement's sampling transform.
- `stb_image_write.h`: v1.16, from
  <https://github.com/nothings/stb/blob/d14d46f6b44456eb88beac58cba833a4135d4c89/stb_image_write.h>.
  Patched to free compressed data if the final PNG allocation fails. Its
  `STBIW_ZLIB_COMPRESS` hook uses Zig's standard-library compressor so allocation
  failures return an encoding error rather than aborting the process.

The implementations are compiled in `src/stb_image.c`. No system image
processing library or runtime dependency is required.
