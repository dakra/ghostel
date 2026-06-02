/// Ghostel — Emacs dynamic module entry point.
///
/// This is the top-level file compiled into ghostel-module.so/.dylib.
/// It exports emacs_module_init (the C entry point Emacs calls on load)
/// and registers all Elisp-callable functions.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const emacs = @import("emacs.zig");
const ComintFilter = @import("comint_filter.zig");
const GhostelTerm = @import("GhostelTerm.zig");
const sys = @import("sys.zig");
const pty = @import("pty.zig");

const c = emacs.c;

/// In debug builds, all allocations go through DebugAllocator for corruption
/// detection (double-free, use-after-free, overflow canaries).  A debug-only
/// kill-emacs-hook explicitly deinits all live terminals before process exit so
/// atexit can call deinit() on a clean slate.
var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
var alloc: Allocator = std.heap.c_allocator;

/// Module version — see src/version.zig.  Keep in sync with ghostel.el
/// and build.zig.zon.
const version = @import("version.zig").version;

extern fn atexit(func: *const fn () callconv(.c) void) c_int;

// ---------------------------------------------------------------------------
// Module entry point
// ---------------------------------------------------------------------------

/// Emacs calls this when loading the dynamic module.
export fn emacs_module_init(runtime: *c.struct_emacs_runtime) callconv(.c) c_int {
    if (runtime.size < @sizeOf(c.struct_emacs_runtime)) {
        return 1; // ABI mismatch
    }

    if (builtin.mode == .Debug) {
        alloc = debug_alloc.allocator();
        _ = atexit(&debugAtExit);
    }

    const raw_env = runtime.get_environment.?(runtime);
    emacs.initModule(alloc, raw_env);

    const env = emacs.Env.init(raw_env);

    env.registerFunctions(&emacs_functions);

    ComintFilter.initModule(alloc, env);
    GhostelTerm.initModule(alloc, env);

    // Install system callbacks (PNG decoder for kitty graphics, logging).
    sys.init();

    _ = env.f("provide", .{emacs.sym.@"ghostel-module"});
    return 0;
}

fn debugAtExit() callconv(.c) void {
    if (debug_alloc.deinit() == .leak) {
        std.debug.print("ghostel: memory leak detected at exit\n", .{});
    }
}

// ---------------------------------------------------------------------------
// Plugin version — required by Emacs >= 27
// ---------------------------------------------------------------------------

export const plugin_is_GPL_compatible: c_int = 0;

// ---------------------------------------------------------------------------
// Exported Elisp functions
// ---------------------------------------------------------------------------

const emacs_functions = [_]emacs.FunctionEntry{
    .{
        .name = "ghostel--module-version",
        .arity = .{ 0, 0 },
        .doc =
        \\Return the native module version string.
        \\
        \\(ghostel--module-version)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, _: [*c]emacs.Value) !emacs.Value {
                return env.makeString(version);
            }
        },
    },
    .{
        .name = "ghostel--enable-vt-log",
        .arity = .{ 0, 0 },
        .doc =
        \\Enable libghostty internal log routing to *ghostel-debug*.
        \\
        \\(ghostel--enable-vt-log)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, _: [*c]emacs.Value) !emacs.Value {
                vt_log_active = true;
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--disable-vt-log",
        .arity = .{ 0, 0 },
        .doc =
        \\Disable libghostty internal log routing.
        \\
        \\(ghostel--disable-vt-log)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, _: [*c]emacs.Value) !emacs.Value {
                vt_log_active = false;
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--pty-password-input-p",
        .arity = .{ 1, 1 },
        .doc =
        \\Return t if the tty at PATH is in canonical mode with echo off.
        \\
        \\This mirrors libghostty's password-input heuristic.  Returns nil when the path can't be opened, `tcgetattr' fails, or the tty is in some other state.
        \\
        \\(ghostel--pty-password-input-p PATH)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                var stack_buf: [1024]u8 = undefined;
                const path = env.extractString(args[0], &stack_buf) catch return env.nil();
                return if (pty.isPasswordMode(path)) env.t() else env.nil();
            }
        },
    },
};

// ---------------------------------------------------------------------------
// zig log callback
// ---------------------------------------------------------------------------

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = if (builtin.mode == .Debug) .debug else .warn,
};

/// Whether VT logging is active.
pub var vt_log_active: bool = false;

/// Log callback matching GhosttySysLogFn.  Formats the message and
/// forwards it to `ghostel--debug-log-vt' in Elisp.
fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    std.log.defaultLog(message_level, scope, format, args);

    if (!vt_log_active) return;
    const env = emacs.current_env orelse return;
    const level_str: []const u8 = switch (message_level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    };
    const scope_slice = @tagName(scope);
    var buf: [4096]u8 = undefined;
    const msg_slice = std.fmt.bufPrint(&buf, format, args) catch return;

    _ = env.f("ghostel--debug-log-vt", .{ level_str, scope_slice, msg_slice });

    // If the Elisp call signaled an error (e.g. ghostel--debug-log-vt is
    // void-function because ghostel-debug.el isn't loaded), clear it so it
    // doesn't leak into the calling context and disable logging to prevent
    // repeated errors.
    if (env.nonLocalExitCheck() != .normal) {
        env.nonLocalExitClear();
        vt_log_active = false;
    }
}
