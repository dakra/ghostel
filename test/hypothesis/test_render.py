"""Hypothesis property tests for Ghostel rendering correctness."""

from __future__ import annotations

import base64
import collections
import hashlib
import json
import os
import selectors
import shlex
import subprocess
import threading
import time
import unittest
from pathlib import Path
from typing import Optional

try:
    from hypothesis import HealthCheck, Verbosity, event, given, note, settings, target
    from hypothesis import strategies as st
except ImportError as exc:  # pragma: no cover - exercised by the test runner env
    raise SystemExit(
        "Hypothesis is required for this test. Install with:\n"
        "  python3 -m pip install -r test/hypothesis/requirements.txt"
    ) from exc


REPO_ROOT = Path(__file__).resolve().parents[2]
EMACS = os.environ.get("EMACS", "emacs")
EMACSFLAGS = shlex.split(os.environ.get("EMACSFLAGS", ""))
MAX_EXAMPLES = int(os.environ.get("GHOSTEL_HYPOTHESIS_EXAMPLES", "100"))
CASE_TIMEOUT = float(os.environ.get("GHOSTEL_HYPOTHESIS_TIMEOUT", "30"))
CASES_DIR = Path(
    os.environ.get("GHOSTEL_HYPOTHESIS_CASES_DIR", REPO_ROOT / "test/hypothesis/cases")
)
FAILURE_ARTIFACTS_DIR = Path(
    os.environ.get(
        "GHOSTEL_HYPOTHESIS_FAILURE_DIR", "/private/tmp/ghostel-hypothesis-failure"
    )
)

TEXT_ALPHABET = (
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "0123456789"
    "     .,;:_+-=*/\\|()[]{}<>!?@#$%^&'\""
)
TEXT_BYTES = [ord(ch) for ch in TEXT_ALPHABET]
UNICODE_CHARS = list("λéöø界中┌─┐│✓★🟢🙂")
UNICODE_EDGE_CHARS = [
    "e\u0301",
    "a\u0308",
    "☃\ufe0f",
    "♥\ufe0e",
    "👩\u200d💻",
    "🏳️\u200d🌈",
    "·",
    "─",
    "表",
]
CONTROL_CHUNKS = [
    b"\x00",
    b"\x05",
    b"\x07",
    b"\x08",
    b"\t",
    b"\n",
    b"\v",
    b"\f",
    b"\r",
    b"\r\n",
    b"\x0e",
    b"\x0f",
    b"\x18",
    b"\x1a",
]
BULK_PATTERNS = [
    b"abcdefghijklmnopqrstuvwxyz0123456789",
    b"0123456789abcdef",
    b"The quick brown fox jumps over the lazy dog. ",
    b"-=+*#@ ",
]
SGR_CODES = [
    0,
    1,
    2,
    3,
    4,
    5,
    7,
    8,
    9,
    21,
    22,
    23,
    24,
    25,
    27,
    28,
    29,
    39,
    49,
    53,
    55,
    *range(30, 38),
    *range(40, 48),
    *range(90, 98),
    *range(100, 108),
]
DEC_PRIVATE_MODES = [
    1,     # application cursor keys
    3,     # 80/132 columns
    5,     # reverse video
    6,     # origin mode
    7,     # autowrap
    12,    # cursor blink
    25,    # cursor visibility
    40,    # allow 80/132 columns
    47,    # alternate screen
    66,    # application keypad
    69,    # left/right margin mode
    80,    # sixel scrolling mode
    95,    # do not clear screen on DECCOLM
    1000,  # mouse tracking variants
    1002,
    1003,
    1004,  # focus events
    1005,
    1006,
    1015,
    1047,
    1048,
    1049,
    2004,  # bracketed paste
    2026,  # synchronized output
]
ANSI_MODES = [2, 4, 12, 20]


def b64(data: bytes) -> str:
    """Return DATA encoded for the JSON protocol."""
    return base64.b64encode(data).decode("ascii")


def write_op(data: bytes) -> dict[str, str]:
    """Return a write operation for DATA."""
    return {"op": "write", "data": b64(data)}


def resize_op(delta_rows: int, delta_cols: int) -> dict[str, int]:
    """Return a resize operation with relative row/column deltas."""
    return {"op": "resize", "delta_rows": delta_rows, "delta_cols": delta_cols}


