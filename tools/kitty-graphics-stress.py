#!/usr/bin/env python3
"""Visual Kitty Graphics torture tests for Ghostel and Ghostty (stdlib only).

Use the same terminal size and similar fonts in both terminals. Compare the
labeled scenes, or pause after each one:

    python3 tools/kitty-graphics-stress.py --pause
    python3 tools/kitty-graphics-stress.py --only placeholders fragments alpha
    python3 tools/kitty-graphics-stress.py --only churn --rounds 80 --delay .05

--list describes the scenes. Output remains in scrollback. The script deletes
existing Kitty images on startup unless --no-clear is given. No animation,
behind-text images, relative placements rooted in placeholders, or guarantees
about updating historical images are tested. Transparency over ordinary text
is exercised only with fully transparent or fully opaque cells.
"""

from __future__ import annotations

import argparse
import base64
from contextlib import contextmanager
import math
import random
import shutil
import struct
import sys
import time
from typing import Iterator
import zlib

ESC = b"\x1b"
APC_START = ESC + b"_G"
APC_END = ESC + b"\\"
PLACEHOLDER = "\U0010eeee"
DIACRITICS = ("\u0305", "\u030d", "\u030e", "\u0310", "\u0312", "\u033d", "\u033e", "\u033f")
PALETTE = ((240, 55, 55), (40, 210, 90), (50, 100, 255), (255, 205, 40),
           (200, 70, 230), (30, 210, 220), (250, 140, 40), (230, 230, 230))


def out(data: bytes | str) -> None:
    sys.stdout.buffer.write(data.encode("utf-8") if isinstance(data, str) else data)


def flush() -> None:
    sys.stdout.buffer.flush()


def csi(sequence: str) -> None:
    out(f"\x1b[{sequence}")


def sgr(sequence: str = "0") -> None:
    csi(sequence + "m")


def line(text: str = "") -> None:
    out(text + "\r\n")


def graphics(control: str, payload: bytes | None = None) -> None:
    """Chunk base64 on four-byte boundaries; continuation chunks carry only m."""
    if payload is None:
        out(APC_START + control.encode("ascii") + APC_END)
        return
    encoded = base64.b64encode(payload)
    for offset in range(0, max(1, len(encoded)), 4096):
        more = int(offset + 4096 < len(encoded))
        fields = control if not offset else ""
        if len(encoded) > 4096:
            fields += ("," if fields else "") + f"m={more}"
        out(APC_START + fields.encode("ascii") + b";" + encoded[offset:offset + 4096] + APC_END)


def transmit(image_id: int, width: int, height: int, data: bytes, channels: int = 3,
             *, png: bool = False) -> None:
    if len(data) != width * height * channels:
        raise ValueError("pixel payload does not match dimensions")
    if png:
        def chunk(kind: bytes, body: bytes) -> bytes:
            return (struct.pack(">I", len(body)) + kind + body
                    + struct.pack(">I", zlib.crc32(kind + body)))
        stride = width * channels
        scanlines = b"".join(b"\0" + data[y:y + stride] for y in range(0, len(data), stride))
        color_type = 6 if channels == 4 else 2
        data = (b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(scanlines)) + chunk(b"IEND", b""))
    graphics(f"a=t,f={100 if png else channels * 8},s={width},v={height},i={image_id},q=2", data)


def place(image_id: int, *, cols: int | None = None, rows: int | None = None,
          placement_id: int = 1, source: tuple[int, int, int, int] | None = None,
          offset: tuple[int, int] | None = None, z: int = 0, virtual: bool = False,
          parent: tuple[int, int, int, int] | None = None) -> None:
    fields = ["a=p", f"i={image_id}", f"p={placement_id}", "C=1", "q=2", f"z={z}"]
    if cols is not None:
        fields.append(f"c={cols}")
    if rows is not None:
        fields.append(f"r={rows}")
    if source is not None:
        fields.extend(f"{key}={value}" for key, value in zip(("x", "y", "w", "h"), source))
    if offset is not None:
        fields.extend((f"X={offset[0]}", f"Y={offset[1]}"))
    if virtual:
        fields.append("U=1")
    if parent is not None:
        fields.extend(f"{key}={value}" for key, value in zip(("P", "Q", "H", "V"), parent))
    graphics(",".join(fields))


def delete(image_id: int, placement_id: int | None = None) -> None:
    fields = f"a=d,d=i,i={image_id},q=2"
    if placement_id is not None:
        fields += f",p={placement_id}"
    graphics(fields)


def rgb_color(prefix: str, value: int) -> None:
    sgr(f"{prefix};2;{(value >> 16) & 255};{(value >> 8) & 255};{value & 255}")


