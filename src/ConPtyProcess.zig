const std = @import("std");
const Allocator = std.mem.Allocator;

const backend_types = @import("backend_types.zig");

const c = @cImport({
    @cInclude("windows.h");
});

const Self = @This();

const HPCON = ?*anyopaque;
const CreatePseudoConsoleFn = *const fn (c.COORD, c.HANDLE, c.HANDLE, u32, *HPCON) callconv(.winapi) c.HRESULT;
const ResizePseudoConsoleFn = *const fn (HPCON, c.COORD) callconv(.winapi) c.HRESULT;
const ClosePseudoConsoleFn = *const fn (HPCON) callconv(.winapi) void;

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const PIPE_REJECT_REMOTE_CLIENTS: c.DWORD = 0x00000008;
const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT: c.DWORD = 0x00000002;
const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: c.DWORD = 0x00000004;
const READ_BUFFER_SIZE = 64 * 1024;
const WRITE_CHUNK_SIZE = 4096;

const OverlappedPipeEnd = enum { read, write };

alloc: Allocator,
hpc: HPCON = null,
pty_input: c.HANDLE = c.INVALID_HANDLE_VALUE,
pty_output: c.HANDLE = c.INVALID_HANDLE_VALUE,
interrupt_event: c.HANDLE = c.INVALID_HANDLE_VALUE,
output_read_event: c.HANDLE = c.INVALID_HANDLE_VALUE,
input_write_event: c.HANDLE = c.INVALID_HANDLE_VALUE,
shell_process: c.HANDLE = c.INVALID_HANDLE_VALUE,
pid: i64 = -1,

var create_pseudo_console: ?CreatePseudoConsoleFn = null;
var resize_pseudo_console: ?ResizePseudoConsoleFn = null;
var close_pseudo_console: ?ClosePseudoConsoleFn = null;

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

        // Emacs' `open_channel' returns a CRT fd owned by Emacs, so event
        // writes must go through the same mainstream CRT family Emacs imports.
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

pub fn init(alloc: Allocator, initial_cols: u16, initial_rows: u16, params: backend_types.ProcessParams) !Self {
    try initApi();

    var self: Self = .{ .alloc = alloc };

    self.interrupt_event = c.CreateEventW(null, c.TRUE, c.FALSE, null);
    if (self.interrupt_event == null) return error.CreateEventFailed;
    errdefer closeConPtyHandles(&self);

    self.output_read_event = c.CreateEventW(null, c.TRUE, c.FALSE, null);
    if (self.output_read_event == null) return error.CreateEventFailed;

    self.input_write_event = c.CreateEventW(null, c.TRUE, c.FALSE, null);
    if (self.input_write_event == null) return error.CreateEventFailed;

    try createConPty(&self, initial_rows, initial_cols);
    try spawnChild(&self, params);

    return self;
}

pub fn pidValue(self: *const Self) i64 {
    return self.pid;
}

pub fn drain(self: *Self, stream: anytype) !bool {
    const interrupt_handles = [_]c.HANDLE{
        self.shell_process,
        self.interrupt_event,
    };

    return try self.readOutput(stream, &interrupt_handles) == .ok;
}

pub fn finishDrain(self: *Self, stream: anytype) !void {
    self.clearInterruptEvent();
    const close_thread = startPseudoConsoleClose(self) orelse return;
    defer close_thread.join();

    while (try self.readOutput(stream, &.{}) == .ok) {}
}

