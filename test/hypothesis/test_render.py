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
CONTROL_CHUNKS = [b"\n", b"\r", b"\r\n", b"\t", b"\b"]
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
    7,
    9,
    22,
    23,
    24,
    27,
    29,
    *range(30, 38),
    *range(40, 48),
    *range(90, 98),
    *range(100, 108),
]


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
    """Generate sizes with deliberate mass in the medium/large ranges."""
    return st.one_of(
        st.integers(*small),
        st.integers(*medium),
        st.integers(*medium),
        st.integers(*large),
    )


def ascii_text() -> st.SearchStrategy[bytes]:
    """Generate small printable ASCII text bytes."""
    return st.lists(st.sampled_from(TEXT_BYTES), min_size=1, max_size=120).map(bytes)


def unicode_text() -> st.SearchStrategy[bytes]:
    """Generate a small valid UTF-8 text chunk."""
    return st.lists(st.sampled_from(UNICODE_CHARS), min_size=1, max_size=60).map(
        lambda chars: "".join(chars).encode("utf-8")
    )


def control_text() -> st.SearchStrategy[bytes]:
    """Generate C0 text controls that terminals commonly receive."""
    return st.lists(st.sampled_from(CONTROL_CHUNKS), min_size=1, max_size=80).map(
        b"".join
    )


@st.composite
def bulk_lines(draw: st.DrawFn, rows: int, cols: int) -> bytes:
    """Generate many newline-terminated rows to cross page/scrollback limits."""
    line_count = draw(size_strategy((1, 20), (40, 260), (216, 900)))
    width = draw(size_strategy((0, max(cols, 1)), (cols, max(cols * 4, 80)), (80, 800)))
    pattern = draw(st.sampled_from(BULK_PATTERNS))
    newline = draw(st.sampled_from([b"\n", b"\r\n"]))
    parts = []
    for i in range(line_count):
        prefix = f"{i:05d}: ".encode("ascii")
        parts.append(prefix + repeated(pattern, width) + newline)
    return b"".join(parts)


@st.composite
def long_wrapped_line(draw: st.DrawFn, rows: int, cols: int) -> bytes:
    """Generate a long line that wraps over many terminal rows."""
    del rows
    length = draw(size_strategy((1, max(cols * 2, 16)), (512, 8192), (8192, 65536)))
    pattern = draw(st.sampled_from(BULK_PATTERNS))
    suffix = draw(st.sampled_from([b"", b"\n", b"\r\n"]))
    return repeated(pattern, length) + suffix


