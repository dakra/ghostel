/// Zig wrapper around the Emacs dynamic module API.
///
/// Provides type-safe access to emacs_env functions, cached symbol
/// interning, and helper methods for common operations.
const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

pub const c = @cImport({
    // Ensure struct timespec is fully defined on Linux (glibc gates it
    // behind _POSIX_C_SOURCE).  Harmless on macOS/BSDs.
    @cDefine("_POSIX_C_SOURCE", "199309L");
    @cInclude("emacs-module.h");
});

/// Emacs value type alias for convenience.
pub const Value = c.emacs_value;
pub const RawEnv = ?*c.emacs_env;
pub const FnArgs = [*c]Value;
pub const FnData = ?*anyopaque;
pub const UserPtr = ?*anyopaque;
pub const Finalizer = fn (?*anyopaque) callconv(.c) void;
pub const FuncallExit = enum(c_int) {
    normal = 0,
    signal = 1,
    throw = 2,
};

const DebugUserPtr = struct {
    ptr: UserPtr,
    finalizer: *const Finalizer,
};

/// Tracks all live userptrs in debug builds so the kill-emacs-hook can
/// explicitly free them before atexit fires. This allows us to check for
/// memory leaks on exit.
var debug_userptrs: std.ArrayList(DebugUserPtr) = .{};
/// Set by the kill-emacs hook once all tracked userpts are freed; makes
/// finalizers a no-op for any subsequent GC-driven callbacks.
var debug_cleanup_done: bool = false;