fn readOutput(
    self: *Self,
    stream: anytype,
    interrupt_handles: []const c.HANDLE,
) !union(enum) { ok, finished } {
    if (self.pty_output == c.INVALID_HANDLE_VALUE) return .finished;
    if (self.output_read_event == c.INVALID_HANDLE_VALUE) return error.IoFailed;

    _ = c.ResetEvent(self.output_read_event);

    var overlapped = std.mem.zeroes(c.OVERLAPPED);
    overlapped.hEvent = self.output_read_event;

    var buf: [READ_BUFFER_SIZE]u8 = undefined;
    var bytes_read: c.DWORD = 0;
    if (c.ReadFile(
        self.pty_output,
        &buf,
        @intCast(buf.len),
        &bytes_read,
        &overlapped,
    ) != 0) {
        stream.nextSlice(buf[0..bytes_read]);
        return .ok;
    }

    switch (c.GetLastError()) {
        c.ERROR_IO_PENDING => {},
        c.ERROR_OPERATION_ABORTED, c.ERROR_BROKEN_PIPE, c.ERROR_INVALID_HANDLE => {
            return .finished;
        },
        else => return error.IoFailed,
    }
    errdefer _ = completeOverlapped(self.pty_output, &overlapped, true) catch {};

    const wait_result = try self.waitForRead(interrupt_handles);
    const complete_result = try completeOverlapped(
        self.pty_output,
        &overlapped,
        wait_result == .interrupted,
    );
    if (complete_result == .bytes) stream.nextSlice(buf[0..complete_result.bytes]);

    if (wait_result == .interrupted or complete_result != .bytes) return .finished;
    return .ok;
}

fn completeOverlapped(
    handle: c.HANDLE,
    overlapped: *c.OVERLAPPED,
    cancel: bool,
) !union(enum) { bytes: usize, aborted, closed } {
    if (cancel and c.CancelIoEx(handle, overlapped) == 0 and
        c.GetLastError() == c.ERROR_INVALID_HANDLE)
    {
        return .closed;
    }

    var bytes_transferred: c.DWORD = 0;
    if (c.GetOverlappedResult(
        handle,
        overlapped,
        &bytes_transferred,
        c.TRUE,
    ) == 0) {
        const err = c.GetLastError();
        switch (err) {
            c.ERROR_OPERATION_ABORTED => return .aborted,
            c.ERROR_BROKEN_PIPE, c.ERROR_INVALID_HANDLE => return .closed,
            else => return error.IoFailed,
        }
    }

    return .{ .bytes = @intCast(bytes_transferred) };
}

fn waitForRead(
    self: *Self,
    interrupt_handles: []const c.HANDLE,
) !union(enum) { ready, interrupted } {
    var handles: [3]c.HANDLE = undefined;
    var count: c.DWORD = 0;
    const read_index = count;
    handles[count] = self.output_read_event;
    count += 1;

    for (interrupt_handles) |handle| {
        if (handle == c.INVALID_HANDLE_VALUE) continue;
        handles[count] = handle;
        count += 1;
    }

    const result = c.WaitForMultipleObjects(count, &handles, c.FALSE, c.INFINITE);
    if (result < c.WAIT_OBJECT_0 or result >= c.WAIT_OBJECT_0 + count) return error.WaitFailed;

    const index = result - c.WAIT_OBJECT_0;
    return if (index == read_index) .ready else .interrupted;
}

