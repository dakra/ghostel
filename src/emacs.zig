/// Zig wrapper around the Emacs dynamic module API.
///
/// Provides type-safe access to emacs_env functions, cached symbol
/// interning, and helper methods for common operations.
const std = @import("std");

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

    pub fn funcall(self: Env, func: Value, args: []Value) Value {
        return self.raw.funcall.?(self.raw, func, @intCast(args.len), args.ptr);
    }

    pub fn call0(self: Env, func: Value) Value {
        return self.raw.funcall.?(self.raw, func, 0, null);
    }

    pub fn call1(self: Env, func: Value, a0: Value) Value {
        var args = [_]Value{a0};
        return self.raw.funcall.?(self.raw, func, 1, &args);
    }

    pub fn call2(self: Env, func: Value, a0: Value, a1: Value) Value {
        var args = [_]Value{ a0, a1 };
        return self.raw.funcall.?(self.raw, func, 2, &args);
    }

    pub fn call3(self: Env, func: Value, a0: Value, a1: Value, a2: Value) Value {
        var args = [_]Value{ a0, a1, a2 };
        return self.raw.funcall.?(self.raw, func, 3, &args);
    }

    pub fn call4(self: Env, func: Value, a0: Value, a1: Value, a2: Value, a3: Value) Value {
        var args = [_]Value{ a0, a1, a2, a3 };
        return self.raw.funcall.?(self.raw, func, 4, &args);
    }

    // --- Type constructors ---

    pub fn makeInteger(self: Env, n: i64) Value {
        return self.raw.make_integer.?(self.raw, @intCast(n));
    }

    pub fn makeString(self: Env, str: []const u8) Value {
        return self.raw.make_string.?(self.raw, str.ptr, @intCast(str.len));
    }

    pub fn makeUserPtr(self: Env, finalizer: ?*const fn (?*anyopaque) callconv(.c) void, ptr: ?*anyopaque) Value {
        return self.raw.make_user_ptr.?(self.raw, finalizer, ptr);
    }

    pub fn getUserPtr(self: Env, comptime T: type, val: Value) ?*T {
        const raw_ptr = self.raw.get_user_ptr.?(self.raw, val);
        return @ptrCast(@alignCast(raw_ptr));
    }

    // --- Type extraction ---

    pub fn extractInteger(self: Env, val: Value) i64 {
        return @intCast(self.raw.extract_integer.?(self.raw, val));
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

    pub fn openChannel(self: Env, process: Value) i32 {
        return self.raw.open_channel.?(self.raw, process);
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
        _ = self.call2(self.intern("fset"), name_sym, fun);
    }

    /// Call (provide 'feature).
    pub fn provide(self: Env, feature: [*:0]const u8) void {
        _ = self.call1(self.intern("provide"), self.intern(feature));
    }

    // --- Buffer helpers ---

    pub fn point(self: Env) Value {
        return self.call0(sym.point);
    }

    pub fn gotoChar(self: Env, pos: Value) void {
        _ = self.call1(sym.@"goto-char", pos);
    }

    pub fn gotoCharN(self: Env, pos: i64) void {
        _ = self.call1(sym.@"goto-char", self.makeInteger(pos));
    }

    pub fn insert(self: Env, text: []const u8) void {
        _ = self.call1(sym.insert, self.makeString(text));
    }

    pub fn forwardLine(self: Env, n: i64) i64 {
        return self.extractInteger(self.call1(sym.@"forward-line", self.makeInteger(n)));
    }

    pub fn moveToColumn(self: Env, col: i64) void {
        _ = self.call1(sym.@"move-to-column", self.makeInteger(col));
    }

    pub fn eraseBuffer(self: Env) void {
        _ = self.call0(sym.@"erase-buffer");
    }

    pub fn lineEndPosition(self: Env) Value {
        return self.call0(sym.@"line-end-position");
    }

    pub fn pointMax(self: Env) Value {
        return self.call0(sym.@"point-max");
    }

    pub fn deleteRegion(self: Env, start: Value, end: Value) void {
        _ = self.call2(sym.@"delete-region", start, end);
    }

    pub fn putTextProperty(self: Env, start: Value, end: Value, prop: Value, value: Value) void {
        _ = self.call4(sym.@"put-text-property", start, end, prop, value);
    }

    /// Signal an error with a message string.
    pub fn signalError(self: Env, msg: []const u8) void {
        self.nonLocalExitSignal(
            self.intern("error"),
            self.call1(self.intern("list"), self.makeString(msg)),
        );
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

    // Built-in functions
    cons: Value,
    list: Value,
    @"symbol-value": Value,
    @"put-text-property": Value,
    @"goto-char": Value,
    point: Value,
    insert: Value,
    @"forward-line": Value,
    @"move-to-column": Value,
    @"erase-buffer": Value,
    @"line-end-position": Value,
    @"point-max": Value,
    @"delete-region": Value,
    @"char-before": Value,

    // Text property names
    face: Value,
    @"help-echo": Value,
    @"mouse-face": Value,
    highlight: Value,
    keymap: Value,
    @"ghostel-wrap": Value,
    @"ghostel-prompt": Value,

    // Ghostel symbols
    @"ghostel-link-map": Value,
    @"ghostel--set-buffer-face": Value,
    @"ghostel--detect-urls": Value,
    @"ghostel--has-wide-chars": Value,
    @"ghostel--set-cursor-style": Value,
    @"ghostel--update-directory": Value,
    @"ghostel--osc51-eval": Value,
    @"ghostel--osc52-handle": Value,
    @"ghostel--osc133-marker": Value,
    @"ghostel--flush-output": Value,
    @"ghostel--set-title": Value,
    @"ghostel--debug-log-vt": Value,
    ding: Value,
};

pub var sym: Sym = undefined;

/// Initialize the global symbol cache.  Must be called once from
/// emacs_module_init with the environment provided by Emacs.
pub fn initSymbols(env: Env) void {
    inline for (std.meta.fields(Sym)) |field| {
        @field(sym, field.name) = env.makeGlobalRef(env.intern(field.name));
    }
}
