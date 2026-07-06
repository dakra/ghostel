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

hpc: HPCON = null,
pty_input: c.HANDLE = c.INVALID_HANDLE_VALUE,
pty_output: c.HANDLE = c.INVALID_HANDLE_VALUE,
command_event: c.HANDLE = c.INVALID_HANDLE_VALUE,
output_read_event: c.HANDLE = c.INVALID_HANDLE_VALUE,
shell_process: c.HANDLE = c.INVALID_HANDLE_VALUE,
running: std.atomic.Value(bool) = .init(true),
pid: i64 = -1,

var create_pseudo_console: ?CreatePseudoConsoleFn = null;
var resize_pseudo_console: ?ResizePseudoConsoleFn = null;
var close_pseudo_console: ?ClosePseudoConsoleFn = null;
var pipe_name_counter = std.atomic.Value(u32).init(1);

pub const ProcessParams = @import("ProcessParams.zig");

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

    var notify_crt: ?NotifyCrt = null;

    pub fn init(fd: Fd) !EventWriter {
        _ = try resolveNotifyCrt();
        return .{
            .fd = fd,
        };
    }

    pub fn write(self: *EventWriter, data: []const u8) !void {
        const crt = notify_crt.?;
        var written: usize = 0;
        while (written < data.len) {
            const chunk_len: c_uint = @intCast(@min(data.len - written, std.math.maxInt(c_uint)));
            const n = crt.write(
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
        _ = notify_crt.?.close(self.fd);
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
        if (notify_crt) |crt| return crt;

        const provider = try detectNotifyCrtProvider();
        const dll_name = switch (provider) {
            .msvcrt => std.unicode.utf8ToUtf16LeStringLiteral("msvcrt.dll"),
            .ucrt => std.unicode.utf8ToUtf16LeStringLiteral("ucrtbase.dll"),
        };
        const module = c.GetModuleHandleW(dll_name) orelse return error.NotifyCrtUnavailable;
        const write_proc = c.GetProcAddress(module, "_write") orelse return error.NotifyCrtUnavailable;
        const close_proc = c.GetProcAddress(module, "_close") orelse return error.NotifyCrtUnavailable;
        notify_crt = .{
            .write = @ptrCast(write_proc),
            .close = @ptrCast(close_proc),
        };
        return notify_crt.?;
    }
};

pub fn init(alloc: Allocator, initial_cols: u16, initial_rows: u16, params: ProcessParams) !Self {
    try initApi();

    var self: Self = .{};
    self.command_event = c.CreateEventW(null, c.TRUE, c.FALSE, null);
    if (self.command_event == null) return error.CreateEventFailed;
    errdefer self.closeConPtyHandles();
    self.output_read_event = c.CreateEventW(null, c.TRUE, c.FALSE, null);
    if (self.output_read_event == null) return error.CreateEventFailed;
    try self.createConPty(initial_rows, initial_cols);
    try self.spawnChild(alloc, params);

    return self;
}

pub fn pidValue(self: *const Self) i64 {
    return self.pid;
}

pub fn drain(
    self: *Self,
    stream: anytype,
) !bool {
    var buf: [READ_BUFFER_SIZE]u8 = undefined;

    while (self.running.load(.acquire)) {
        switch (try self.readOutput(stream, buf[0..])) {
            .output, .command => return false,
            .eof => {
                self.stopRunning();
                return true;
            },
        }
    }

    return true;
}

const ReadOutputResult = enum {
    output,
    eof,
    command,
};

fn readOutput(
    self: *Self,
    stream: anytype,
    buf: []u8,
) !ReadOutputResult {
    if (self.pty_output == c.INVALID_HANDLE_VALUE) return .eof;
    if (self.output_read_event == c.INVALID_HANDLE_VALUE) return error.ReadFailed;

    _ = c.ResetEvent(self.output_read_event);

    var overlapped = std.mem.zeroes(c.OVERLAPPED);
    overlapped.hEvent = self.output_read_event;

    var bytes_read: c.DWORD = 0;
    if (c.ReadFile(
        self.pty_output,
        buf.ptr,
        @intCast(buf.len),
        &bytes_read,
        &overlapped,
    ) != 0) {
        return self.finishRead(stream, buf, bytes_read);
    }

    switch (c.GetLastError()) {
        c.ERROR_IO_PENDING => {},
        c.ERROR_OPERATION_ABORTED => return .command,
        c.ERROR_BROKEN_PIPE, c.ERROR_INVALID_HANDLE => return .eof,
        else => return error.ReadFailed,
    }

    var include_process = true;
    while (true) {
        switch (try self.waitForReadOrCommand(include_process)) {
            .read => return self.finishOverlappedRead(stream, buf, &overlapped),
            .command => {
                self.clearCommandEvent();
                return self.cancelPendingRead(stream, buf, &overlapped);
            },
            .process => {
                self.closePseudoConsole();
                include_process = false;
            },
        }
    }
}

fn finishRead(self: *Self, stream: anytype, buf: []u8, bytes_read: c.DWORD) ReadOutputResult {
    _ = self;
    if (bytes_read == 0) return .eof;
    stream.nextSlice(buf[0..@as(usize, @intCast(bytes_read))]);
    return .output;
}

fn finishOverlappedRead(
    self: *Self,
    stream: anytype,
    buf: []u8,
    overlapped: *c.OVERLAPPED,
) !ReadOutputResult {
    var bytes_read: c.DWORD = 0;
    if (c.GetOverlappedResult(
        self.pty_output,
        overlapped,
        &bytes_read,
        c.FALSE,
    ) == 0) {
        const err = c.GetLastError();
        switch (err) {
            c.ERROR_OPERATION_ABORTED => return .command,
            c.ERROR_BROKEN_PIPE, c.ERROR_INVALID_HANDLE => return .eof,
            else => return error.ReadFailed,
        }
    }

    return self.finishRead(stream, buf, bytes_read);
}

fn cancelPendingRead(
    self: *Self,
    stream: anytype,
    buf: []u8,
    overlapped: *c.OVERLAPPED,
) !ReadOutputResult {
    if (c.CancelIoEx(self.pty_output, overlapped) == 0) {
        const err = c.GetLastError();
        switch (err) {
            c.ERROR_NOT_FOUND => {},
            c.ERROR_INVALID_HANDLE => return .eof,
            else => return error.ReadFailed,
        }
    }

    var bytes_read: c.DWORD = 0;
    if (c.GetOverlappedResult(
        self.pty_output,
        overlapped,
        &bytes_read,
        c.TRUE,
    ) == 0) {
        const err = c.GetLastError();
        switch (err) {
            c.ERROR_OPERATION_ABORTED => return .command,
            c.ERROR_BROKEN_PIPE, c.ERROR_INVALID_HANDLE => return .eof,
            else => return error.ReadFailed,
        }
    }

    return self.finishRead(stream, buf, bytes_read);
}

const WaitResult = enum {
    read,
    process,
    command,
};

fn waitForReadOrCommand(self: *Self, include_process: bool) !WaitResult {
    var handles: [3]c.HANDLE = undefined;
    var count: c.DWORD = 0;
    const read_index = count;
    handles[count] = self.output_read_event;
    count += 1;

    var process_index: ?c.DWORD = null;
    var command_index: c.DWORD = undefined;

    if (include_process and self.shell_process != c.INVALID_HANDLE_VALUE) {
        process_index = count;
        handles[count] = self.shell_process;
        count += 1;
    }

    command_index = count;
    handles[count] = self.command_event;
    count += 1;

    const result = c.WaitForMultipleObjects(count, &handles, c.FALSE, c.INFINITE);
    if (result < c.WAIT_OBJECT_0 or result >= c.WAIT_OBJECT_0 + count) return error.WaitFailed;

    const index = result - c.WAIT_OBJECT_0;
    if (index == read_index) return .read;
    if (process_index != null and index == process_index.?) return .process;
    if (index == command_index) return .command;
    return error.WaitFailed;
}

pub fn write(self: *Self, data: []const u8) !void {
    if (data.len == 0) return;
    if (self.pty_input == c.INVALID_HANDLE_VALUE) return error.WriteFailed;

    var offset: usize = 0;
    while (offset < data.len) {
        var wrote: c.DWORD = 0;
        const chunk_len: c.DWORD = @intCast(@min(data.len - offset, std.math.maxInt(c.DWORD)));
        if (c.WriteFile(self.pty_input, data[offset..].ptr, chunk_len, &wrote, null) == 0) {
            return error.WriteFailed;
        }
        if (wrote == 0) return error.WriteFailed;
        offset += wrote;
    }
}

pub fn requestStop(self: *Self, read_thread: std.Thread) void {
    self.stopRunning();
    if (self.command_event != c.INVALID_HANDLE_VALUE) {
        _ = c.SetEvent(self.command_event);
    }

    if (self.pty_input != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(self.pty_input);
        self.pty_input = c.INVALID_HANDLE_VALUE;
    }

    _ = c.CancelSynchronousIo(read_thread.getHandle());
}

pub fn resize(self: *Self, cols: u16, rows: u16) !void {
    if (!self.running.load(.acquire)) return error.PtyResizeFailed;
    const hpc = self.hpc orelse return error.PtyResizeFailed;
    const size = c.COORD{
        .X = @intCast(cols),
        .Y = @intCast(rows),
    };
    if (resize_pseudo_console.?(hpc, size) < 0) return error.PtyResizeFailed;
}

pub fn replicaName(_: *Self) []const u8 {
    return "";
}

pub fn deinitAndWait(self: *Self) u8 {
    self.stopRunning();
    self.closeConPtyHandles();

    var exit_code: c.DWORD = 0;
    if (self.shell_process != c.INVALID_HANDLE_VALUE) {
        _ = c.WaitForSingleObject(self.shell_process, c.INFINITE);
        _ = c.GetExitCodeProcess(self.shell_process, &exit_code);
        _ = c.CloseHandle(self.shell_process);
        self.shell_process = c.INVALID_HANDLE_VALUE;
    }

    return @truncate(exit_code);
}

fn initApi() !void {
    if (create_pseudo_console != null) return;

    const kernel32 = c.GetModuleHandleA("kernel32.dll") orelse return error.MissingConPty;
    create_pseudo_console = @ptrCast(c.GetProcAddress(kernel32, "CreatePseudoConsole") orelse return error.MissingConPty);
    resize_pseudo_console = @ptrCast(c.GetProcAddress(kernel32, "ResizePseudoConsole") orelse return error.MissingConPty);
    close_pseudo_console = @ptrCast(c.GetProcAddress(kernel32, "ClosePseudoConsole") orelse return error.MissingConPty);
}

fn createConPty(self: *Self, rows: u16, cols: u16) !void {
    var in_read: c.HANDLE = c.INVALID_HANDLE_VALUE;
    var in_write: c.HANDLE = c.INVALID_HANDLE_VALUE;
    var out_read: c.HANDLE = c.INVALID_HANDLE_VALUE;
    var out_write: c.HANDLE = c.INVALID_HANDLE_VALUE;
    errdefer {
        self.closeConPtyHandles();
        if (in_read != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(in_read);
        if (in_write != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(in_write);
        if (out_read != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(out_read);
        if (out_write != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(out_write);
    }

    var sa = std.mem.zeroes(c.SECURITY_ATTRIBUTES);
    sa.nLength = @sizeOf(c.SECURITY_ATTRIBUTES);
    sa.bInheritHandle = c.TRUE;

    if (c.CreatePipe(&in_read, &in_write, &sa, 0) == 0) return error.CreatePipeFailed;
    try createOverlappedPipe(&out_read, &out_write);

    const size = c.COORD{
        .X = @intCast(cols),
        .Y = @intCast(rows),
    };
    if (create_pseudo_console.?(size, in_read, out_write, 0, &self.hpc) < 0) {
        return error.CreatePseudoConsoleFailed;
    }

    self.pty_input = in_write;
    self.pty_output = out_read;
    _ = c.CloseHandle(in_read);
    _ = c.CloseHandle(out_write);
    in_write = c.INVALID_HANDLE_VALUE;
    out_read = c.INVALID_HANDLE_VALUE;
    in_read = c.INVALID_HANDLE_VALUE;
    out_write = c.INVALID_HANDLE_VALUE;
}

fn closeConPtyHandles(self: *Self) void {
    if (self.pty_input != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(self.pty_input);
        self.pty_input = c.INVALID_HANDLE_VALUE;
    }
    if (self.pty_output != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(self.pty_output);
        self.pty_output = c.INVALID_HANDLE_VALUE;
    }
    if (self.hpc != null) {
        // ClosePseudoConsole owns the documented ConPTY teardown path.
        close_pseudo_console.?(self.hpc);
        self.hpc = null;
    }
    if (self.command_event != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(self.command_event);
        self.command_event = c.INVALID_HANDLE_VALUE;
    }
    if (self.output_read_event != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(self.output_read_event);
        self.output_read_event = c.INVALID_HANDLE_VALUE;
    }
}

fn closePseudoConsole(self: *Self) void {
    if (self.hpc != null) {
        close_pseudo_console.?(self.hpc);
        self.hpc = null;
    }
}

fn clearCommandEvent(self: *Self) void {
    if (self.command_event == c.INVALID_HANDLE_VALUE) return;
    _ = c.ResetEvent(self.command_event);
}

fn createOverlappedPipe(read_handle: *c.HANDLE, write_handle: *c.HANDLE) !void {
    var pipe_path_buf: [128]u8 = undefined;
    var pipe_path_buf_w: [128]u16 = undefined;
    const pipe_path = std.fmt.bufPrintZ(
        &pipe_path_buf,
        "\\\\.\\pipe\\ghostel-conpty-{d}-{d}",
        .{
            c.GetCurrentProcessId(),
            pipe_name_counter.fetchAdd(1, .monotonic),
        },
    ) catch unreachable;

    const pipe_path_w_len = std.unicode.utf8ToUtf16Le(
        &pipe_path_buf_w,
        pipe_path,
    ) catch unreachable;
    pipe_path_buf_w[pipe_path_w_len] = 0;
    const pipe_path_w = pipe_path_buf_w[0..pipe_path_w_len :0];

    var sa = std.mem.zeroes(c.SECURITY_ATTRIBUTES);
    sa.nLength = @sizeOf(c.SECURITY_ATTRIBUTES);
    sa.bInheritHandle = c.TRUE;

    read_handle.* = c.CreateNamedPipeW(
        pipe_path_w.ptr,
        c.PIPE_ACCESS_INBOUND | c.FILE_FLAG_OVERLAPPED | c.FILE_FLAG_FIRST_PIPE_INSTANCE,
        c.PIPE_TYPE_BYTE,
        1,
        4096,
        4096,
        0,
        &sa,
    );
    if (read_handle.* == c.INVALID_HANDLE_VALUE) return error.CreatePipeFailed;
    errdefer {
        _ = c.CloseHandle(read_handle.*);
        read_handle.* = c.INVALID_HANDLE_VALUE;
    }

    write_handle.* = c.CreateFileW(
        pipe_path_w.ptr,
        c.GENERIC_WRITE,
        0,
        &sa,
        c.OPEN_EXISTING,
        c.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (write_handle.* == c.INVALID_HANDLE_VALUE) return error.CreatePipeFailed;
}

fn spawnChild(self: *Self, alloc: Allocator, params: ProcessParams) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(alloc);
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
        self.hpc,
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

    self.shell_process = pi.hProcess;
    self.pid = @intCast(pi.dwProcessId);
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

const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

fn envEntryLessThan(_: void, lhs: EnvEntry, rhs: EnvEntry) bool {
    return std.ascii.lessThanIgnoreCase(lhs.key, rhs.key);
}

fn buildEnvironmentBlock(arena: Allocator, env_map: *const std.process.EnvMap) ![]u16 {
    var builder = std.ArrayList(u16).empty;
    errdefer builder.deinit(arena);

    const entries = try arena.alloc(EnvEntry, @intCast(env_map.count()));
    defer arena.free(entries);
    var it = env_map.iterator();
    var i: usize = 0;
    while (it.next()) |pair| : (i += 1) {
        entries[i] = .{ .key = pair.key_ptr.*, .value = pair.value_ptr.* };
    }
    std.mem.sort(EnvEntry, entries, {}, envEntryLessThan);

    for (entries) |entry| {
        try appendWtf8AsWtf16(&builder, arena, entry.key);
        try builder.append(arena, '=');
        try appendWtf8AsWtf16(&builder, arena, entry.value);
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

fn stopRunning(self: *Self) void {
    self.running.store(false, .release);
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

test "buildEnvironmentBlock sorts entries by environment name" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZED", "last");
    try env.put("ALPHA", "first");
    try env.put("Path", "middle");

    const block = try buildEnvironmentBlock(std.testing.allocator, &env);
    defer std.testing.allocator.free(block);

    try std.testing.expectEqualSlices(u16, &[_]u16{
        'A', 'L', 'P', 'H', 'A', '=', 'f', 'i', 'r', 's', 't', 0,
        'P', 'a', 't', 'h', '=', 'm', 'i', 'd', 'd', 'l', 'e', 0,
        'Z', 'E', 'D', '=', 'l', 'a', 's', 't', 0,   0,
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