pub fn write(
    self: *Self,
    data: []const u8,
    cancellation: ?backend_types.CancellationToken,
) !backend_types.WriteResult {
    if (data.len == 0) return .{ .written = 0 };
    if (self.pty_input == c.INVALID_HANDLE_VALUE) return error.IoFailed;
    if (self.input_write_event == c.INVALID_HANDLE_VALUE) return error.IoFailed;
    if (self.interrupt_event == c.INVALID_HANDLE_VALUE) return error.IoFailed;

    _ = c.ResetEvent(self.input_write_event);

    var overlapped = std.mem.zeroes(c.OVERLAPPED);
    overlapped.hEvent = self.input_write_event;

    var bytes_written: c.DWORD = 0;
    const chunk_len: c.DWORD = @intCast(@min(data.len, WRITE_CHUNK_SIZE));
    if (c.WriteFile(
        self.pty_input,
        data.ptr,
        chunk_len,
        &bytes_written,
        &overlapped,
    ) != 0) {
        if (bytes_written == 0) return error.IoFailed;
        return .{ .written = @intCast(bytes_written) };
    }

    switch (c.GetLastError()) {
        c.ERROR_IO_PENDING => {},
        c.ERROR_BROKEN_PIPE, c.ERROR_INVALID_HANDLE => return error.ProcessExited,
        else => return error.IoFailed,
    }
    errdefer _ = completeOverlapped(self.pty_input, &overlapped, true) catch {};

    const handles = [_]c.HANDLE{
        self.input_write_event,
        self.interrupt_event,
    };
    const timeout = if (cancellation) |token| token.poll_interval_ms else c.INFINITE;
    while (true) {
        const wait_result = c.WaitForMultipleObjects(
            handles.len,
            &handles,
            c.FALSE,
            timeout,
        );
        if (wait_result == c.WAIT_TIMEOUT) {
            try cancellation.?.check();
            continue;
        }

        const interrupted = wait_result == c.WAIT_OBJECT_0 + 1;
        if (!interrupted and wait_result != c.WAIT_OBJECT_0) return error.IoFailed;

        const complete_result = try completeOverlapped(
            self.pty_input,
            &overlapped,
            interrupted,
        );
        return switch (complete_result) {
            .bytes => |n| if (n > 0) .{ .written = n } else error.IoFailed,
            .aborted => if (interrupted) .interrupted else error.IoFailed,
            else => error.IoFailed,
        };
    }
}

pub fn resize(self: *Self, cols: u16, rows: u16) !void {
    const hpc = self.hpc orelse return error.PtyResizeFailed;
    const size = c.COORD{
        .X = @intCast(cols),
        .Y = @intCast(rows),
    };
    if (resize_pseudo_console.?(hpc, size) < 0) return error.PtyResizeFailed;
}

pub fn requestStop(self: *Self, _: std.Thread) void {
    if (self.interrupt_event == c.INVALID_HANDLE_VALUE) return;
    _ = c.SetEvent(self.interrupt_event);
}

pub fn replicaName(_: *Self) []const u8 {
    return "";
}

pub fn deinitAndWait(self: *Self) u8 {
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

    // Prefer the redistributable Microsoft.Windows.Console.ConPTY runtime when
    // it is shipped next to ghostel-module.dll. Its side-by-side OpenConsole
    // path avoids the stock conhost response-to-input latency seen through
    // kernel32!CreatePseudoConsole. Fall back to kernel32 so local/debug builds
    // and unsupported layouts keep working with the public OS API.
    if (loadSideBySideConpty()) |conpty| {
        if (resolveApi(conpty, "ConptyCreatePseudoConsole", "ConptyResizePseudoConsole", "ConptyClosePseudoConsole")) {
            return;
        }
    }

    try resolveKernel32Api();
}

fn resolveKernel32Api() !void {
    const kernel32 = c.GetModuleHandleA("kernel32.dll") orelse return error.MissingConPty;
    if (!resolveApi(kernel32, "CreatePseudoConsole", "ResizePseudoConsole", "ClosePseudoConsole")) {
        return error.MissingConPty;
    }
}

fn resolveApi(module: c.HMODULE, create_name: [*:0]const u8, resize_name: [*:0]const u8, close_name: [*:0]const u8) bool {
    const create_proc = c.GetProcAddress(module, create_name) orelse return false;
    const resize_proc = c.GetProcAddress(module, resize_name) orelse return false;
    const close_proc = c.GetProcAddress(module, close_name) orelse return false;
    create_pseudo_console = @ptrCast(create_proc);
    resize_pseudo_console = @ptrCast(resize_proc);
    close_pseudo_console = @ptrCast(close_proc);
    return true;
}

