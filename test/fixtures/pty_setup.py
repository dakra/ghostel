"""Portable terminal setup for PTY integration-test children."""

import os
import sys


def set_raw_stdio():
    """Put standard input in raw/no-echo mode and use binary I/O."""
    if os.name == "nt":
        import ctypes
        import msvcrt
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        get_console_mode = kernel32.GetConsoleMode
        get_console_mode.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
        get_console_mode.restype = wintypes.BOOL
        set_console_mode = kernel32.SetConsoleMode
        set_console_mode.argtypes = (wintypes.HANDLE, wintypes.DWORD)
        set_console_mode.restype = wintypes.BOOL

        stdin_fd = sys.stdin.fileno()
        stdin_handle = msvcrt.get_osfhandle(stdin_fd)
        mode = wintypes.DWORD()
        if not get_console_mode(stdin_handle, ctypes.byref(mode)):
            raise ctypes.WinError(ctypes.get_last_error())

        enable_processed_input = 0x0001
        enable_line_input = 0x0002
        enable_echo_input = 0x0004
        raw_mode = mode.value & ~(
            enable_processed_input | enable_line_input | enable_echo_input
        )
        if not set_console_mode(stdin_handle, raw_mode):
            raise ctypes.WinError(ctypes.get_last_error())

        msvcrt.setmode(stdin_fd, os.O_BINARY)
        msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)
    else:
        import tty

        tty.setraw(sys.stdin.fileno())
