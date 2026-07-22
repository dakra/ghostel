const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const emacs = @import("emacs.zig");

const windows = if (builtin.os.tag == .windows) struct {
    const w32 = std.os.windows;

    const CP_ACP: w32.UINT = 0;
    const MB_ERR_INVALID_CHARS: w32.DWORD = 0x00000008;

    extern "kernel32" fn MultiByteToWideChar(
        code_page: w32.UINT,
        flags: w32.DWORD,
        input: [*]const u8,
        input_len: c_int,
        output: ?[*]u16,
        output_len: c_int,
    ) callconv(.winapi) c_int;

    fn ansiToUtf8AllocZ(allocator: Allocator, bytes: []const u8) ![:0]u8 {
        if (bytes.len == 0) return allocator.dupeZ(u8, "");
        if (bytes.len > std.math.maxInt(c_int)) return error.StringTooLong;

        const wide_len = MultiByteToWideChar(
            CP_ACP,
            MB_ERR_INVALID_CHARS,
            bytes.ptr,
            @intCast(bytes.len),
            null,
            0,
        );
        if (wide_len == 0) return error.InvalidSystemEncoding;

        const wide = try allocator.alloc(u16, @intCast(wide_len));
        defer allocator.free(wide);
        if (MultiByteToWideChar(
            CP_ACP,
            MB_ERR_INVALID_CHARS,
            bytes.ptr,
            @intCast(bytes.len),
            wide.ptr,
            wide_len,
        ) != wide_len) return error.InvalidSystemEncoding;

        return std.unicode.utf16LeToUtf8AllocZ(allocator, wide);
    }
} else struct {};

/// Extract a Lisp string for use as an operating-system process input.
/// On Windows, unibyte strings use the system ANSI code page, while
/// multibyte strings use the module API's UTF-8 representation.
pub fn extractProcessStringAlloc(
    allocator: Allocator,
    env: emacs.Env,
    value: emacs.Value,
) ![:0]u8 {
    var storage: ?[]u8 = null;
    errdefer if (storage) |s| allocator.free(s);
    const bytes = try env.extractStringAlloc(allocator, value, &storage);

    if (builtin.os.tag == .windows) {
        if (env.isNil(env.f("multibyte-string-p", .{value}))) {
            const result = try windows.ansiToUtf8AllocZ(allocator, bytes);
            allocator.free(storage.?);
            return result;
        }
    }
    return bytes;
}
