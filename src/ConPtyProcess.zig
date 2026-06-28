const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("windows.h");
});

const Self = @This();

const HPCON = ?*anyopaque;
const CreatePseudoConsoleFn = *const fn (c.COORD, c.HANDLE, c.HANDLE, u32, *HPCON) callconv(.winapi) c.HRESULT;
const ResizePseudoConsoleFn = *const fn (HPCON, c.COORD) callconv(.winapi) c.HRESULT;
const ClosePseudoConsoleFn = *const fn (HPCON) callconv(.winapi) void;

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const READ_BUFFER_SIZE = 64 * 1024;

// Kept separate from Self because NativeProcess hands this backend by value to
// a detached reaper thread.
const State = struct {
    alloc: Allocator,
    hpc: HPCON = null,
    pty_input: c.HANDLE = c.INVALID_HANDLE_VALUE,
    pty_output: c.HANDLE = c.INVALID_HANDLE_VALUE,
    shell_process: c.HANDLE = c.INVALID_HANDLE_VALUE,
    running: std.atomic.Value(bool) = .init(true),
    forced_stop: std.atomic.Value(bool) = .init(false),
    pid: i64 = -1,
};

state: *State,

var create_pseudo_console: ?CreatePseudoConsoleFn = null;
var resize_pseudo_console: ?ResizePseudoConsoleFn = null;
var close_pseudo_console: ?ClosePseudoConsoleFn = null;

pub const ProcessParams = struct {
    file: [:0]const u8,
    args: [][:0]const u8,
    env: *const std.process.EnvMap,
    cwd: ?[]const u8 = null,
};