def placeholder_run(image_id: int, row: int, col: int, count: int, *,
                    inherited: bool = False, placement_id: int = 1) -> None:
    rgb_color("38", image_id & 0xffffff)
    rgb_color("58", placement_id)
    high_byte = image_id >> 24
    for index in range(count):
        cell = PLACEHOLDER
        if not inherited or not index:
            cell += DIACRITICS[row] + DIACRITICS[col + index]
            if high_byte:
                cell += DIACRITICS[high_byte]
        out(cell)
    sgr()


class Panel:
    """A reserved block so multi-row images never overwrite later headings."""

    def __init__(self, height: int) -> None:
        self.height = height

    def at(self, row: int, col: int = 1) -> None:
        if not 0 <= row < self.height or col < 1:
            raise ValueError("position outside panel")
        out(ESC + b"8")
        if row:
            csi(f"{row}B")
        csi(f"{col}G")

    def text(self, row: int, col: int, text: str) -> None:
        self.at(row, col)
        out(text)

    def grid(self, image_id: int, row: int, col: int, *, cols: int, rows: int,
             inherited: bool = False, placement_id: int = 1,
             source_row: int = 0, source_col: int = 0) -> None:
        for y in range(rows):
            self.at(row + y, col)
            placeholder_run(image_id, source_row + y, source_col, cols,
                            inherited=inherited, placement_id=placement_id)


@contextmanager
def panel(height: int) -> Iterator[Panel]:
    # Reserve first: scrolling during reservation must precede saving the origin.
    out("\r\n" * height)
    csi(f"{height}A")
    csi("1G")
    out(ESC + b"7")
    try:
        yield Panel(height)
    finally:
        out(ESC + b"8")
        csi(f"{height}B")
        csi("1G")
        sgr()