fn loadSideBySideConpty() ?c.HMODULE {
    var module_dir_buf: [32768]u8 = undefined;
    const module_dir = currentModuleDir(&module_dir_buf) orelse return null;
    var conpty_path_buf: [32768]u8 = undefined;
    const conpty_path = std.fmt.bufPrintZ(
        &conpty_path_buf,
        "{s}\\conpty.dll",
        .{module_dir},
    ) catch return null;

    var conpty_path_w_buf: [32768]u16 = undefined;
    const conpty_path_w_len = std.unicode.utf8ToUtf16Le(
        &conpty_path_w_buf,
        conpty_path,
    ) catch return null;
    conpty_path_w_buf[conpty_path_w_len] = 0;
    const conpty_path_w = conpty_path_w_buf[0..conpty_path_w_len :0];
    return c.LoadLibraryW(conpty_path_w.ptr);
}

fn currentModuleDir(module_path_buf: *[32768]u8) ?[]const u8 {
    var self_module: c.HMODULE = null;
    const flags = GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT;
    if (c.GetModuleHandleExW(flags, @ptrCast(&create_pseudo_console), &self_module) == 0) return null;

    var module_path_w: [32768]u16 = undefined;
    const len = c.GetModuleFileNameW(self_module, &module_path_w, module_path_w.len);
    if (len == 0 or len >= module_path_w.len) return null;

    const module_path_len = std.unicode.utf16LeToUtf8(
        module_path_buf,
        module_path_w[0..@intCast(len)],
    ) catch return null;
    const module_path = module_path_buf[0..module_path_len];
    return std.fs.path.dirname(module_path);
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

    try createOverlappedPipe(&in_read, &in_write, .write);
    try createOverlappedPipe(&out_read, &out_write, .read);

    const size = c.COORD{
        .X = @intCast(cols),
        .Y = @intCast(rows),
    };
    const create_result = create_pseudo_console.?(size, in_read, out_write, 0, &self.hpc);
    if (create_result < 0) return error.CreatePseudoConsoleFailed;

    self.pty_input = in_write;
    self.pty_output = out_read;
    _ = c.CloseHandle(in_read);
    _ = c.CloseHandle(out_write);
    in_write = c.INVALID_HANDLE_VALUE;
    out_read = c.INVALID_HANDLE_VALUE;
    in_read = c.INVALID_HANDLE_VALUE;
    out_write = c.INVALID_HANDLE_VALUE;
}

fn closeHandle(handle: *c.HANDLE) void {
    if (handle.* != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(handle.*);
        handle.* = c.INVALID_HANDLE_VALUE;
    }
}

fn closeConPtyHandles(self: *Self) void {
    closeHandle(&self.pty_input);
    closeHandle(&self.pty_output);
    self.closePseudoConsole();
    closeHandle(&self.interrupt_event);
    closeHandle(&self.output_read_event);
    closeHandle(&self.input_write_event);
}

fn closePseudoConsole(self: *Self) void {
    if (self.hpc != null) {
        // ClosePseudoConsole owns the documented ConPTY teardown path.
        close_pseudo_console.?(self.hpc);
        self.hpc = null;
    }
}

fn startPseudoConsoleClose(self: *Self) ?std.Thread {
    const hpc = self.hpc;
    if (hpc == null) return null;
    self.hpc = null;

    // Child exit only tells us when to initiate teardown; EOF on the output
    // pipe tells us when ConPTY has flushed its final output. Older Windows can
    // block inside ClosePseudoConsole until that drain completes, so the reader
    // thread must hand the handle to a helper, keep reading to EOF, and then
    // join the helper.
    return std.Thread.spawn(
        .{ .stack_size = 128 * 1024 },
        closePseudoConsoleHandle,
        .{hpc},
    ) catch |err| {
        std.log.scoped(.ConPtyProcess).err(
            "Failed to spawn ConPTY closer thread; leaking pseudoconsole handle to avoid reader deadlock: {any}",
            .{err},
        );
        return null;
    };
}

fn closePseudoConsoleHandle(hpc: HPCON) void {
    close_pseudo_console.?(hpc);
}