pub const EventWriter = struct {
    pub const Fd = c_int;

    const NotifyCrtProvider = enum {
        msvcrt,
        ucrt,
    };

    const NotifyCrtWriteFn = *const fn (c_int, ?*const anyopaque, c_uint) callconv(.c) c_int;
    const NotifyCrtCloseFn = *const fn (c_int) callconv(.c) c_int;
    const NotifyCrt = struct {
        write: NotifyCrtWriteFn,
        close: NotifyCrtCloseFn,
    };

    fd: Fd,
    notify_crt: NotifyCrt,

    var cached_notify_crt: ?NotifyCrt = null;

    pub fn init(fd: Fd) !EventWriter {
        return .{
            .fd = fd,
            .notify_crt = try resolveNotifyCrt(),
        };
    }

    pub fn write(self: *EventWriter, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const chunk_len: c_uint = @intCast(@min(data.len - written, std.math.maxInt(c_uint)));
            const n = self.notify_crt.write(
                self.fd,
                @ptrCast(data[written..].ptr),
                chunk_len,
            );
            if (n <= 0) return error.EventWriteFailed;
            written += @intCast(n);
        }
    }

    pub fn close(self: *EventWriter) void {
        if (self.fd < 0) return;
        _ = self.notify_crt.close(self.fd);
        self.fd = -1;
    }

    pub fn onThreadEnter(_: *EventWriter) void {}

    pub fn onThreadExit() void {}

    fn notifyCrtProviderForImport(dll_name: []const u8, symbol_name: []const u8) ?NotifyCrtProvider {
        if (!std.mem.eql(u8, symbol_name, "_dup")) return null;

        if (std.ascii.eqlIgnoreCase(dll_name, "msvcrt.dll")) return .msvcrt;
        if (std.ascii.eqlIgnoreCase(dll_name, "ucrtbase.dll")) return .ucrt;
        // Newer Emacs builds may link the UCRT through api-ms-win-crt
        // forwarding DLLs rather than importing ucrtbase.dll directly.
        if (std.ascii.startsWithIgnoreCase(dll_name, "api-ms-win-crt-")) return .ucrt;
        return null;
    }

    fn ptrFromRva(comptime T: type, base: usize, rva: c.DWORD) *const T {
        return @ptrFromInt(base + @as(usize, @intCast(rva)));
    }

    fn cStringFromRva(base: usize, rva: c.DWORD) []const u8 {
        const ptr: [*:0]const u8 = @ptrFromInt(base + @as(usize, @intCast(rva)));
        return std.mem.span(ptr);
    }

    fn importDescriptorHasSymbol(base: usize, descriptor: *const c.IMAGE_IMPORT_DESCRIPTOR, symbol_name: []const u8) bool {
        const thunk_rva = if (descriptor.unnamed_0.OriginalFirstThunk != 0)
            descriptor.unnamed_0.OriginalFirstThunk
        else
            descriptor.FirstThunk;
        if (thunk_rva == 0) return false;

        const thunks: [*]const c.IMAGE_THUNK_DATA = @ptrFromInt(base + @as(usize, @intCast(thunk_rva)));
        var i: usize = 0;
        while (thunks[i].u1.AddressOfData != 0) : (i += 1) {
            const address = thunks[i].u1.AddressOfData;
            const ordinal_flag = @as(@TypeOf(address), 1) << (@bitSizeOf(@TypeOf(address)) - 1);
            if ((address & ordinal_flag) != 0) continue;

            const import_by_name = ptrFromRva(c.IMAGE_IMPORT_BY_NAME, base, @intCast(address));
            const name_addr = @intFromPtr(import_by_name) + @offsetOf(c.IMAGE_IMPORT_BY_NAME, "Name");
            const import_name: [*:0]const u8 = @ptrFromInt(name_addr);
            if (std.mem.eql(u8, std.mem.span(import_name), symbol_name)) return true;
        }
        return false;
    }

    fn findNotifyCrtProviderInImage(module: c.HMODULE) ?NotifyCrtProvider {
        const base = @intFromPtr(module);
        const dos = ptrFromRva(c.IMAGE_DOS_HEADER, base, 0);
        if (dos.e_magic != c.IMAGE_DOS_SIGNATURE or dos.e_lfanew < 0) return null;

        const nt: *const c.IMAGE_NT_HEADERS = @ptrFromInt(base + @as(usize, @intCast(dos.e_lfanew)));
        if (nt.Signature != c.IMAGE_NT_SIGNATURE) return null;

        const import_index: usize = @intCast(c.IMAGE_DIRECTORY_ENTRY_IMPORT);
        if (nt.OptionalHeader.NumberOfRvaAndSizes <= import_index) return null;
        const import_directory = nt.OptionalHeader.DataDirectory[import_index];
        if (import_directory.VirtualAddress == 0) return null;

        const descriptors: [*]const c.IMAGE_IMPORT_DESCRIPTOR = @ptrFromInt(base + @as(usize, @intCast(import_directory.VirtualAddress)));
        var i: usize = 0;
        while (descriptors[i].Name != 0) : (i += 1) {
            const dll_name = cStringFromRva(base, descriptors[i].Name);
            if (importDescriptorHasSymbol(base, &descriptors[i], "_dup")) {
                if (notifyCrtProviderForImport(dll_name, "_dup")) |provider| return provider;
            }
        }
        return null;
    }

    fn detectNotifyCrtProvider() !NotifyCrtProvider {
        const module = c.GetModuleHandleW(null) orelse return error.NotifyCrtUnavailable;
        return findNotifyCrtProviderInImage(module) orelse error.NotifyCrtUnavailable;
    }

    fn resolveNotifyCrt() !NotifyCrt {
        if (cached_notify_crt) |crt| return crt;

        const provider = try detectNotifyCrtProvider();
        const dll_name = switch (provider) {
            .msvcrt => std.unicode.utf8ToUtf16LeStringLiteral("msvcrt.dll"),
            .ucrt => std.unicode.utf8ToUtf16LeStringLiteral("ucrtbase.dll"),
        };
        const module = c.GetModuleHandleW(dll_name) orelse return error.NotifyCrtUnavailable;
        const write_proc = c.GetProcAddress(module, "_write") orelse return error.NotifyCrtUnavailable;
        const close_proc = c.GetProcAddress(module, "_close") orelse return error.NotifyCrtUnavailable;
        cached_notify_crt = .{
            .write = @ptrCast(write_proc),
            .close = @ptrCast(close_proc),
        };
        return cached_notify_crt.?;
    }
};

pub fn init(alloc: Allocator, initial_cols: u16, initial_rows: u16, params: ProcessParams) !Self {
    try initApi();

    const state = try alloc.create(State);
    errdefer alloc.destroy(state);
    state.* = .{ .alloc = alloc };

    try createConPty(state, initial_rows, initial_cols);
    errdefer closeConPtyHandles(state);
    try spawnChild(state, params);

    return .{ .state = state };
}

pub fn pidValue(self: *const Self) i64 {
    return self.state.pid;
}