def repeated(pattern: bytes, length: int) -> bytes:
    """Return PATTERN repeated and truncated to LENGTH bytes."""
    if length <= 0:
        return b""
    return (pattern * ((length // len(pattern)) + 1))[:length]


def size_strategy(
    small: tuple[int, int],
    medium: tuple[int, int],
    large: tuple[int, int],
) -> st.SearchStrategy[int]:
    """Generate sizes with room for edge cases and occasional stress cases."""
    return st.one_of(
        st.integers(*small),
        st.integers(*small),
        st.integers(*medium),
        st.integers(*medium),
        st.integers(*large),
    )


def csi(params: str, final: str, private: str = "") -> bytes:
    """Return a CSI sequence."""
    return f"\x1b[{private}{params}{final}".encode("ascii")


def osc(command: str, payload: str, terminator: bytes) -> bytes:
    """Return an OSC sequence."""
    return b"\x1b]" + command.encode("ascii") + b";" + payload.encode("utf-8") + terminator


def ascii_text(max_size: int = 120) -> st.SearchStrategy[bytes]:
    """Generate printable ASCII text bytes."""
    return st.lists(st.sampled_from(TEXT_BYTES), min_size=1, max_size=max_size).map(bytes)


def unicode_text() -> st.SearchStrategy[bytes]:
    """Generate a small valid UTF-8 text chunk."""
    return st.lists(
        st.one_of(st.sampled_from(UNICODE_CHARS), st.sampled_from(UNICODE_EDGE_CHARS)),
        min_size=1,
        max_size=60,
    ).map(lambda chars: "".join(chars).encode("utf-8"))


def control_text() -> st.SearchStrategy[bytes]:
    """Generate C0 text controls that terminals commonly receive."""
    return st.lists(st.sampled_from(CONTROL_CHUNKS), min_size=1, max_size=80).map(
        b"".join
    )


@st.composite
def bulk_lines(draw: st.DrawFn, rows: int, cols: int) -> bytes:
    """Generate many newline-terminated rows to cross page/scrollback limits."""
    del rows
    line_count = draw(size_strategy((1, 16), (24, 180), (216, 900)))
    width = draw(size_strategy((0, max(cols, 1)), (cols, max(cols * 3, 80)), (80, 800)))
    pattern = draw(st.sampled_from(BULK_PATTERNS))
    newline = draw(st.sampled_from([b"\n", b"\r\n"]))
    parts = []
    for i in range(line_count):
        prefix = f"{i:05d}: ".encode("ascii")
        parts.append(prefix + repeated(pattern, width) + newline)
    return b"".join(parts)


@st.composite
def medium_lines(draw: st.DrawFn, rows: int, cols: int) -> bytes:
    """Generate modest line-oriented output for edge/state interleaving."""
    del rows
    line_count = draw(st.integers(min_value=1, max_value=40))
    width = draw(st.integers(min_value=0, max_value=max(cols * 2, 20)))
    pattern = draw(st.sampled_from(BULK_PATTERNS))
    newline = draw(st.sampled_from([b"\n", b"\r\n", b"\r"]))
    return b"".join(
        f"{i:03d}: ".encode("ascii") + repeated(pattern, width) + newline
        for i in range(line_count)
    )


@st.composite
def long_wrapped_line(draw: st.DrawFn, rows: int, cols: int) -> bytes:
    """Generate a long line that wraps over many terminal rows."""
    del rows
    length = draw(size_strategy((1, max(cols * 2, 16)), (256, 4096), (8192, 65536)))
    pattern = draw(st.sampled_from(BULK_PATTERNS))
    suffix = draw(st.sampled_from([b"", b"\n", b"\r\n"]))
    return repeated(pattern, length) + suffix


@st.composite
def styled_bulk_lines(draw: st.DrawFn, rows: int, cols: int) -> bytes:
    """Generate rows with frequent style changes."""
    del rows
    line_count = draw(size_strategy((1, 12), (20, 120), (216, 600)))
    width = draw(size_strategy((1, max(cols, 1)), (cols, max(cols * 2, 80)), (80, 400)))
    newline = draw(st.sampled_from([b"\n", b"\r\n"]))
    parts = []
    for i in range(line_count):
        fg = 30 + (i % 8)
        bg = 40 + ((i // 8) % 8)
        prefix = f"\x1b[{fg};{bg}m{i:05d}: ".encode("ascii")
        parts.append(prefix + repeated(b"styled-content ", width) + b"\x1b[0m" + newline)
    return b"".join(parts)


@st.composite
def unicode_bulk_lines(draw: st.DrawFn, rows: int, cols: int) -> bytes:
    """Generate bulk rows containing wide, combining, and multibyte characters."""
    del rows
    line_count = draw(size_strategy((1, 8), (12, 80), (120, 360)))
    width = draw(size_strategy((1, max(cols, 1)), (cols, max(cols * 2, 80)), (80, 240)))
    text = draw(st.sampled_from(["λ界🙂┌─┐✓", "e\u0301a\u0308☃️♥︎", "👩\u200d💻🏳️\u200d🌈表·─"]))
    repeated_text = (text * ((width // len(text)) + 1))[:width]
    return "".join(f"{i:05d}: {repeated_text}\r\n" for i in range(line_count)).encode(
        "utf-8"
    )


@st.composite
def sgr_sequence(draw: st.DrawFn) -> bytes:
    """Generate basic, indexed-color, and true-color SGR sequences."""
    kind = draw(st.sampled_from(["basic", "empty", "defaulted", "indexed", "truecolor"]))
    if kind == "empty":
        return b"\x1b[m"
    if kind == "defaulted":
        return draw(st.sampled_from([b"\x1b[;m", b"\x1b[1;;31m", b"\x1b[0;39;49m"]))
    if kind == "indexed":
        selector = draw(st.sampled_from([38, 48, 58]))
        color = draw(st.integers(min_value=0, max_value=255))
        return f"\x1b[{selector};5;{color}m".encode("ascii")
    if kind == "truecolor":
        selector = draw(st.sampled_from([38, 48, 58]))
        r = draw(st.integers(min_value=0, max_value=255))
        g = draw(st.integers(min_value=0, max_value=255))
        b = draw(st.integers(min_value=0, max_value=255))
        return f"\x1b[{selector};2;{r};{g};{b}m".encode("ascii")
    codes = draw(st.lists(st.sampled_from(SGR_CODES), min_size=1, max_size=8))
    return b"\x1b[" + ";".join(str(code) for code in codes).encode("ascii") + b"m"


@st.composite
def cursor_sequence(draw: st.DrawFn, rows: int, cols: int) -> bytes:
    """Generate cursor positioning and relative movement sequences."""
    kind = draw(st.sampled_from(["cup", "hvp", "line_col", "rel", "index", "tab"]))
    if kind in {"cup", "hvp"}:
        row = draw(st.integers(min_value=1, max_value=max(rows + 5, 1)))
        col = draw(st.integers(min_value=1, max_value=max(cols + 10, 1)))
        return f"\x1b[{row};{col}{'H' if kind == 'cup' else 'f'}".encode("ascii")
    if kind == "line_col":
        amount = draw(st.integers(min_value=0, max_value=max(rows, cols, 1) + 20))
        final = draw(st.sampled_from(["d", "G", "`", "a", "e"]))
        return csi(str(amount), final)
    if kind == "rel":
        amount = draw(st.integers(min_value=0, max_value=max(rows, cols, 1) + 20))
        final = draw(st.sampled_from(["A", "B", "C", "D", "E", "F"]))
        return csi(str(amount), final)
    if kind == "index":
        return draw(st.sampled_from([b"\x1bD", b"\x1bE", b"\x1bM", b"\x84", b"\x85", b"\x8d"]))
    amount = draw(st.integers(min_value=0, max_value=12))
    return csi(str(amount), draw(st.sampled_from(["I", "Z"])))


@st.composite
def erase_sequence(draw: st.DrawFn) -> bytes:
    """Generate erase-in-display/line variants."""
    final = draw(st.sampled_from(["J", "K"]))
    mode = draw(st.sampled_from(["", "0", "1", "2", "3"]))
    return csi(mode, final)


@st.composite
def edit_sequence(draw: st.DrawFn) -> bytes:
    """Generate insert/delete/erase character or line editing sequences."""
    amount = draw(st.integers(min_value=0, max_value=40))
    final = draw(st.sampled_from(["@", "P", "X", "L", "M", "S", "T", "b"]))
    return csi(str(amount), final)


@st.composite
def mode_sequence(draw: st.DrawFn) -> bytes:
    """Generate ANSI and DEC private mode set/reset sequences."""
    private = draw(st.booleans())
    final = draw(st.sampled_from(["h", "l"]))
    if private:
        mode = draw(st.sampled_from(DEC_PRIVATE_MODES))
        return csi(str(mode), final, private="?")
    mode = draw(st.sampled_from(ANSI_MODES))
    return csi(str(mode), final)


@st.composite
def scroll_region_sequence(draw: st.DrawFn, rows: int, cols: int) -> bytes:
    """Generate vertical and horizontal margin sequences."""
    kind = draw(st.sampled_from(["vertical", "reset", "horizontal", "horizontal_reset"]))
    if kind == "reset":
        return b"\x1b[r"
    if kind == "horizontal_reset":
        return b"\x1b[s"
    if kind == "horizontal":
        left = draw(st.integers(min_value=1, max_value=max(cols, 1)))
        right = draw(st.integers(min_value=left, max_value=max(cols, left)))
        return f"\x1b[{left};{right}s".encode("ascii")
    top = draw(st.integers(min_value=1, max_value=max(rows, 1)))
    bottom = draw(st.integers(min_value=top, max_value=max(rows, top)))
    return f"\x1b[{top};{bottom}r".encode("ascii")


@st.composite
def osc_sequence(draw: st.DrawFn) -> bytes:
    """Generate common OSC sequences with BEL and ST terminators."""
    kind = draw(
        st.sampled_from(
            ["title", "cwd", "hyperlink", "color", "clipboard", "prompt", "iterm"]
        )
    )
    terminator = draw(st.sampled_from([b"\x07", b"\x1b\\"]))
    if kind == "title":
        command = draw(st.sampled_from(["0", "1", "2"]))
        title = draw(
            st.text(
                alphabet="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_",
                min_size=0,
                max_size=60,
            )
        )
        return osc(command, title, terminator)
    if kind == "cwd":
        path = draw(
            st.sampled_from(
                ["file://localhost/tmp", "file:///Users/example/project", "file://host/a%20b"]
            )
        )
        return osc("7", path, terminator)
    if kind == "hyperlink":
        params = draw(st.sampled_from(["", "id=h1", "id=h1:foo=bar"]))
        uri = draw(st.sampled_from(["https://example.test/a", "file:///tmp/x", ""]))
        text = draw(ascii_text(max_size=40))
        return osc("8", params + ";" + uri, terminator) + text + osc("8", ";", terminator)
    if kind == "color":
        command = draw(st.sampled_from(["10", "11", "12", "4"]))
        payload = draw(
            st.sampled_from(
                ["#102030", "rgb:aa/bb/cc", "0;#000000", "255;rgb:ff/00/ff", "?"]
            )
        )
        return osc(command, payload, terminator)
    if kind == "clipboard":
        payload = draw(st.sampled_from(["c;SGVsbG8=", "p;", ";VGVzdA==", "c;?"]))
        return osc("52", payload, terminator)
    if kind == "prompt":
        payload = draw(st.sampled_from(["A", "B", "C", "D", "A;cl=m", "P;k=i", "P;Cwd=/tmp"]))
        return osc("133", payload, terminator)
    payload = draw(
        st.sampled_from(
            ["A", "B", "C", "D", "SetMark", "CurrentDir=/tmp", "ShellIntegrationVersion=1"]
        )
    )
    return osc("633", payload, terminator)


@st.composite
def charset_sequence(draw: st.DrawFn) -> bytes:
    """Generate character-set designation and locking-shift sequences."""
    return draw(
        st.sampled_from(
            [
                b"\x1b(B",
                b"\x1b(0",
                b"\x1b)B",
                b"\x1b)0",
                b"\x1b*B",
                b"\x1b+B",
                b"\x0e",
                b"\x0f",
            ]
        )
    )


@st.composite
def incomplete_escape_sequence(draw: st.DrawFn) -> bytes:
    """Generate partial sequences that leave parser state pending."""
    return draw(
        st.sampled_from(
            [
                b"\x1b",
                b"\x1b[",
                b"\x1b[?",
                b"\x1b[38;2;",
                b"\x1b]2;unterminated",
                b"\x1b]8;id=x;https://example.test",
                b"\x1bP1;2;3",
            ]
        )
    )


@st.composite
def small_terminal_chunk(draw: st.DrawFn, rows: int, cols: int) -> bytes:
    """Generate a small terminal sequence or text chunk."""
    kind = draw(
        st.sampled_from(
            [
                "ascii",
                "unicode",
                "control",
                "sgr",
                "cursor",
                "erase",
                "edit",
                "mode",
                "mode",
                "scroll_region",
                "scroll_region",
                "osc",
                "osc",
                "osc",
                "charset",
                "save_restore",
                "tab_stop",
                "incomplete",
            ]
        )
    )

    if kind == "ascii":
        return draw(ascii_text())
    if kind == "unicode":
        return draw(unicode_text())
    if kind == "control":
        return draw(control_text())
    if kind == "sgr":
        return draw(sgr_sequence())
    if kind == "cursor":
        return draw(cursor_sequence(rows, cols))
    if kind == "erase":
        return draw(erase_sequence())
    if kind == "edit":
        return draw(edit_sequence())
    if kind == "mode":
        return draw(mode_sequence())
    if kind == "scroll_region":
        return draw(scroll_region_sequence(rows, cols))
    if kind == "osc":
        return draw(osc_sequence())
    if kind == "charset":
        return draw(charset_sequence())
    if kind == "save_restore":
        return draw(st.sampled_from([b"\x1b7", b"\x1b8", b"\x1b[s", b"\x1b[u"]))
    if kind == "tab_stop":
        return draw(st.sampled_from([b"\x1bH", b"\x1b[0g", b"\x1b[3g"]))
    if kind == "incomplete":
        return draw(incomplete_escape_sequence())

    raise AssertionError(f"unhandled generated kind: {kind}")


@st.composite
def write_chunk(draw: st.DrawFn, rows: int, cols: int) -> bytes:
    """Generate one write chunk with a broad spread of sizes and state changes."""
    return draw(
        st.one_of(
            small_terminal_chunk(rows, cols),
            small_terminal_chunk(rows, cols),
            small_terminal_chunk(rows, cols),
            small_terminal_chunk(rows, cols),
            medium_lines(rows, cols),
            medium_lines(rows, cols),
            bulk_lines(rows, cols),
            long_wrapped_line(rows, cols),
            styled_bulk_lines(rows, cols),
            unicode_bulk_lines(rows, cols),
        )
    )


@st.composite
def resize_delta(draw: st.DrawFn, rows: int, cols: int) -> tuple[int, int, int, int]:
    """Generate a resize delta and resulting dimensions."""
    delta_rows = draw(st.integers(min_value=max(-rows + 1, -10), max_value=15))
    delta_cols = draw(st.integers(min_value=max(-cols + 1, -20), max_value=30))
    new_rows = max(1, rows + delta_rows)
    new_cols = max(1, cols + delta_cols)
    return delta_rows, delta_cols, new_rows, new_cols


@st.composite
def terminal_operation(draw: st.DrawFn, rows: int, cols: int) -> tuple[dict[str, object], int, int]:
    """Generate one terminal operation (write or resize) and return (op, new_rows, new_cols)."""
    is_resize = draw(st.booleans())
    if is_resize:
        delta_rows, delta_cols, new_rows, new_cols = draw(resize_delta(rows, cols))
        return resize_op(delta_rows, delta_cols), new_rows, new_cols
    return write_op(draw(write_chunk(rows, cols))), rows, cols


@st.composite
def fragmented_write_ops(draw: st.DrawFn, rows: int, cols: int) -> list[dict[str, object]]:
    """Generate a complete escape/text chunk split across multiple writes."""
    data = draw(
        st.one_of(
            small_terminal_chunk(rows, cols),
            osc_sequence(),
            sgr_sequence(),
            cursor_sequence(rows, cols),
            erase_sequence(),
            edit_sequence(),
            mode_sequence(),
        )
    )
    if len(data) < 2:
        return [write_op(data)]
    split_count = draw(st.integers(min_value=1, max_value=min(4, len(data) - 1)))
    split_points = draw(
        st.lists(
            st.integers(min_value=1, max_value=len(data) - 1),
            min_size=split_count,
            max_size=split_count,
            unique=True,
        )
    )
    parts = []
    start = 0
    for stop in sorted(split_points):
        parts.append(write_op(data[start:stop]))
        start = stop
    parts.append(write_op(data[start:]))
    return parts


@st.composite
def terminal_motif(
    draw: st.DrawFn, rows: int, cols: int
) -> tuple[list[dict[str, object]], int, int]:
    """Generate one composable terminal-state motif."""
    kind = draw(
        st.sampled_from(
            [
                "single",
                "single",
                "single",
                "fragmented",
                "osc_span",
                "mode_flip",
                "mode_flip",
                "alt_screen_cycle",
                "alt_screen_cycle",
                "scroll_region_cycle",
                "save_resize_restore",
                "style_span",
            ]
        )
    )

    if kind == "single":
        op, new_rows, new_cols = draw(terminal_operation(rows, cols))
        return [op], new_rows, new_cols

    if kind == "fragmented":
        return draw(fragmented_write_ops(rows, cols)), rows, cols

    if kind == "osc_span":
        body = draw(st.one_of(ascii_text(max_size=80), unicode_text()))
        return [write_op(draw(osc_sequence())), write_op(body)], rows, cols

    if kind == "mode_flip":
        private = draw(st.booleans())
        mode = draw(st.sampled_from(DEC_PRIVATE_MODES if private else ANSI_MODES))
        private_prefix = "?" if private else ""
        body = draw(write_chunk(rows, cols))
        return [
            write_op(csi(str(mode), "h", private_prefix)),
            write_op(body),
            write_op(csi(str(mode), "l", private_prefix)),
        ], rows, cols

    if kind == "alt_screen_cycle":
        body = draw(
            st.one_of(medium_lines(rows, cols), small_terminal_chunk(rows, cols), unicode_text())
        )
        maybe_resize = draw(st.booleans())
        ops: list[dict[str, object]] = [write_op(b"\x1b[?1049h\x1b[H\x1b[2J"), write_op(body)]
        new_rows, new_cols = rows, cols
        if maybe_resize:
            delta_rows, delta_cols, new_rows, new_cols = draw(resize_delta(rows, cols))
            ops.append(resize_op(delta_rows, delta_cols))
            ops.append(write_op(b"\x1b[H" + draw(medium_lines(new_rows, new_cols))))
        ops.append(write_op(b"\x1b[?1049l"))
        return ops, new_rows, new_cols

    if kind == "scroll_region_cycle":
        top = draw(st.integers(min_value=1, max_value=max(rows, 1)))
        bottom = draw(st.integers(min_value=top, max_value=max(rows, top)))
        scrolls = draw(
            st.lists(
                st.sampled_from([b"\n", b"\x1bD", b"\x1bM", b"\x1b[1S", b"\x1b[1T"]),
                min_size=1,
                max_size=12,
            )
        )
        return [
            write_op(f"\x1b[{top};{bottom}r\x1b[{bottom};1H".encode("ascii")),
            write_op(b"".join(scrolls)),
            write_op(b"\x1b[r"),
        ], rows, cols

    if kind == "save_resize_restore":
        delta_rows, delta_cols, new_rows, new_cols = draw(resize_delta(rows, cols))
        body = draw(write_chunk(new_rows, new_cols))
        save, restore = draw(
            st.sampled_from(
                [
                    (b"\x1b7", b"\x1b8"),
                    (b"\x1b[s", b"\x1b[u"),
                    (b"\x1b[?1048h", b"\x1b[?1048l"),
                ]
            )
        )
        return [
            write_op(save),
            resize_op(delta_rows, delta_cols),
            write_op(body),
            write_op(restore),
        ], new_rows, new_cols

    if kind == "style_span":
        prefix = draw(sgr_sequence())
        body = draw(st.one_of(ascii_text(max_size=200), unicode_text(), medium_lines(rows, cols)))
        suffix = draw(st.sampled_from([b"\x1b[0m", b"\x1b[39;49m", b"\x1b[m"]))
        return [write_op(prefix + body + suffix)], rows, cols

    raise AssertionError(f"unhandled generated motif: {kind}")


@st.composite
def redraw_batch(draw: st.DrawFn, rows: int, cols: int) -> list[dict[str, object]]:
    """Generate [0-N writes/resizes/motifs, redraw]."""
    ops: list[dict[str, object]] = []
    current_rows, current_cols = rows, cols

    op_count = draw(
        st.one_of(
            st.just(0),
            st.integers(min_value=1, max_value=3),
            st.integers(min_value=1, max_value=4),
            st.integers(min_value=3, max_value=5),
        )
    )
    for _ in range(op_count):
        new_ops, current_rows, current_cols = draw(
            terminal_motif(current_rows, current_cols)
        )
        ops.extend(new_ops)

    ops.append({"op": "redraw"})
    return ops


@st.composite
def render_case(draw: st.DrawFn) -> RenderCase:
    """Generate one complete render consistency test case."""
    rows = draw(
        st.one_of(
            st.integers(min_value=1, max_value=5),
            st.integers(min_value=6, max_value=40),
        )
    )
    cols = draw(
        st.one_of(
            st.integers(min_value=1, max_value=20),
            st.integers(min_value=21, max_value=160),
        )
    )
    scrollback = draw(
        st.sampled_from(
            [
                0,
                1,
                512,
                4 * 1024,
                16 * 1024,
                64 * 1024,
                256 * 1024,
                1024 * 1024,
                5 * 1024 * 1024,
            ]
        )
    )
    batch_count = draw(
        st.one_of(
            st.integers(min_value=1, max_value=5),
            st.integers(min_value=1, max_value=8),
            st.integers(min_value=6, max_value=12),
            st.integers(min_value=10, max_value=18),
            st.integers(min_value=19, max_value=30),
        )
    )
    ops: list[dict[str, object]] = []
    for _ in range(batch_count):
        ops.extend(draw(redraw_batch(rows, cols)))
    payload = {"rows": rows, "cols": cols, "scrollback": scrollback, "ops": ops}
    return RenderCase.from_payload(payload)

def write_bytes(op: dict[str, str]) -> int:
    """Return decoded byte length for a write op, or 0 for redraw."""
    if op.get("op") != "write":
        return 0
    return len(base64.b64decode(op["data"]))


def write_data(op: dict[str, object]) -> bytes:
    """Return decoded write payload bytes, or empty bytes for non-writes."""
    if op.get("op") != "write":
        return b""
    data = op.get("data")
    if not isinstance(data, str):
        return b""
    return base64.b64decode(data)


def unterminated_osc(data: bytes) -> bool:
    """Return whether DATA appears to end inside an OSC sequence."""
    start = data.rfind(b"\x1b]")
    if start < 0:
        return False
    tail = data[start + 2 :]
    return b"\x07" not in tail and b"\x1b\\" not in tail


def bytes_feature_counts(data: bytes) -> collections.Counter[str]:
    """Return semantic feature counts for one terminal write payload."""
    counts: collections.Counter[str] = collections.Counter()
    if not data:
        return counts
    if any(byte < 32 and byte != 27 for byte in data):
        counts["control"] += 1
    if data.startswith(b"\x1b") or b"\x1b[" in data or b"\x1b]" in data:
        counts["escape"] += 1
    if b"\x1b]" in data:
        counts["osc"] += data.count(b"\x1b]")
    for marker, name in [
        (b"\x1b]7;", "osc7"),
        (b"\x1b]8;", "osc8"),
        (b"\x1b]52;", "osc52"),
        (b"\x1b]133;", "osc133"),
        (b"\x1b]633;", "osc633"),
    ]:
        if marker in data:
            counts[name] += data.count(marker)
    if b"\x1b[" in data and b"m" in data:
        counts["sgr"] += data.count(b"m")
    if b";5;" in data and b"m" in data:
        counts["indexed_color"] += 1
    if b";2;" in data and b"m" in data:
        counts["truecolor"] += 1
    if b"\x1b[?" in data and (b"h" in data or b"l" in data):
        counts["dec_mode"] += data.count(b"\x1b[?")
    if any(marker in data for marker in [b"?47", b"?1047", b"?1048", b"?1049"]):
        counts["alt_or_cursor_save_mode"] += 1
    if b"?1049h" in data and b"?1049l" in data:
        counts["alt_screen_cycle"] += 1
    if b"?25" in data:
        counts["cursor_visibility"] += 1
    if b"?2004" in data:
        counts["bracketed_paste"] += 1
    if b"?2026" in data:
        counts["sync_output"] += 1
    if b"\x1b[" in data and any(final in data for final in b"rs"):
        counts["scroll_or_margin"] += 1
    if b"\x1b[" in data and any(final in data for final in b"HfABCDEFG`adeIZ"):
        counts["cursor_motion"] += 1
    if b"\x1b[" in data and any(final in data for final in b"JK"):
        counts["erase"] += 1
    if b"\x1b[" in data and any(final in data for final in b"@PXLMS Tb".replace(b" ", b"")):
        counts["edit_or_scroll"] += 1
    if any(marker in data for marker in [b"\x1b7", b"\x1b8", b"\x1b[s", b"\x1b[u"]):
        counts["save_restore"] += 1
    if any(marker in data for marker in [b"\x1b(B", b"\x1b(0", b"\x0e", b"\x0f"]):
        counts["charset"] += 1
    if unterminated_osc(data) or data in {b"\x1b", b"\x1b[", b"\x1b[?", b"\x1b[38;2;"}:
        counts["incomplete_escape"] += 1
    try:
        decoded = data.decode("utf-8")
    except UnicodeDecodeError:
        decoded = ""
    if any(ord(ch) > 127 for ch in decoded):
        counts["unicode"] += 1
    if any(ch in decoded for ch in ["\u0301", "\u0308", "\ufe0f", "\ufe0e", "\u200d"]):
        counts["unicode_edge"] += 1
    if len(data) >= 4096:
        counts["large_write"] += 1
    return counts


class RenderCase:
    """Generated render case with a compact verbose-mode representation."""

    def __init__(
        self,
        payload: dict[str, object],
        total_bytes: int,
        write_count: int,
        redraw_count: int,
        resize_count: int,
        feature_counts: collections.Counter[str],
    ) -> None:
        self.payload = payload
        self.total_bytes = total_bytes
        self.write_count = write_count
        self.redraw_count = redraw_count
        self.resize_count = resize_count
        self.feature_counts = feature_counts

    @classmethod
    def from_payload(cls, payload: dict[str, object]) -> RenderCase:
        """Return a render case with metrics computed from PAYLOAD."""
        ops = payload["ops"]
        if not isinstance(ops, list):
            raise TypeError(f"case ops must be a list, got {type(ops).__name__}")
        write_count = sum(
            1 for op in ops if isinstance(op, dict) and op.get("op") == "write"
        )
        redraw_count = sum(
            1 for op in ops if isinstance(op, dict) and op.get("op") == "redraw"
        )
        resize_count = sum(
            1 for op in ops if isinstance(op, dict) and op.get("op") == "resize"
        )
        total_bytes = sum(write_bytes(op) for op in ops if isinstance(op, dict))
        feature_counts: collections.Counter[str] = collections.Counter()
        for op in ops:
            if isinstance(op, dict):
                feature_counts.update(bytes_feature_counts(write_data(op)))
        if payload.get("scrollback") in {0, 1, 512, 4 * 1024}:
            feature_counts["tiny_scrollback"] += 1
        if payload.get("rows") in {1, 2} or payload.get("cols") in {1, 2}:
            feature_counts["tiny_dimensions"] += 1
        return cls(
            payload,
            total_bytes,
            write_count,
            redraw_count,
            resize_count,
            feature_counts,
        )

    def __repr__(self) -> str:
        return (
            "RenderCase("
            f"rows={self.payload['rows']}, "
            f"cols={self.payload['cols']}, "
            f"scrollback={self.payload['scrollback']}, "
            f"ops={len(self.payload['ops'])}, "
            f"writes={self.write_count}, "
            f"resizes={self.resize_count}, "
            f"redraws={self.redraw_count}, "
            f"bytes={self.total_bytes}, "
            f"features={dict(self.feature_counts.most_common(8))}"
            ")"
        )


def case_json(case: dict[str, object]) -> str:
    """Return CASE encoded as compact JSON."""
    return json.dumps(case, ensure_ascii=False, separators=(",", ":"))


def case_digest(case: RenderCase) -> str:
    """Return a stable short digest for CASE."""
    return hashlib.sha256(case_json(case.payload).encode("utf-8")).hexdigest()[:16]


def save_regression_case(case: RenderCase) -> Path:
    """Save CASE in the committed regression corpus and return its path."""
    CASES_DIR.mkdir(parents=True, exist_ok=True)
    path = CASES_DIR / f"render-{case_digest(case)}.json"
    path.write_text(case_json(case.payload) + "\n", encoding="utf-8")
    return path


def load_render_case(path: Path) -> RenderCase:
    """Load one saved render regression case from PATH."""
    with path.open(encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise TypeError(f"case file {path} must contain a JSON object")
    return RenderCase.from_payload(payload)


def saved_case_files() -> list[Path]:
    """Return saved render regression case files."""
    return sorted(CASES_DIR.glob("*.json"))


def first_difference(left: str, right: str) -> Optional[int]:
    """Return first differing character offset, or None if strings match."""
    for index, (left_ch, right_ch) in enumerate(zip(left, right)):
        if left_ch != right_ch:
            return index
    if len(left) != len(right):
        return min(len(left), len(right))
    return None


def line_col(text: str, offset: int) -> tuple[int, int]:
    """Return 1-based line/column for OFFSET in TEXT."""
    clamped = max(0, min(offset, len(text)))
    line = text.count("\n", 0, clamped) + 1
    line_start = text.rfind("\n", 0, clamped) + 1
    return line, clamped - line_start + 1


def char_label(text: str, offset: int) -> str:
    """Return a compact label for the character at OFFSET in TEXT."""
    if offset >= len(text):
        return "<end>"
    ch = text[offset]
    if ch == "\n":
        return "<LF>"
    if ch == "\r":
        return "<CR>"
    if ch == "\t":
        return "<TAB>"
    return repr(ch)


def elided_context(text: str, offset: int, radius: int = 120) -> str:
    """Return context around OFFSET with newlines removed for readability."""
    start = max(0, offset - radius)
    end = min(len(text), offset + radius)
    prefix = "…" if start > 0 else ""
    suffix = "…" if end < len(text) else ""
    return prefix + text[start:end].replace("\r", "").replace("\n", "") + suffix


def write_failure_artifacts(
    case: RenderCase,
    incremental: Optional[str],
    full: Optional[str],
) -> tuple[Path, Path]:
    """Write replay/debug artifacts and save CASE to the regression corpus."""
    saved_case = save_regression_case(case)
    FAILURE_ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)
    (FAILURE_ARTIFACTS_DIR / "case.json").write_text(
        case_json(case.payload) + "\n", encoding="utf-8"
    )
    (FAILURE_ARTIFACTS_DIR / "summary.txt").write_text(
        repr(case) + "\n", encoding="utf-8"
    )
    if incremental is not None:
        (FAILURE_ARTIFACTS_DIR / "incremental.txt").write_text(
            incremental, encoding="utf-8"
        )
    if full is not None:
        (FAILURE_ARTIFACTS_DIR / "full.txt").write_text(full, encoding="utf-8")
    return FAILURE_ARTIFACTS_DIR, saved_case


def failure_visualization(incremental: str, full: str) -> list[str]:
    """Return a compact mismatch visualization with newlines elided."""
    offset = first_difference(incremental, full)
    if offset is None:
        return ["snapshots compare equal"]
    inc_line, inc_col = line_col(incremental, offset)
    full_line, full_col = line_col(full, offset)
    return [
        f"first diff at char {offset}:",
        f"  incremental line {inc_line}, col {inc_col}, char {char_label(incremental, offset)}",
        f"  full        line {full_line}, col {full_col}, char {char_label(full, offset)}",
        "  context newlines elided:",
        f"  incremental: {elided_context(incremental, offset)}",
        f"  full:        {elided_context(full, offset)}",
    ]


class EmacsGhostelRunner:
    """Long-lived Emacs process that runs generated render cases."""

    def __init__(self) -> None:
        cmd = [
            EMACS,
            "--batch",
            *EMACSFLAGS,
            "-Q",
            "-L",
            "lisp",
            "-L",
            "test",
            "-l",
            "test/ghostel-test-helpers.el",
            "-l",
            "test/hypothesis/ghostel-hypothesis-driver.el",
            "--eval",
            "(ghostel-hypothesis-serve)",
        ]
        self.proc = subprocess.Popen(
            cmd,
            cwd=REPO_ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        assert self.proc.stdout is not None
        assert self.proc.stdin is not None
        assert self.proc.stderr is not None
        self._selector = selectors.DefaultSelector()
        self._selector.register(self.proc.stdout, selectors.EVENT_READ)
        self._stderr_tail: collections.deque[str] = collections.deque(maxlen=200)
        self._stderr_thread = threading.Thread(target=self._read_stderr, daemon=True)
        self._stderr_thread.start()
        ready = self._read_json_line(timeout=CASE_TIMEOUT)
        if ready.get("ready") is not True:
            raise RuntimeError(f"unexpected Emacs protocol greeting: {ready!r}")

    def close(self) -> None:
        """Terminate the Emacs process."""
        if self.proc.poll() is None:
            try:
                assert self.proc.stdin is not None
                self.proc.stdin.close()
            except OSError:
                pass
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()

    def run_case(self, case: RenderCase) -> dict[str, object]:
        """Send CASE to Emacs and return its JSON response."""
        if self.proc.poll() is not None:
            raise RuntimeError(
                f"Emacs exited with {self.proc.returncode}. stderr tail:\n{self.stderr_tail()}"
            )
        payload = case_json(case.payload)
        assert self.proc.stdin is not None
        self.proc.stdin.write(payload + "\n")
        self.proc.stdin.flush()
        return self._read_json_line(timeout=CASE_TIMEOUT)

    def stderr_tail(self) -> str:
        """Return recent Emacs stderr output."""
        return "".join(self._stderr_tail)

    def _read_stderr(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            self._stderr_tail.append(line)

    def _read_json_line(self, timeout: float) -> dict[str, object]:
        assert self.proc.stdout is not None
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(
                    f"timed out waiting for Emacs. stderr tail:\n{self.stderr_tail()}"
                )
            events = self._selector.select(remaining)
            if not events:
                continue
            line = self.proc.stdout.readline()
            if line == "":
                raise RuntimeError(
                    f"Emacs stdout closed with {self.proc.poll()}. "
                    f"stderr tail:\n{self.stderr_tail()}"
                )
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                # Ignore non-protocol output defensively; warnings should go to
                # stderr, but this keeps the protocol robust if Emacs prints one.
                continue
            if isinstance(value, dict):
                return value


def remember_failure_case(
    test: unittest.TestCase,
    case: RenderCase,
    incremental: Optional[str],
    full: Optional[str],
) -> None:
    """Remember CASE as the latest failing generated case for TEST."""
    setattr(test, "_ghostel_hypothesis_failure", (case, incremental, full))


def assert_render_case_ok(
    test: unittest.TestCase,
    runner: EmacsGhostelRunner,
    case: RenderCase,
    label: str,
    *,
    save_artifacts: bool = True,
) -> None:
    """Fail TEST if CASE does not preserve content across a full redraw."""
    try:
        result = runner.run_case(case)
    except Exception as exc:  # pragma: no cover - exercised by failing cases
        if not save_artifacts:
            remember_failure_case(test, case, None, None)
            test.fail(f"Emacs failed while running {label}: {exc}")
        failure_dir, saved_case = write_failure_artifacts(case, None, None)
        test.fail(
            "\n".join(
                [
                    f"Emacs failed while running {label}: {exc}",
                    f"saved regression case: {saved_case}",
                    f"failure artifacts: {failure_dir}",
                    f"  case:        {failure_dir / 'case.json'}",
                    f"stderr tail:\n{runner.stderr_tail()}",
                ]
            )
        )

    if result.get("ok") is True:
        return

    message = [f"Emacs reported render failure for {label}: {result.get('kind')}"]
    incremental = None
    full = None
    if "error" in result:
        message.append(str(result["error"]))
    if "incremental" in result and "full" in result:
        incremental = base64.b64decode(str(result["incremental"])).decode(
            "utf-8", "replace"
        )
        full = base64.b64decode(str(result["full"])).decode("utf-8", "replace")
        message.extend(failure_visualization(incremental, full))
    if not save_artifacts:
        remember_failure_case(test, case, incremental, full)
        message.append(f"stderr tail:\n{runner.stderr_tail()}")
        test.fail("\n".join(message))
    failure_dir, saved_case = write_failure_artifacts(case, incremental, full)
    message.append(f"saved regression case: {saved_case}")
    message.append(f"failure artifacts: {failure_dir}")
    message.append(f"  case:        {failure_dir / 'case.json'}")
    if incremental is not None and full is not None:
        message.append(f"  incremental: {failure_dir / 'incremental.txt'}")
        message.append(f"  full:        {failure_dir / 'full.txt'}")
    message.append(f"stderr tail:\n{runner.stderr_tail()}")
    test.fail("\n".join(message))


class RenderSavedCaseRegressionTest(unittest.TestCase):
    """Regression tests for cases saved from prior Hypothesis failures."""

    runner: EmacsGhostelRunner
    case_files: list[Path]

    @classmethod
    def setUpClass(cls) -> None:
        cls.case_files = saved_case_files()
        if not cls.case_files:
            raise unittest.SkipTest(f"no saved Hypothesis cases in {CASES_DIR}")
        cls.runner = EmacsGhostelRunner()

    @classmethod
    def tearDownClass(cls) -> None:
        runner = getattr(cls, "runner", None)
        if runner is not None:
            runner.close()

    def test_saved_render_cases(self) -> None:
        """Saved failing cases must remain fixed."""
        for case_file in self.case_files:
            with self.subTest(case=str(case_file)):
                assert_render_case_ok(
                    self,
                    self.runner,
                    load_render_case(case_file),
                    str(case_file),
                )


class RenderConsistencyPropertyTest(unittest.TestCase):
    """Property tests for incremental vs full redraw content."""

    runner: EmacsGhostelRunner

    @classmethod
    def setUpClass(cls) -> None:
        cls.runner = EmacsGhostelRunner()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.runner.close()

    def test_full_redraw_does_not_change_buffer_content(self) -> None:
        """A full redraw after incremental redraws must preserve buffer text."""
        if hasattr(self, "_ghostel_hypothesis_failure"):
            delattr(self, "_ghostel_hypothesis_failure")
        try:
            self._check_full_redraw_does_not_change_buffer_content()
        except Exception as exc:
            failure = getattr(self, "_ghostel_hypothesis_failure", None)
            if failure is None:
                raise
            case, incremental, full = failure
            failure_dir, saved_case = write_failure_artifacts(case, incremental, full)
            message = [
                str(exc),
                "",
                f"saved regression case: {saved_case}",
                f"failure artifacts: {failure_dir}",
                f"  case:        {failure_dir / 'case.json'}",
            ]
            if incremental is not None and full is not None:
                message.append(f"  incremental: {failure_dir / 'incremental.txt'}")
                message.append(f"  full:        {failure_dir / 'full.txt'}")
            raise AssertionError("\n".join(message)) from exc

    @settings(
        max_examples=MAX_EXAMPLES,
        deadline=None,
        suppress_health_check=[HealthCheck.too_slow, HealthCheck.data_too_large],
        verbosity=Verbosity.verbose,
    )
    @given(case=render_case())
    def _check_full_redraw_does_not_change_buffer_content(
        self, case: RenderCase
    ) -> None:
        """Check one generated render case."""
        ops = case.payload["ops"]
        assert isinstance(ops, list)

        target(min(case.total_bytes, 1024 * 1024), label="input bytes capped")
        target(min(case.write_count, 50), label="write ops capped")
        target(min(case.resize_count, 20), label="resize ops capped")
        target(min(case.redraw_count, 15), label="redraw checkpoints capped")
        target(min(sum(case.feature_counts.values()), 150), label="escape/state features capped")
        target(min(case.feature_counts["dec_mode"], 12), label="DEC mode changes capped")
        target(min(case.feature_counts["osc"], 8), label="OSC sequences capped")
        target(
            min(case.feature_counts["scroll_or_margin"], 10),
            label="scroll/margin sequences capped",
        )
        target(
            min(case.feature_counts["incomplete_escape"], 5),
            label="fragmented/incomplete escapes capped",
        )
        event(f"bytes={case.total_bytes.bit_length()} bits")
        event(f"writes={case.write_count}")
        event(f"resizes={case.resize_count}")
        event(f"redraws={case.redraw_count}")
        for feature in sorted(case.feature_counts):
            event(f"feature:{feature}")
        note(repr(case))

        assert_render_case_ok(
            self, self.runner, case, repr(case), save_artifacts=False
        )


if __name__ == "__main__":
    unittest.main()