@st.composite
def styled_bulk_lines(draw: st.DrawFn, rows: int, cols: int) -> bytes:
    """Generate bulk rows with frequent style changes."""
    line_count = draw(size_strategy((1, 20), (30, 220), (216, 600)))
    width = draw(size_strategy((1, max(cols, 1)), (cols, max(cols * 3, 80)), (80, 400)))
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
    """Generate bulk rows containing wide and multibyte characters."""
    del rows
    line_count = draw(size_strategy((1, 12), (20, 120), (120, 360)))
    width = draw(size_strategy((1, max(cols, 1)), (cols, max(cols * 2, 80)), (80, 240)))
    text = "λ界🙂┌─┐✓"
    repeated_text = (text * ((width // len(text)) + 1))[:width]
    return "".join(f"{i:05d}: {repeated_text}\r\n" for i in range(line_count)).encode(
        "utf-8"
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
                "cup",
                "cursor_rel",
                "erase",
                "mode",
                "scroll_region",
                "osc_title",
                "save_restore",
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
        codes = draw(st.lists(st.sampled_from(SGR_CODES), min_size=1, max_size=8))
        return b"\x1b[" + ";".join(str(code) for code in codes).encode("ascii") + b"m"
    if kind == "cup":
        row = draw(st.integers(min_value=1, max_value=max(rows, 1)))
        col = draw(st.integers(min_value=1, max_value=max(cols, 1)))
        return f"\x1b[{row};{col}H".encode("ascii")
    if kind == "cursor_rel":
        amount = draw(st.integers(min_value=0, max_value=max(rows, cols, 1) + 20))
        final = draw(st.sampled_from([b"A", b"B", b"C", b"D", b"E", b"F", b"G"]))
        return b"\x1b[" + str(amount).encode("ascii") + final
    if kind == "erase":
        return draw(
            st.sampled_from(
                [
                    b"\x1b[J",
                    b"\x1b[0J",
                    b"\x1b[1J",
                    b"\x1b[2J",
                    b"\x1b[3J",
                    b"\x1b[K",
                    b"\x1b[0K",
                    b"\x1b[1K",
                    b"\x1b[2K",
                ]
            )
        )
    if kind == "mode":
        return draw(
            st.sampled_from(
                [
                    b"\x1b[?25h",
                    b"\x1b[?25l",
                    b"\x1b[?1049h",
                    b"\x1b[?1049l",
                    b"\x1b[?2004h",
                    b"\x1b[?2004l",
                ]
            )
        )
    if kind == "scroll_region":
        top = draw(st.integers(min_value=1, max_value=max(rows, 1)))
        bottom = draw(st.integers(min_value=top, max_value=max(rows, top)))
        return f"\x1b[{top};{bottom}r".encode("ascii")
    if kind == "osc_title":
        title = draw(
            st.text(
                alphabet="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_",
                min_size=0,
                max_size=60,
            )
        )
        terminator = draw(st.sampled_from([b"\x07", b"\x1b\\"]))
        return b"\x1b]2;" + title.encode("utf-8") + terminator
    if kind == "save_restore":
        return draw(st.sampled_from([b"\x1b7", b"\x1b8"]))

    raise AssertionError(f"unhandled generated kind: {kind}")


@st.composite
def write_chunk(draw: st.DrawFn, rows: int, cols: int) -> bytes:
    """Generate one write chunk, biased toward substantial output."""
    return draw(
        st.one_of(
            small_terminal_chunk(rows, cols),
            bulk_lines(rows, cols),
            bulk_lines(rows, cols),
            long_wrapped_line(rows, cols),
            long_wrapped_line(rows, cols),
            styled_bulk_lines(rows, cols),
            unicode_bulk_lines(rows, cols),
        )
    )


@st.composite
def terminal_operation(draw: st.DrawFn, rows: int, cols: int) -> tuple[dict[str, object], int, int]:
    """Generate one terminal operation (write or resize) and return (op, new_rows, new_cols)."""
    is_resize = draw(st.booleans())
    if is_resize:
        delta_rows = draw(st.integers(min_value=max(-rows + 1, -10), max_value=15))
        delta_cols = draw(st.integers(min_value=max(-cols + 1, -20), max_value=30))
        new_rows = max(1, rows + delta_rows)
        new_cols = max(1, cols + delta_cols)
        return resize_op(delta_rows, delta_cols), new_rows, new_cols
    else:
        return write_op(draw(write_chunk(rows, cols))), rows, cols


@st.composite
def redraw_batch(draw: st.DrawFn, rows: int, cols: int) -> list[dict[str, object]]:
    """Generate [0-N writes/resizes, redraw]."""
    ops: list[dict[str, object]] = []
    current_rows, current_cols = rows, cols

    op_count = draw(
        st.one_of(
            st.just(0),
            st.integers(min_value=1, max_value=3),
            st.integers(min_value=1, max_value=3),
            st.integers(min_value=4, max_value=12),
        )
    )
    for _ in range(op_count):
        op, current_rows, current_cols = draw(
            terminal_operation(current_rows, current_cols)
        )
        ops.append(op)

    ops.append({"op": "redraw"})
    return ops


@st.composite
def render_case(draw: st.DrawFn) -> RenderCase:
    """Generate one complete render consistency test case."""
    rows = draw(st.integers(min_value=1, max_value=40))
    cols = draw(st.integers(min_value=1, max_value=160))
    scrollback = draw(
        st.sampled_from(
            [
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
            st.integers(min_value=6, max_value=25),
            st.integers(min_value=6, max_value=25),
            st.integers(min_value=26, max_value=80),
        )
    )
    ops: list[dict[str, str]] = []
    for _ in range(batch_count):
        ops.extend(draw(redraw_batch(rows, cols)))
    payload = {"rows": rows, "cols": cols, "scrollback": scrollback, "ops": ops}
    return RenderCase.from_payload(payload)


def write_bytes(op: dict[str, str]) -> int:
    """Return decoded byte length for a write op, or 0 for redraw."""
    if op.get("op") != "write":
        return 0
    return len(base64.b64decode(op["data"]))


class RenderCase:
    """Generated render case with a compact verbose-mode representation."""

    def __init__(
        self,
        payload: dict[str, object],
        total_bytes: int,
        write_count: int,
        redraw_count: int,
        resize_count: int,
    ) -> None:
        self.payload = payload
        self.total_bytes = total_bytes
        self.write_count = write_count
        self.redraw_count = redraw_count
        self.resize_count = resize_count

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
        return cls(payload, total_bytes, write_count, redraw_count, resize_count)

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
            f"bytes={self.total_bytes}"
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

        target(case.total_bytes, label="input bytes")
        target(case.write_count, label="write ops")
        target(case.resize_count, label="resize ops")
        target(case.redraw_count, label="redraw checkpoints")
        event(f"bytes={case.total_bytes.bit_length()} bits")
        event(f"writes={case.write_count}")
        event(f"resizes={case.resize_count}")
        event(f"redraws={case.redraw_count}")
        note(repr(case))

        assert_render_case_ok(
            self, self.runner, case, repr(case), save_artifacts=False
        )


if __name__ == "__main__":
    unittest.main()