pub fn drain(self: *Self, stream: anytype) !bool {
    var drained = false;
    var buf: [READ_BUFFER_SIZE]u8 = undefined;

    while (self.state.running.load(.acquire)) {
        const available = try peekOutputAvailable(self.state);
        if (available == 0) {
            if (drained) return true;
            if (shellProcessExited(self.state)) {
                stopRunning(self.state);
                return drained;
            }
            // The ConPTY output pipe is polled with PeekNamedPipe; wait briefly
            // on the child process handle to avoid a hot spin while still
            // noticing process exit promptly.
            _ = c.WaitForSingleObject(self.state.shell_process, 10);
            continue;
        }

        var bytes_read: c.DWORD = 0;
        const read_len: c.DWORD = @intCast(@min(buf.len, available));
        if (c.ReadFile(self.state.pty_output, buf[0..].ptr, read_len, &bytes_read, null) == 0) {
            const err = c.GetLastError();
            switch (err) {
                c.ERROR_OPERATION_ABORTED, c.ERROR_BROKEN_PIPE, c.ERROR_INVALID_HANDLE => {
                    stopRunning(self.state);
                    return drained;
                },
                else => return error.ReadFailed,
            }
        }
        if (bytes_read == 0) {
            stopRunning(self.state);
            return drained;
        }
        stream.nextSlice(buf[0..@as(usize, @intCast(bytes_read))]);
        drained = true;
    }

    return drained;
}

fn peekOutputAvailable(state: *State) !c.DWORD {
    if (state.pty_output == c.INVALID_HANDLE_VALUE) return 0;

    var available: c.DWORD = 0;
    if (c.PeekNamedPipe(state.pty_output, null, 0, null, &available, null) == 0) {
        const err = c.GetLastError();
        switch (err) {
            c.ERROR_OPERATION_ABORTED, c.ERROR_BROKEN_PIPE, c.ERROR_INVALID_HANDLE => return 0,
            else => return error.ReadFailed,
        }
    }
    return available;
}

fn shellProcessExited(state: *State) bool {
    if (state.shell_process == c.INVALID_HANDLE_VALUE) return true;
    return c.WaitForSingleObject(state.shell_process, 0) == c.WAIT_OBJECT_0;
}

pub fn write(self: *Self, data: []const u8) !void {
    if (data.len == 0) return;
    if (self.state.pty_input == c.INVALID_HANDLE_VALUE) return error.WriteFailed;

    var offset: usize = 0;
    while (offset < data.len) {
        var wrote: c.DWORD = 0;
        const chunk_len: c.DWORD = @intCast(@min(data.len - offset, std.math.maxInt(c.DWORD)));
        if (c.WriteFile(self.state.pty_input, data[offset..].ptr, chunk_len, &wrote, null) == 0) {
            return error.WriteFailed;
        }
        if (wrote == 0) return error.WriteFailed;
        offset += wrote;
    }
}

pub fn resize(self: *Self, cols: u16, rows: u16) !void {
    if (!self.state.running.load(.acquire)) return error.PtyResizeFailed;
    const hpc = self.state.hpc orelse return error.PtyResizeFailed;
    const size = c.COORD{
        .X = @intCast(cols),
        .Y = @intCast(rows),
    };
    if (resize_pseudo_console.?(hpc, size) < 0) return error.PtyResizeFailed;
}

pub fn requestStop(self: *Self, read_thread: std.Thread) void {
    self.state.forced_stop.store(true, .release);
    stopRunning(self.state);

    if (self.state.pty_input != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(self.state.pty_input);
        self.state.pty_input = c.INVALID_HANDLE_VALUE;
    }

    _ = c.CancelSynchronousIo(read_thread.getHandle());
}

pub fn replicaName(_: *Self) []const u8 {
    return "";
}

pub fn deinitAndWait(self: *Self) u8 {
    const state = self.state;
    stopRunning(state);

    if (state.forced_stop.load(.acquire)) {
        closeConPtyHandles(state);
    }

    var exit_code: c.DWORD = 0;
    if (state.shell_process != c.INVALID_HANDLE_VALUE) {
        _ = c.WaitForSingleObject(state.shell_process, c.INFINITE);
        _ = c.GetExitCodeProcess(state.shell_process, &exit_code);
        _ = c.CloseHandle(state.shell_process);
    }

    closeConPtyHandles(state);

    const alloc = state.alloc;
    alloc.destroy(state);
    return @truncate(exit_code);
}