fn clearInterruptEvent(self: *Self) void {
    if (self.interrupt_event == c.INVALID_HANDLE_VALUE) return;
    _ = c.ResetEvent(self.interrupt_event);
}

fn createOverlappedPipe(
    read_handle: *c.HANDLE,
    write_handle: *c.HANDLE,
    overlapped_end: OverlappedPipeEnd,
) !void {
    var pipe_path_buf: [160]u8 = undefined;
    var pipe_path_buf_w: [160]u16 = undefined;
    const pipe_path = std.fmt.bufPrintZ(
        &pipe_path_buf,
        "\\\\.\\pipe\\ghostel-conpty-{d}-{x}",
        .{ c.GetCurrentProcessId(), std.crypto.random.int(u64) },
    ) catch unreachable;

    const pipe_path_w_len = std.unicode.utf8ToUtf16Le(
        &pipe_path_buf_w,
        pipe_path,
    ) catch unreachable;
    pipe_path_buf_w[pipe_path_w_len] = 0;
    const pipe_path_w = pipe_path_buf_w[0..pipe_path_w_len :0];

    var read_flags: c.DWORD = @intCast(c.PIPE_ACCESS_INBOUND);
    read_flags |= @intCast(c.FILE_FLAG_FIRST_PIPE_INSTANCE);
    if (overlapped_end == .read) read_flags |= @intCast(c.FILE_FLAG_OVERLAPPED);

    var write_flags: c.DWORD = @intCast(c.FILE_ATTRIBUTE_NORMAL);
    if (overlapped_end == .write) write_flags |= @intCast(c.FILE_FLAG_OVERLAPPED);

    read_handle.* = c.CreateNamedPipeW(
        pipe_path_w.ptr,
        read_flags,
        c.PIPE_TYPE_BYTE | PIPE_REJECT_REMOTE_CLIENTS,
        1,
        4096,
        4096,
        0,
        null,
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
        null,
        c.OPEN_EXISTING,
        write_flags,
        null,
    );
    if (write_handle.* == c.INVALID_HANDLE_VALUE) return error.CreatePipeFailed;
}

fn spawnChild(self: *Self, params: backend_types.ProcessParams) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(self.alloc);
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
    const attr_list_word_count = try std.math.divCeil(usize, attr_list_size, @sizeOf(usize));
    const attr_list_buf = try arena.alloc(usize, attr_list_word_count);

    var si = std.mem.zeroes(c.STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(c.STARTUPINFOEXW);
    // Prevent console children from inheriting Emacs' redirected stdio when
    // Emacs itself is running under SSH or another pipe-backed parent.  This
    // intentionally follows the ConPTY workaround recommended by Microsoft
    // Terminal maintainers: set STARTF_USESTDHANDLES with null hStd* handles
    // so Windows does not copy the parent's redirected handles into the child.
    // The child's console association comes from PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE.
    si.StartupInfo.dwFlags = c.STARTF_USESTDHANDLES;
    si.lpAttributeList = @ptrCast(attr_list_buf.ptr);
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
        for (arg0) |ch| {
            if (ch == '"') return error.InvalidArg0;
        }
        try buf.append('"');
        for (arg0) |ch| {
            try buf.append(if (ch == '/') '\\' else ch);
        }
        try buf.append('"');

        for (argv[1..]) |arg| {
            try buf.append(' ');

            const needs_quotes = for (arg) |ch| {
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

test "argvToCommandLineWindows quotes argv0" {
    const argv = [_][:0]const u8{
        "c:/Windows/System32/cmd.exe",
        "/d",
        "/c",
        "echo hi",
    };
    const command_line = try argvToCommandLineWindows(std.testing.allocator, &argv);
    defer std.testing.allocator.free(command_line);

    const expected = std.unicode.utf8ToUtf16LeStringLiteral(
        "\"c:\\Windows\\System32\\cmd.exe\" /d /c \"echo hi\"",
    );
    try std.testing.expectEqualSlices(u16, expected, command_line);
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
