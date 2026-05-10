/// Zig wrapper around the Emacs dynamic module API.
///
/// Provides type-safe access to emacs_env functions, cached symbol
/// interning, and helper methods for common operations.
const std = @import("std");
const builtin = @import("builtin");

pub const c = @cImport({
    // Ensure struct timespec is fully defined on Linux (glibc gates it
    // behind _POSIX_C_SOURCE).  Harmless on macOS/BSDs.
    @cDefine("_POSIX_C_SOURCE", "199309L");
    @cInclude("emacs-module.h");
});

/// Emacs value type alias for convenience.
pub const Value = c.emacs_value;

/// Emacs environment wrapper providing typed access to the module API.
pub const Env = struct {
    raw: *c.emacs_env,

    pub fn init(raw: *c.emacs_env) Env {
        return .{ .raw = raw };
    }

    // --- Symbol interning ---

    pub fn intern(self: Env, name: [*:0]const u8) Value {
        return self.raw.intern.?(self.raw, name);
    }

    // --- Function calls ---

    pub fn funcall(self: Env, func: Value, args: []const Value) Value {
        return self.raw.funcall.?(self.raw, func, @intCast(args.len), @constCast(args.ptr));
    }

    pub fn f(self: Env, comptime func: []const u8, args: anytype) Value {
        return self.funcall(@field(sym, func), &self.makeValues(args));
    }

    // --- Type constructors ---

    pub fn makeList(self: Env, items: []const Value) Value {
        return self.funcall(sym.list, @constCast(items));
    }

    pub fn makeInteger(self: Env, n: i64) Value {
        return self.raw.make_integer.?(self.raw, @intCast(n));
    }

    pub fn makeFloat(self: Env, n: f64) Value {
        return self.raw.make_float.?(self.raw, n);
    }

    pub fn makeString(self: Env, str: []const u8) Value {
        return self.raw.make_string.?(self.raw, str.ptr, @intCast(str.len));
    }

    pub fn makeUserPtr(self: Env, finalizer: ?*const fn (?*anyopaque) callconv(.c) void, ptr: ?*anyopaque) Value {
        return self.raw.make_user_ptr.?(self.raw, finalizer, ptr);
    }

    pub fn makeValues(self: Env, args: anytype) [std.meta.fields(@TypeOf(args)).len]Value {
        const fields = std.meta.fields(@TypeOf(args));
        var converted_args: [fields.len]Value = undefined;
        inline for (fields, 0..) |field, i| {
            converted_args[i] = self.makeValue(@field(args, field.name));
        }
        return converted_args;
    }

    pub fn makeValue(self: Env, value: anytype) Value {
        const T = @TypeOf(value);

        switch (@typeInfo(T)) {
            .float, .comptime_float => return self.makeFloat(value),
            .int, .comptime_int => return self.makeInteger(@as(i64, @intCast(value))),
            .optional => return if (value) |v| self.makeValue(v) else self.nil(),
            .bool => return if (value) self.t() else self.nil(),
            .pointer => |ptr| {
                if (comptime isStringLike(ptr)) return self.makeString(value);
                if (T == *c.struct_emacs_value_tag) return value;
            },
            else => {},
        }

        @compileError(std.fmt.comptimePrint("Non-supported type: {}", .{T}));
    }

    pub fn getUserPtr(self: Env, comptime T: type, val: Value) ?*T {
        const raw_ptr = self.raw.get_user_ptr.?(self.raw, val);
        return @ptrCast(@alignCast(raw_ptr));
    }

    // --- Type extraction ---

    pub fn extractInteger(self: Env, val: Value) i64 {
        return @intCast(self.raw.extract_integer.?(self.raw, val));
    }

    pub fn extractFloat(self: Env, val: Value) f64 {
        return self.raw.extract_float.?(self.raw, val);
    }

    pub fn extractString(self: Env, val: Value, buf: []u8) ?[]const u8 {
        var len: isize = @intCast(buf.len);
        if (self.raw.copy_string_contents.?(self.raw, val, buf.ptr, &len)) {
            // len includes the null terminator
            const actual_len: usize = @intCast(len);
            if (actual_len > 0) {
                return buf[0 .. actual_len - 1];
            }
            return buf[0..0];
        }
        // Clear the non-local exit so callers (e.g. extractStringAlloc
        // fallback) can make further API calls.
        self.raw.non_local_exit_clear.?(self.raw);
        return null;
    }

    pub fn extractStringAlloc(self: Env, val: Value, allocator: std.mem.Allocator) ?[]const u8 {
        // First call to get required size
        var len: isize = 0;
        _ = self.raw.copy_string_contents.?(self.raw, val, null, &len);
        self.raw.non_local_exit_clear.?(self.raw);

        if (len <= 0) return null;
        const size: usize = @intCast(len);

        const buf = allocator.alloc(u8, size) catch return null;
        var actual_len: isize = @intCast(size);
        if (self.raw.copy_string_contents.?(self.raw, val, buf.ptr, &actual_len)) {
            const actual: usize = @intCast(actual_len);
            if (actual > 0) {
                return buf[0 .. actual - 1];
            }
            return buf[0..0];
        }
        allocator.free(buf);
        return null;
    }

    // --- Type checking ---

    pub fn isNil(self: Env, val: Value) bool {
        return !self.isNotNil(val);
    }

    pub fn isNotNil(self: Env, val: Value) bool {
        return self.raw.is_not_nil.?(self.raw, val);
    }

    pub fn eq(self: Env, a: Value, b: Value) bool {
        return self.raw.eq.?(self.raw, a, b);
    }

    // --- Global references ---

    pub fn makeGlobalRef(self: Env, val: Value) Value {
        return self.raw.make_global_ref.?(self.raw, val);
    }

    pub fn freeGlobalRef(self: Env, val: Value) void {
        self.raw.free_global_ref.?(self.raw, val);
    }

    // --- Vectors ---

    pub fn vecGet(self: Env, vec: Value, i: c_long) Value {
        return self.raw.vec_get.?(self.raw, vec, i);
    }

    pub fn vecSet(self: Env, vec: Value, i: c_long, value: Value) void {
        self.raw.vec_set.?(self.raw, vec, i, value);
    }

    pub fn vecSize(self: Env, vec: Value) c_long {
        return self.raw.vec_size.?(self.raw, vec);
    }

    // --- Non-local exit handling ---

    pub fn nonLocalExitCheck(self: Env) c.enum_emacs_funcall_exit {
        return self.raw.non_local_exit_check.?(self.raw);
    }

    pub fn nonLocalExitClear(self: Env) void {
        self.raw.non_local_exit_clear.?(self.raw);
    }

    pub fn nonLocalExitSignal(self: Env, symbol: Value, data: Value) void {
        self.raw.non_local_exit_signal.?(self.raw, symbol, data);
    }

    // --- Function registration ---

    pub fn makeFunction(
        self: Env,
        min_arity: i32,
        max_arity: i32,
        func: *const fn (?*c.emacs_env, isize, [*c]c.emacs_value, ?*anyopaque) callconv(.c) c.emacs_value,
        docstring: [*:0]const u8,
        data: ?*anyopaque,
    ) Value {
        return self.raw.make_function.?(self.raw, min_arity, max_arity, func, docstring, data);
    }

    // --- Convenience helpers ---

    pub fn nil(_: Env) Value {
        return sym.nil;
    }

    pub fn t(_: Env) Value {
        return sym.t;
    }

    /// Register a named Elisp function backed by a C function.
    pub fn bindFunction(self: Env, name: [*:0]const u8, min_arity: i32, max_arity: i32, func: *const fn (?*c.emacs_env, isize, [*c]c.emacs_value, ?*anyopaque) callconv(.c) c.emacs_value, docstring: [*:0]const u8) void {
        const fun = self.makeFunction(min_arity, max_arity, func, docstring, null);
        const name_sym = self.intern(name);
        _ = self.funcall(self.intern("fset"), &[_]Value{ name_sym, fun });
    }

    /// Call (provide 'feature).
    pub fn provide(self: Env, feature: [*:0]const u8) void {
        _ = self.funcall(self.intern("provide"), &[_]Value{self.intern(feature)});
    }

    // --- Buffer helpers ---

    pub fn point(self: Env) Value {
        return self.f("point", .{});
    }

    pub fn gotoChar(self: Env, pos: Value) void {
        _ = self.f("goto-char", .{pos});
    }

    pub fn gotoCharN(self: Env, pos: i64) void {
        _ = self.f("goto-char", .{pos});
    }

    pub fn insert(self: Env, text: []const u8) void {
        _ = self.f("insert", .{text});
    }

    pub fn forwardLine(self: Env, n: i64) i64 {
        return self.extractInteger(self.f("forward-line", .{n}));
    }

    pub fn moveToColumn(self: Env, col: i64) void {
        _ = self.f("move-to-column", .{col});
    }

    pub fn eraseBuffer(self: Env) void {
        _ = self.f("erase-buffer", .{});
    }

    pub fn lineEndPosition(self: Env) Value {
        return self.f("line-end-position", .{});
    }

    pub fn lineBeginningPosition2(self: Env) Value {
        return self.f("line-beginning-position", .{2});
    }

    pub fn pointMin(self: Env) Value {
        return self.f("point-min", .{});
    }

    pub fn pointMax(self: Env) Value {
        return self.f("point-max", .{});
    }

    pub fn markMarker(self: Env) Value {
        return self.f("mark-marker", .{});
    }

    pub fn markerPosition(self: Env, marker: Value) Value {
        return self.f("marker-position", .{marker});
    }

    pub fn setMarker(self: Env, marker: Value, pos: Value) Value {
        return self.f("set-marker", .{ marker, pos });
    }

    pub fn deleteRegion(self: Env, start: Value, end: Value) void {
        _ = self.f("delete-region", .{ start, end });
    }

    pub fn putTextProperty(self: Env, start: Value, end: Value, prop: Value, value: Value) void {
        _ = self.f("put-text-property", .{ start, end, prop, value });
    }

    /// Create a unibyte string (for binary data like PNG images).
    /// Returns null if the API is unavailable (Emacs < 28).
    pub fn makeUnibyteString(self: Env, str: []const u8) ?Value {
        const func = self.raw.make_unibyte_string orelse return null;
        return func(self.raw, str.ptr, @intCast(str.len));
    }

    // --- Logging and debugging ---

    /// Signal an error with a message string.
    pub fn signalError(self: Env, msg: []const u8) void {
        self.nonLocalExitSignal(
            self.intern("error"),
            self.f("list", .{msg}),
        );
    }

    /// Signal an error with a formatted message string.
    pub fn signalErrorf(self: Env, comptime fmt: []const u8, args: anytype) void {
        callFmt(self, Env.signalError, fmt, args);
    }

    pub fn message(self: Env, msg: []const u8) void {
        _ = self.call1(sym.message, self.makeString(msg));
    }

    pub fn messagef(self: Env, comptime fmt: []const u8, args: anytype) void {
        callFmt(self, Env.message, fmt, args);
    }

    pub fn logError(self: Env, msg: []const u8) void {
        _ = self.f("display-warning", .{ sym.ghostel, msg, sym.@":error" });
    }

    pub fn logErrorf(self: Env, comptime fmt: []const u8, args: anytype) void {
        callFmt(self, Env.logError, fmt, args);
    }

    /// Writes stack trace as Emacs messages if in debug mode
    pub fn logStackTrace(self: Env, stack_trace: ?*std.builtin.StackTrace) void {
        if (comptime builtin.mode == .Debug) {
            if (stack_trace) |trace| {
                var buffer: [4096]u8 = undefined;
                var writer = std.Io.Writer.fixed(&buffer);
                const debug_info = std.debug.getSelfDebugInfo() catch |err| {
                    self.logErrorf("Unable to get debug info: {s}", .{@errorName(err)});
                    return;
                };
                std.debug.writeStackTrace(trace.*, &writer, debug_info, .no_color) catch |err| {
                    self.logErrorf("Unable to print stack trace: {s}", .{@errorName(err)});
                    return;
                };
                self.logError(buffer[0..writer.end]);
            }
        }
    }

    fn callFmt(self: Env, func: anytype, comptime fmt: []const u8, args: anytype) void {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print(fmt, args) catch {};
        @call(.auto, func, .{ self, buffer[0..writer.end] });
    }

    fn isStringLike(comptime ty: std.builtin.Type.Pointer) bool {
        const child_info = @typeInfo(ty.child);
        const ret = switch (ty.size) {
            .slice => ty.child == u8,
            .one => child_info == .array and child_info.array.child == u8,
            else => false,
        };
        return ret;
    }
};