fn initApi() !void {
    if (create_pseudo_console != null) return;

    const kernel32 = c.GetModuleHandleA("kernel32.dll") orelse return error.MissingConPty;
    create_pseudo_console = @ptrCast(c.GetProcAddress(kernel32, "CreatePseudoConsole") orelse return error.MissingConPty);
    resize_pseudo_console = @ptrCast(c.GetProcAddress(kernel32, "ResizePseudoConsole") orelse return error.MissingConPty);
    close_pseudo_console = @ptrCast(c.GetProcAddress(kernel32, "ClosePseudoConsole") orelse return error.MissingConPty);
}

fn createConPty(state: *State, rows: u16, cols: u16) !void {
    var in_read: c.HANDLE = c.INVALID_HANDLE_VALUE;
    var in_write: c.HANDLE = c.INVALID_HANDLE_VALUE;
    var out_read: c.HANDLE = c.INVALID_HANDLE_VALUE;
    var out_write: c.HANDLE = c.INVALID_HANDLE_VALUE;
    errdefer {
        closeConPtyHandles(state);
        if (in_read != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(in_read);
        if (in_write != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(in_write);
        if (out_read != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(out_read);
        if (out_write != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(out_write);
    }

    var sa = std.mem.zeroes(c.SECURITY_ATTRIBUTES);
    sa.nLength = @sizeOf(c.SECURITY_ATTRIBUTES);
    sa.bInheritHandle = c.TRUE;

    if (c.CreatePipe(&in_read, &in_write, &sa, 0) == 0) return error.CreatePipeFailed;
    if (c.CreatePipe(&out_read, &out_write, &sa, 0) == 0) return error.CreatePipeFailed;

    const size = c.COORD{
        .X = @intCast(cols),
        .Y = @intCast(rows),
    };
    if (create_pseudo_console.?(size, in_read, out_write, 0, &state.hpc) < 0) {
        return error.CreatePseudoConsoleFailed;
    }

    state.pty_input = in_write;
    state.pty_output = out_read;
    _ = c.CloseHandle(in_read);
    _ = c.CloseHandle(out_write);
    in_write = c.INVALID_HANDLE_VALUE;
    out_read = c.INVALID_HANDLE_VALUE;
    in_read = c.INVALID_HANDLE_VALUE;
    out_write = c.INVALID_HANDLE_VALUE;
}

fn closeConPtyHandles(state: *State) void {
    if (state.pty_input != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(state.pty_input);
        state.pty_input = c.INVALID_HANDLE_VALUE;
    }
    if (state.pty_output != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(state.pty_output);
        state.pty_output = c.INVALID_HANDLE_VALUE;
    }
    if (state.hpc != null) {
        // ClosePseudoConsole owns the documented ConPTY teardown path.
        close_pseudo_console.?(state.hpc);
        state.hpc = null;
    }
}

fn spawnChild(state: *State, params: ProcessParams) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(state.alloc);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const command_line = try argvToCommandLineWindows(arena, params.args);
    const cwd = if (params.cwd) |cwd_path|
        try std.unicode.wtf8ToWtf16LeAllocZ(arena, cwd_path)
    else
        null;
    const env_block = try buildEnvironmentBlock(arena, params.env);

    var attr_list_size: usize = 0;
    _ = c.InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size);
    const attr_list_buf = try arena.alloc(u8, attr_list_size);

    var si = std.mem.zeroes(c.STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(c.STARTUPINFOEXW);
    si.lpAttributeList = @ptrCast(@alignCast(attr_list_buf.ptr));
    if (c.InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_list_size) == 0) {
        return error.InitializeProcThreadAttributeListFailed;
    }
    defer c.DeleteProcThreadAttributeList(si.lpAttributeList);

    if (c.UpdateProcThreadAttribute(
        si.lpAttributeList,
        0,
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        state.hpc,
        @sizeOf(HPCON),
        null,
        null,
    ) == 0) {
        return error.UpdateProcThreadAttributeFailed;
    }

    var pi = std.mem.zeroes(c.PROCESS_INFORMATION);
    const flags = c.EXTENDED_STARTUPINFO_PRESENT | c.CREATE_UNICODE_ENVIRONMENT;
    if (c.CreateProcessW(
        null,
        command_line.ptr,
        null,
        null,
        c.FALSE,
        flags,
        @ptrCast(env_block.ptr),
        if (cwd) |cwd_w| cwd_w.ptr else null,
        &si.StartupInfo,
        &pi,
    ) == 0) {
        return error.CreateProcessFailed;
    }

    state.shell_process = pi.hProcess;
    state.pid = @intCast(pi.dwProcessId);
    _ = c.CloseHandle(pi.hThread);
}

fn argvToCommandLineWindows(
    allocator: Allocator,
    argv: []const [:0]const u8,
) ![:0]u16 {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    if (argv.len != 0) {
        const arg0 = argv[0];

        var needs_quotes = arg0.len == 0;
        for (arg0) |ch| {
            if (ch <= ' ') {
                needs_quotes = true;
            } else if (ch == '"') {
                return error.InvalidArg0;
            }
        }
        if (needs_quotes) {
            try buf.append('"');
            try buf.appendSlice(arg0);
            try buf.append('"');
        } else {
            try buf.appendSlice(arg0);
        }

        for (argv[1..]) |arg| {
            try buf.append(' ');

            needs_quotes = for (arg) |ch| {
                if (ch <= ' ' or ch == '"') {
                    break true;
                }
            } else arg.len == 0;
            if (!needs_quotes) {
                try buf.appendSlice(arg);
                continue;
            }

            try buf.append('"');
            var backslash_count: usize = 0;
            for (arg) |byte| {
                switch (byte) {
                    '\\' => {
                        backslash_count += 1;
                    },
                    '"' => {
                        try buf.appendNTimes('\\', backslash_count * 2 + 1);
                        try buf.append('"');
                        backslash_count = 0;
                    },
                    else => {
                        try buf.appendNTimes('\\', backslash_count);
                        try buf.append(byte);
                        backslash_count = 0;
                    },
                }
            }
            try buf.appendNTimes('\\', backslash_count * 2);
            try buf.append('"');
        }
    }

    return try std.unicode.wtf8ToWtf16LeAllocZ(allocator, buf.items);
}

fn buildEnvironmentBlock(arena: Allocator, env_map: *const std.process.EnvMap) ![]u16 {
    var builder = std.ArrayList(u16).empty;
    errdefer builder.deinit(arena);

    var it = env_map.iterator();
    while (it.next()) |pair| {
        try appendWtf8AsWtf16(&builder, arena, pair.key_ptr.*);
        try builder.append(arena, '=');
        try appendWtf8AsWtf16(&builder, arena, pair.value_ptr.*);
        try builder.append(arena, 0);
    }
    try builder.append(arena, 0);
    return try builder.toOwnedSlice(arena);
}

fn appendWtf8AsWtf16(builder: *std.ArrayList(u16), arena: Allocator, value: []const u8) !void {
    const len = try std.unicode.calcWtf16LeLen(value);
    const dest = try builder.addManyAsSlice(arena, len);
    const written = try std.unicode.wtf8ToWtf16Le(dest, value);
    std.debug.assert(written == len);
}

fn stopRunning(state: *State) void {
    state.running.store(false, .release);
}

test "notify CRT provider follows the CRT that owns Emacs dup" {
    try std.testing.expectEqual(
        EventWriter.NotifyCrtProvider.msvcrt,
        EventWriter.notifyCrtProviderForImport("msvcrt.dll", "_dup").?,
    );
    try std.testing.expectEqual(
        EventWriter.NotifyCrtProvider.ucrt,
        EventWriter.notifyCrtProviderForImport("api-ms-win-crt-stdio-l1-1-0.dll", "_dup").?,
    );
    try std.testing.expectEqual(
        EventWriter.NotifyCrtProvider.ucrt,
        EventWriter.notifyCrtProviderForImport("ucrtbase.dll", "_dup").?,
    );
}

test "notify CRT provider ignores non-dup CRT imports" {
    try std.testing.expectEqual(
        @as(?EventWriter.NotifyCrtProvider, null),
        EventWriter.notifyCrtProviderForImport("msvcrt.dll", "_write"),
    );
    try std.testing.expectEqual(
        @as(?EventWriter.NotifyCrtProvider, null),
        EventWriter.notifyCrtProviderForImport("kernel32.dll", "_dup"),
    );
}

test "buildEnvironmentBlock writes nul-separated UTF-16 entries" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("FOO", "bar");

    const block = try buildEnvironmentBlock(std.testing.allocator, &env);
    defer std.testing.allocator.free(block);

    try std.testing.expectEqualSlices(u16, &[_]u16{
        'F', 'O', 'O', '=', 'b', 'a', 'r', 0,
        0,
    }, block);
}

test "EnvMap keeps environment names unique on Windows" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("Path", "first");
    try env.put("PATH", "second");

    try std.testing.expectEqual(@as(std.process.EnvMap.Size, 1), env.count());
    try std.testing.expectEqualStrings("second", env.get("path").?);
}