def atlas(width: int = 96, height: int = 64) -> bytes:
    data = bytearray()
    noise = random.Random(7)
    for y in range(height):
        for x in range(width):
            quadrant = int(x >= width // 2) + 2 * int(y >= height // 2)
            color = PALETTE[quadrant]
            if x in (width // 2 - 1, width // 2) or y in (height // 2 - 1, height // 2):
                color = (255, 255, 255)
            elif x % 12 == 0 or y % 8 == 0:
                color = tuple(max(0, channel - 70) for channel in color)
            else:
                # Fine detail exposes resampling errors and keeps PNG uploads chunked.
                color = tuple(max(0, channel - noise.randrange(24)) for channel in color)
            data.extend(color)
    return bytes(data)


def solid(image_id: int, color: tuple[int, ...]) -> None:
    transmit(image_id, 1, 1, bytes(color), len(color))


def wait(args: argparse.Namespace) -> None:
    flush()
    time.sleep(args.delay)


def formats(args: argparse.Namespace, base: int) -> None:
    data = atlas()
    transmit(base, 96, 64, data)
    transmit(base + 1, 96, 64, data, png=True)
    rgba = b"".join(data[i:i + 3] + b"\xff" for i in range(0, len(data), 3))
    transmit(base + 2, 96, 64, rgba, 4)
    line("Three identical atlases: RGB | PNG | opaque RGBA. No missing chunks.")
    with panel(5) as p:
        for index, label in enumerate(("RGB", "PNG", "RGBA")):
            col = 1 + index * 21
            p.text(0, col, label)
            p.at(1, col)
            place(base + index, cols=16, rows=3)


def crops(args: argparse.Namespace, base: int) -> None:
    transmit(base, 96, 64, atlas())
    line("Red | green | blue | yellow | clipped yellow corner; no other quadrant.")
    with panel(5) as p:
        for index, source in enumerate(((0, 0, 48, 32), (48, 0, 48, 32),
                                        (0, 32, 48, 32), (48, 32, 48, 32),
                                        (72, 48, 80, 50))):
            p.text(0, 1 + index * 12, str(index + 1))
            p.at(1, 1 + index * 12)
            place(base, cols=9, rows=3, placement_id=index + 1, source=source)


def geometry(args: argparse.Namespace, base: int) -> None:
    transmit(base, 96, 64, atlas())
    transmit(base + 1, 24, 16, atlas(24, 16))
    line("Fixed grid | width only | height only | natural size | pixel offset.")
    with panel(7) as p:
        specs = ((1, dict(cols=10, rows=3)), (15, dict(cols=10)),
                 (29, dict(rows=3)), (44, {}), (53, dict(cols=8, rows=3, offset=(3, 2))))
        for index, (col, spec) in enumerate(specs):
            p.text(0, col, str(index + 1))
            p.at(1, col)
            place(base + 1 if index == 3 else base, placement_id=index + 1, **spec)
        p.text(5, 1, "short")
        p.text(4, 34, "v sparse anchor")
        p.at(5, 34)
        place(base, cols=8, rows=1, placement_id=10)


def alpha(args: argparse.Namespace, base: int) -> None:
    solid(base, (0, 0, 255))
    solid(base + 1, (255, 0, 0, 128))
    solid(base + 2, (255, 0, 0))
    solid(base + 3, (0, 0, 255))
    solid(base + 4, (0, 220, 255))
    solid(base + 5, (255, 0, 0, 0))
    edge = bytes((255, 0, 0, 255)) * 8 + bytes((0, 255, 0, 0)) * 8
    transmit(base + 6, 16, 1, edge, 4)
    line("Overlap: red/blue -> purple. Equal z: higher image ID wins, not last write.")
    with panel(8) as p:
        p.text(0, 1, "Alpha overlap")
        p.at(1, 1)
        place(base, cols=16, rows=3, z=1)
        p.at(2, 5)
        place(base + 1, cols=8, rows=1, z=2)
        p.text(0, 23, "Higher-ID blue wins")
        p.at(2, 27)
        place(base + 3, cols=8, rows=1, z=3)
        p.at(1, 23)
        place(base + 2, cols=16, rows=3, z=3)
        p.text(5, 1, "0123456789ABCDEF")
        p.at(5, 1)
        place(base + 4, cols=4, rows=1)
        p.at(5, 5)
        place(base + 5, cols=8, rows=1)
        p.at(5, 13)
        place(base + 4, cols=4, rows=1, placement_id=2)
        p.text(6, 1, "Clear tile: 456789AB visible")
        p.at(5, 40)
        place(base + 6, cols=16, rows=1)
        p.text(6, 40, "Red edge, no green halo")


def placeholders(args: argparse.Namespace, base: int) -> None:
    high_id = base + (2 << 24)
    for image_id in (base, high_id):
        transmit(image_id, 96, 64, atlas())
        place(image_id, virtual=True, cols=8, rows=4)
    place(base, virtual=True, cols=8, rows=4, placement_id=2)
    place(base, virtual=True, cols=4, rows=2, placement_id=3)
    line("First three match. Green/blue fragments use placeholder coordinates.")
    with panel(6) as p:
        for col, label in ((1, "Explicit"), (14, "Inherited"), (28, "High ID"),
                           (44, "Green 4c"), (53, "Blue 2c")):
            p.text(0, col, label)
        p.grid(base, 1, 1, cols=8, rows=4)
        p.grid(base, 1, 14, cols=8, rows=4, inherited=True)
        p.grid(high_id, 1, 28, cols=8, rows=4)
        p.grid(base, 1, 44, cols=4, rows=2, placement_id=2, source_col=4)
        p.grid(base, 1, 53, cols=2, rows=1, placement_id=3, source_row=1)


def fragments(args: argparse.Namespace, base: int) -> None:
    data = b"".join(bytes(color) * 8 for color in PALETTE)
    transmit(base, 64, 1, data)
    place(base, virtual=True, cols=8, rows=1)
    line("Fragments use source columns, not screen columns; gap text stays visible.")
    with panel(5) as p:
        for row, (left, right, label) in enumerate(((0, 6, "ends"), (6, 0, "reversed"),
                                                   (0, 0, "repeated")), 1):
            p.text(row, 1, label)
            p.at(row, 14)
            placeholder_run(base, 0, left, 2, inherited=True)
            out(" <text gap> ")
            placeholder_run(base, 0, right, 2, inherited=True)


def letterbox(args: argparse.Namespace, base: int) -> None:
    transmit(base, 64, 8, bytes((240, 60, 60)) * (64 * 8))
    transmit(base + 1, 8, 64, bytes((50, 150, 255)) * (8 * 64))
    rgba = b"".join(bytes((40, 220, 90, 255 if (x // 2 + y // 2) % 2 else 0))
                    for y in range(8) for x in range(8))
    transmit(base + 2, 8, 8, rgba, 4)
    line("Padding and transparent cells are blank, with no placeholder glyphs or tall rows.")
    with panel(6) as p:
        for index, label in enumerate(("Wide: blank rows", "Tall: blank columns", "Alpha checker")):
            col = 1 + index * 22
            p.text(0, col, label)
            place(base + index, virtual=True, cols=8, rows=4)
            p.grid(base + index, 1, col, cols=8, rows=4)
        p.text(5, 1, "-------------------- row-spacing baseline --------------------")


def text(args: argparse.Namespace, base: int) -> None:
    transmit(base, 96, 64, atlas())
    line("The first two images are four cells wide despite a face/link boundary.")
    with panel(6) as p:
        p.at(1)
        sgr("48;2;17;34;51")
        out("ab")
        sgr("48;2;68;85;102")
        out("\x1b]8;id=kitty-test;https://example.invalid/kitty\x1b\\cd\x1b]8;;\x1b\\")
        sgr()
        out("| after styles")
        p.at(1)
        place(base, cols=4, rows=1)
        p.text(2, 5, "| after plain")
        p.at(2)
        place(base, cols=4, rows=1, placement_id=2)
        p.text(4, 1, "a\u0301界X       | after combining/wide prefix")
        p.at(4, 4)
        place(base, cols=8, rows=1, placement_id=3)


def relative(args: argparse.Namespace, base: int) -> None:
    transmit(base, 96, 64, atlas())
    solid(base + 1, (50, 160, 255))
    solid(base + 2, (230, 60, 220))
    line("Root moves right; blue child and purple grandchild must follow, leaving no trails.")
    with panel(8) as p:
        p.at(3, 12)
        place(base, cols=8, rows=3)
        place(base + 1, cols=4, rows=1, parent=(base, 1, -8, -1), z=1)
        place(base + 2, cols=4, rows=1, parent=(base + 1, 1, 6, -1), z=2)
        wait(args)
        p.at(3, 32)
        place(base, cols=8, rows=3)
        p.text(0, 1, "Final: purple col 30, blue col 24, root col 32")


def updates(args: argparse.Namespace, base: int) -> None:
    solid(base, (240, 50, 50))
    solid(base + 1, (240, 50, 50))
    solid(base + 2, (40, 100, 255))
    solid(base + 3, (30, 220, 70))
    line("Final: red control left, moved blue tile right; deleting green reveals blue below.")
    with panel(7) as p:
        p.at(1, 1)
        place(base, cols=10, rows=2)
        p.at(1, 22)
        place(base + 1, cols=10, rows=2)
        p.at(4, 22)
        place(base + 2, cols=10, rows=1)
        place(base + 3, cols=10, rows=1, z=1)
        wait(args)
        # Retransmission replaces the image and removes its old placements.
        solid(base + 1, (40, 100, 255))
        p.at(1, 22)
        place(base + 1, cols=10, rows=2)
        wait(args)
        p.at(1, 44)
        place(base + 1, cols=10, rows=2)
        delete(base + 3)
        p.text(0, 1, "RED control")
        p.text(0, 22, "Empty after move")
        p.text(0, 44, "BLUE replacement")
        p.text(5, 22, "BLUE exposed by delete")


def edges(args: argparse.Namespace, base: int) -> None:
    transmit(base, 96, 64, atlas())
    solid(base + 1, (100, 100, 100))
    line("Edges crop the atlas rather than squeezing it; inspect bottom clipping before continuing.")
    with panel(8) as p:
        p.text(0, 1, "Left-clipped child")
        p.text(0, args.columns - 19, "Right-clipped tile")
        p.at(5, 1)
        place(base + 1, cols=1, rows=1)
        p.text(5, 3, "gray parent anchor")
        place(base, cols=12, rows=3, parent=(base + 1, 1, -5, -4), z=1)
        p.at(1, args.columns - 5)
        place(base, cols=12, rows=3, placement_id=2)
        p.text(6, 24, "Extends below screen:")
        p.at(7, 24)
        place(base, cols=12, rows=5, placement_id=3)


def churn(args: argparse.Namespace, base: int) -> None:
    rng = random.Random(args.seed)
    line(f"Seed {args.seed}, {args.rounds} rounds. Same seed gives the same final tiles.")
    line("Use --rounds 80 --delay .05 for repeated raster/cache turnover.")
    with panel(8) as p:
        for turn in range(args.rounds):
            for slot in range(8):
                image_id = base + slot
                row, col = 1 + (slot // 4) * 3, 1 + (slot % 4) * 16
                color = PALETTE[(slot + turn) % len(PALETTE)]
                data = b"".join(bytes(color if (x + y) % 4 else (255, 255, 255))
                                for y in range(16) for x in range(16))
                transmit(image_id, 16, 16, data)
                # Retransmitting some tiles but not placing them exercises removal.
                deleted = turn % 3 == 1 and slot % 3 == 0
                p.text(row - 1, col, f"{slot}:{'gone' if deleted else turn + 1:<4}  ")
                if not deleted:
                    p.at(row, col + rng.randrange(3))
                    source = (rng.randrange(9), rng.randrange(9), 8, 8)
                    place(image_id, cols=rng.randrange(4, 12), rows=2, source=source)
            wait(args)
        p.text(7, 1, "No old tile fragments should remain outside the final placements.")


def scroll(args: argparse.Namespace, base: int) -> None:
    transmit(base, 96, 64, atlas())
    transmit(base + 1, 96, 64, atlas())
    line("Images should scroll with these labels; scroll up after the filler output.")
    with panel(6) as p:
        p.text(0, 1, "PINNED")
        p.at(1, 1)
        place(base, cols=8, rows=4)
        p.text(0, 23, "PLACEHOLDERS")
        place(base + 1, virtual=True, cols=8, rows=4)
        p.grid(base + 1, 1, 23, cols=8, rows=4)
    for index in range(args.scroll_lines):
        line(f"scroll {index + 1:04d}: images and labels above should stay together")


SCENES = {
    "formats": (formats, "RGB, RGBA and PNG uploads, including chunked payloads"),
    "crops": (crops, "atlas quadrants, cropped scaling and source-edge clipping"),
    "geometry": (geometry, "sparse anchors, natural size, one-axis sizing and pixel offsets"),
    "alpha": (alpha, "z ordering, alpha blending, transparent holes and resampling halos"),
    "placeholders": (placeholders, "explicit/inherited coordinates, high IDs and explicit placement IDs"),
    "fragments": (fragments, "disjoint, reordered and repeated placeholder fragments around text"),
    "letterbox": (letterbox, "wide/tall virtual images and transparent placeholder cells"),
    "text": (text, "combining/wide text and face/link boundaries inside image spans"),
    "relative": (relative, "pinned parent/child chains moving as a group"),
    "updates": (updates, "same-ID retransmission, placement movement and deletion revealing a layer"),
    "edges": (edges, "left/right clipping and an image extending below the screen"),
    "churn": (churn, "seeded placement movement, replacement, deletion and repeated resize jobs"),
    "scroll": (scroll, "pinned and placeholder images entering scrollback with their labels"),
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list", action="store_true", help="list scenes without emitting terminal commands")
    parser.add_argument("--only", nargs="+", choices=SCENES, metavar="SCENE", help="run just these scenes, in this order")
    parser.add_argument("--pause", action="store_true", help="wait for Enter after each scene (q stops)")
    parser.add_argument("--no-clear", action="store_true", help="skip the initial screen and image clear")
    parser.add_argument("--delay", type=float, default=.35, help="seconds between mutation phases (default: .35)")
    parser.add_argument("--scroll-lines", type=int, help="filler lines for scroll scene (default: screen height + 10)")
    parser.add_argument("--rounds", type=int, default=12, help="churn rounds; 80+ exercises cache turnover")
    parser.add_argument("--seed", type=int, default=42, help="deterministic churn seed (default: 42)")
    args = parser.parse_args()
    if args.list:
        for name, (_, description) in SCENES.items():
            print(f"{name:14} {description}")
        return 0
    if not math.isfinite(args.delay) or args.delay < 0 or args.rounds < 1:
        parser.error("--delay must be finite and nonnegative; --rounds must be positive")
    if args.scroll_lines is not None and args.scroll_lines < 0:
        parser.error("--scroll-lines must be nonnegative")
    if args.pause and not (sys.stdin.isatty() and sys.stdout.isatty()):
        parser.error("--pause requires interactive stdin and stdout")
    size = shutil.get_terminal_size((100, 30))
    args.columns = size.columns
    if size.columns < 64 or size.lines < 16:
        parser.error("use a terminal at least 64 columns by 16 rows")
    args.scroll_lines = args.scroll_lines if args.scroll_lines is not None else size.lines + 10
    if not args.no_clear:
        graphics("a=d,d=A,q=2")
        csi("2J")
        csi("H")
    sgr()
    line("Kitty Graphics supported-feature torture test: Ghostel / Ghostty")
    line("Compare geometry, colors, clipping and gaps; align terminal sizes/fonts first.")
    try:
        for name in args.only or SCENES:
            line()
            run, description = SCENES[name]
            line(f"== {name}: {description} ==")
            if name == "edges":
                out("\r\n" * size.lines)
            run(args, 1000 + list(SCENES).index(name) * 100)
            flush()
            if args.pause:
                out("Enter: next scene; q: stop > ")
                flush()
                if input().strip().lower() == "q":
                    break
        line("Done. Scroll up to compare previous scenes; rerun --only SCENE to isolate one.")
    finally:
        sgr()
        out("\x1b]8;;\x1b\\")
        flush()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        line("Stopped.")
        flush()
        raise SystemExit(130)