// ---------------------------------------------------------------------------
// Pre-interned symbol cache — initialized once at module load, valid for the
// lifetime of the Emacs session.  Every field is a global reference so it
// stays valid across different emacs_env pointers.
// ---------------------------------------------------------------------------

pub const Sym = struct {
    // Common values
    nil: Value,
    t: Value,

    // Face property keywords
    @":foreground": Value,
    @":background": Value,
    @":weight": Value,
    @":slant": Value,
    @":underline": Value,
    @":style": Value,
    @":color": Value,
    @":strike-through": Value,

    // Face property values
    bold: Value,
    light: Value,
    italic: Value,
    wave: Value,
    @"double-line": Value,
    dot: Value,
    dash: Value,
    line: Value,
    @":font": Value,

    // Built-in functions
    cons: Value,
    list: Value,
    set: Value,
    @"symbol-value": Value,
    @"put-text-property": Value,
    @"goto-char": Value,
    point: Value,
    insert: Value,
    @"forward-line": Value,
    @"move-to-column": Value,
    @"erase-buffer": Value,
    @"line-end-position": Value,
    @"line-beginning-position": Value,
    @"point-min": Value,
    @"point-max": Value,
    @"delete-region": Value,
    @"char-before": Value,
    @"mark-marker": Value,
    @"marker-position": Value,
    @"set-marker": Value,
    ding: Value,
    @"face-attribute": Value,
    @"query-font": Value,
    @"font-at": Value,
    @"font-get-glyphs": Value,
    @"selected-window": Value,
    fontp: Value,
    @"font-object": Value,
    @"font-has-char-p": Value,

    // Text properties
    face: Value,
    @"help-echo": Value,
    @"mouse-face": Value,
    highlight: Value,
    keymap: Value,
    default: Value,
    display: Value,
    @"min-width": Value,
    height: Value,
    @"ghostel-wrap": Value,
    @"ghostel-prompt": Value,
    @"ghostel-input": Value,

    // Ghostel symbols
    @"ghostel-link-map": Value,
    @"ghostel--set-buffer-face": Value,
    @"ghostel--set-cursor-style": Value,
    @"ghostel--update-directory": Value,
    @"ghostel--osc51-eval": Value,
    @"ghostel--osc52-handle": Value,
    @"ghostel--osc133-marker": Value,
    @"ghostel--handle-notification": Value,
    @"ghostel--osc-progress": Value,
    @"ghostel--flush-output": Value,
    @"ghostel--set-title": Value,
    @"ghostel--debug-log-vt": Value,
    @"ghostel--native-uri-at": Value,
    @"ghostel--native-link-help-echo": Value,
    @"ghostel--kitty-display-image": Value,
    @"ghostel--kitty-display-virtual": Value,
    @"ghostel--kitty-clear": Value,
    @"ghostel--rendered-font": Value,
    @"ghostel--cursor-pos": Value,
    @"ghostel--cursor-char-pos": Value,

    // Debugging and logging
    message: Value,
    @"display-warning": Value,
    @":error": Value,
    ghostel: Value,
};

pub var sym: Sym = undefined;

/// Initialize the global symbol cache.  Must be called once from
/// emacs_module_init with the environment provided by Emacs.
pub fn initSymbols(env: Env) void {
    inline for (std.meta.fields(Sym)) |field| {
        @field(sym, field.name) = env.makeGlobalRef(env.intern(field.name));
    }
}