var alloc: Allocator = undefined;

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

    // --- Accessing values ---

    pub fn set(self: Env, comptime symbol: []const u8, value: anytype) void {
        _ = self.f("set", .{ @field(sym, symbol), value });
    }

    pub fn symbolValue(self: Env, comptime symbol: []const u8) Value {
        return self.f("symbol-value", .{@field(sym, symbol)});
    }

    // --- Type constructors ---

    pub fn list(self: Env, items: anytype) Value {
        return self.f("list", items);
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

    pub fn makeUserPtr(self: Env, finalizer: Finalizer, ptr: UserPtr) Value {
        if (builtin.mode == .Debug) {
            if (debug_userptrs.append(alloc, .{ .ptr = ptr, .finalizer = &finalizer })) |_| {
                const debugFinalizer = struct {
                    fn debugFinalize(p: ?*anyopaque) callconv(.c) void {
                        if (debug_cleanup_done) return;
                        finalizer(p);
                    }
                }.debugFinalize;
                return self.raw.make_user_ptr.?(self.raw, &debugFinalizer, ptr);
            } else |_| {
                std.log.err("Failed to allocate for debug userptr storage", .{});
            }
        }

        return self.raw.make_user_ptr.?(self.raw, &finalizer, ptr);
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

    pub fn cons(self: Env, car: anytype, cdr: anytype) Value {
        return self.f("cons", .{ car, cdr });
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

    /// Extract val as f64, coercing Emacs integers to floats.
    /// Returns default if val is not a number, avoiding a wrong-type-argument
    /// signal that would corrupt the env's non-local exit state.
    pub fn asFloat(self: Env, val: Value, default: f64) f64 {
        if (self.isNil(self.f("numberp", .{val}))) return default;
        return self.extractFloat(self.f("float", .{val}));
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

    pub fn nonLocalExitCheck(self: Env) FuncallExit {
        return @enumFromInt(self.raw.non_local_exit_check.?(self.raw));
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
        _ = self.funcall(sym.fset, &[_]Value{ name_sym, fun });
    }

    /// Call (provide 'feature).
    pub fn provide(self: Env, feature: [*:0]const u8) void {
        _ = self.funcall(sym.provide, &[_]Value{self.intern(feature)});
    }

    // --- Buffer helpers ---

    pub fn point(self: Env) Value {
        return self.f("point", .{});
    }

    pub fn gotoChar(self: Env, pos: anytype) void {
        _ = self.f("goto-char", .{pos});
    }

    pub fn insert(self: Env, text: []const u8) void {
        _ = self.f("insert", .{text});
    }

    pub fn forwardLine(self: Env, n: anytype) i64 {
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

    pub fn deleteRegion(self: Env, start: anytype, end: anytype) void {
        _ = self.f("delete-region", .{ start, end });
    }

    pub fn eobp(self: Env) bool {
        return self.isNotNil(self.f("eobp", .{}));
    }

    pub fn putTextProperty(
        self: Env,
        start: anytype,
        end: anytype,
        comptime prop: []const u8,
        value: anytype,
    ) void {
        _ = self.f("put-text-property", .{ start, end, @field(sym, prop), value });
    }

    /// Create a unibyte string (for binary data like PNG images).
    /// Returns null if the API is unavailable (Emacs < 28).
    pub fn makeUnibyteString(self: Env, str: []const u8) ?Value {
        const func = self.raw.make_unibyte_string orelse return null;
        return func(self.raw, str.ptr, @intCast(str.len));
    }

    // --- Logging and debugging ---

    /// Signal an error with a message string.
    pub fn signalError(self: Env, comptime msg: []const u8, objects: anytype) void {
        self.nonLocalExitSignal(
            sym.@"error",
            self.f("list", .{self.format("ghostel: " ++ msg, objects)}),
        );
    }

    pub fn message(self: Env, msg: []const u8, objects: anytype) void {
        const all_args = [1]Value{self.makeString(msg)} ++ self.makeValues(objects);
        _ = self.funcall(sym.message, &all_args);
    }

    pub fn format(self: Env, msg: []const u8, objects: anytype) Value {
        const all_args = [1]Value{self.makeString(msg)} ++ self.makeValues(objects);
        return self.funcall(sym.format, &all_args);
    }

    pub fn logError(self: Env, comptime msg: []const u8, objects: anytype) void {
        _ = self.f("display-warning", .{
            sym.ghostel,
            self.format("ghostel: " ++ msg, objects),
            sym.@":error",
        });
    }

    /// Writes stack trace as Emacs messages if in debug mode
    pub fn logStackTrace(self: Env, stack_trace: ?*std.builtin.StackTrace) void {
        if (comptime builtin.mode == .Debug) {
            if (stack_trace) |trace| {
                var buffer: [4096]u8 = undefined;
                var writer = std.Io.Writer.fixed(&buffer);
                const debug_info = std.debug.getSelfDebugInfo() catch |err| {
                    self.logError("Unable to get debug info: %s", .{@errorName(err)});
                    return;
                };
                std.debug.writeStackTrace(trace.*, &writer, debug_info, .no_color) catch |err| {
                    self.logError("Unable to print stack trace: %s", .{@errorName(err)});
                    return;
                };
                self.logError("%s", .{buffer[0..writer.end]});
            }
        }
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

const interned_symbols = [_][:0]const u8{
    "eobp",
    ":background",
    ":color",
    ":error",
    ":font",
    ":foreground",
    ":inverse-video",
    ":overline",
    ":slant",
    ":strike-through",
    ":style",
    ":underline",
    ":weight",
    ":width",
    "bold",
    "bright",
    "char-after",
    "char-before",
    "cons",
    "dash",
    "default",
    "delete-region",
    "ding",
    "display",
    "display-warning",
    "dot",
    "double-line",
    "erase-buffer",
    "error",
    "face",
    "face-attribute",
    "float",
    "font-at",
    "font-get-glyphs",
    "font-has-char-p",
    "font-object",
    "fontp",
    "format",
    "forward-line",
    "fset",
    "ghostel",
    "ghostel--cursor-char-pos",
    "ghostel--cursor-pos",
    "ghostel--debug-log-vt",
    "ghostel--flush-output",
    "ghostel--handle-notification",
    "ghostel--kitty-clear",
    "ghostel--kitty-display-image",
    "ghostel--kitty-display-virtual",
    "ghostel--native-link-help-echo",
    "ghostel--native-uri-at",
    "ghostel--osc-progress",
    "ghostel--osc133-marker",
    "ghostel--osc51-eval",
    "ghostel--osc52-handle",
    "ghostel--query-font-cached",
    "ghostel--rendered-font",
    "ghostel--set-buffer-face",
    "ghostel--set-cursor-style",
    "ghostel--set-title",
    "ghostel--update-directory",
    "ghostel-comint--update-dir",
    "ghostel-glyph-scale-floor",
    "ghostel-input",
    "ghostel-link-map",
    "ghostel-prompt",
    "ghostel-wrap",
    "goto-char",
    "height",
    "help-echo",
    "highlight",
    "insert",
    "italic",
    "keymap",
    "light",
    "line",
    "line-beginning-position",
    "line-end-position",
    "list",
    "mark-marker",
    "marker-position",
    "message",
    "min-width",
    "mouse-face",
    "move-to-column",
    "nil",
    "numberp",
    "point",
    "point-max",
    "point-min",
    "provide",
    "put-text-property",
    "query-font",
    "selected-window",
    "set",
    "set-marker",
    "space",
    "symbol-value",
    "t",
    "wave",
};

fn SymbolCache(comptime symbols: []const [:0]const u8) type {
    var cache_fields: [symbols.len]std.builtin.Type.StructField = undefined;
    for (symbols, 0..) |symbol, i| {
        cache_fields[i] = .{
            .name = symbol,
            .type = Value,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Value),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &cache_fields,
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_tuple = false,
    } });
}

pub var sym: SymbolCache(&interned_symbols) = undefined;

/// Initialize the global symbol cache.  Must be called once from
/// emacs_module_init with the environment provided by Emacs.
pub fn initModule(allocator: Allocator, raw: *c.emacs_env) void {
    alloc = allocator;

    const env = Env.init(raw);
    inline for (std.meta.fields(@TypeOf(sym))) |field| {
        @field(sym, field.name) = env.makeGlobalRef(env.intern(field.name));
    }

    if (builtin.mode == .Debug) {
        const cleanup_fn = env.makeFunction(
            0,
            0,
            &debugKillEmacsHook,
            "Explicitly destroy all ghostel terminals for leak detection.",
            null,
        );
        _ = env.funcall(env.intern("add-hook"), &[_]Value{ env.intern("kill-emacs-hook"), cleanup_fn });
    }
}

fn debugKillEmacsHook(_: ?*c.emacs_env, _: isize, _: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    for (debug_userptrs.items) |user_ptr| {
        user_ptr.finalizer(user_ptr.ptr);
    }
    debug_userptrs.deinit(alloc);
    debug_cleanup_done = true;
    return sym.nil;
}
