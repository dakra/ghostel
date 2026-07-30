const std = @import("std");
const builtin = @import("builtin");
const module_version = @import("src/version.zig").version;

var io: std.Io.Threaded = .init_single_threaded;

// Keep in sync with build.zig.zon (minimum_zig_version) and the CI workflows.
const required_zig = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0 };
comptime {
    if (builtin.zig_version.order(required_zig) != .eq)
        @compileError("ghostel requires exactly Zig 0.16.0, found " ++ builtin.zig_version_string);
}

const vendored_emacs_module_dir = "vendor";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ghostty_optimize = b.option(
        std.builtin.OptimizeMode,
        "ghostty-optimize",
        "Optimization mode for the ghostty dependency (defaults to the main optimize option)",
    ) orelse optimize;
    const is_release = optimize != .Debug;
    const target_os = target.result.os.tag;
    const android_libc: ?AndroidLibC = if (target.result.abi.isAndroid())
        resolveAndroidLibC(b, target.result)
    else
        null;

    // On-device Termux builds have no NDK, whose sysroot ghostty's vendored
    // simdutf/highway C++ builds require; use ghostty's scalar path there.
    const ghostty_simd = if (android_libc) |libc| libc.source != .termux else true;
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = ghostty_optimize,
        .@"emit-lib-vt" = true,
        .simd = ghostty_simd,
    });

    const ghostty_vt = ghostty_dep.module("ghostty-vt");

    const emacs_module_dir = resolveEmacsModuleDir(b);
    const translate_emacs = b.addTranslateC(.{
        .root_source_file = b.path("src/emacs.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_emacs.addIncludePath(emacs_module_dir);
    if (android_libc) |libc| addAndroidIncludes(translate_emacs, libc);
    const emacs_c = translate_emacs.createModule();

    const platform_c: std.Build.Module.Import = switch (target_os) {
        .windows => platform: {
            const translate_windows = b.addTranslateC(.{
                .root_source_file = b.path("src/win32.h"),
                .target = target,
                .optimize = optimize,
            });
            break :platform .{
                .name = "windows_c",
                .module = translate_windows.createModule(),
            };
        },
        else => platform: {
            const translate_posix = b.addTranslateC(.{
                .root_source_file = b.path("src/posix.h"),
                .target = target,
                .optimize = optimize,
            });
            if (android_libc) |libc| addAndroidIncludes(translate_posix, libc);
            break :platform .{
                .name = "posix_c",
                .module = translate_posix.createModule(),
            };
        },
    };

    const translate_stb = b.addTranslateC(.{
        .root_source_file = b.path("vendor/stb/stb_image.h"),
        .target = target,
        .optimize = optimize,
    });
    if (android_libc) |libc| addAndroidIncludes(translate_stb, libc);
    const stb_image_c = translate_stb.createModule();

    const mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = if (is_release) true else null,
        .omit_frame_pointer = if (is_release) true else null,
        .imports = &.{
            .{ .name = "ghostty-vt", .module = ghostty_vt },
            .{ .name = "emacs_c", .module = emacs_c },
            platform_c,
            .{ .name = "stb_image_c", .module = stb_image_c },
        },
    });

    // stb_image for PNG decoding (kitty graphics)
    mod.addIncludePath(b.path("vendor/stb"));
    mod.addCSourceFile(.{ .file = b.path("src/stb_image.c") });

    const lib = b.addLibrary(.{
        .name = "ghostel-module",
        .linkage = .dynamic,
        .root_module = mod,
    });
    if (is_release) {
        lib.link_gc_sections = true;
        lib.link_function_sections = true;
        lib.link_data_sections = true;
        lib.dead_strip_dylibs = true;

        if (target_os == .linux) {
            lib.setVersionScript(b.path("symbols.map"));
        }
    }
    if (target_os == .windows) {
        lib.root_module.linkSystemLibrary("kernel32", .{});
    }
    if (android_libc) |libc| {
        // Support 16kb page sizes, required for Android 15+.
        lib.link_z_max_page_size = 16384;
        setAndroidLibCFile(b, lib, libc);
    }

    const copy_step = b.addInstallFile(
        lib.getEmittedBin(),
        moduleOutputName(target_os),
    );
    b.getInstallStep().dependOn(&copy_step.step);

    // Sidecar version file sitting next to the binary.  The elisp loader
    // reads this before `module-load` to detect a stale module without
    // mapping it into the process.
    const version_wf = b.addWriteFiles();
    const version_file = version_wf.add("ghostel-module.version", module_version ++ "\n");
    const copy_version_step = b.addInstallFile(version_file, "ghostel-module.version");
    b.getInstallStep().dependOn(&copy_version_step.step);

    if (target_os == .windows) {
        if (b.option([]const u8, "windows-conpty-package-dir", "Unpacked Microsoft.Windows.Console.ConPTY NuGet package directory")) |dir| {
            installWindowsConptyRuntime(b, target.result.cpu.arch, dir);
        }
    }

    // ----------------------------------------------------------------
    // `zig build test` — pure-Zig unit tests.
    //
    // Modules that don't depend on emacs-module are covered here. End-to-end
    // tests through the C API run via `make test-native`.
    // ----------------------------------------------------------------
    const test_step = b.step("test", "Run Zig unit tests");

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "ghostty-vt", .module = ghostty_vt },
            platform_c,
            .{ .name = "stb_image_c", .module = stb_image_c },
        },
    });
    tests_mod.addIncludePath(b.path("vendor/stb"));
    tests_mod.addCSourceFile(.{ .file = b.path("src/stb_image.c") });
    const tests = b.addTest(.{ .root_module = tests_mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn resolveEmacsModuleDir(b: *std.Build) std.Build.LazyPath {
    if (b.graph.environ_map.get("EMACS_INCLUDE_DIR")) |dir| {
        ensureEmacsModuleHeaderExists(b.allocator, "EMACS_INCLUDE_DIR", dir);
        return .{ .cwd_relative = dir };
    }

    if (b.graph.environ_map.get("EMACS_BIN_DIR")) |bin_dir| {
        const include_dir = resolveEmacsIncludeDirFromBin(b.allocator, bin_dir) orelse
            std.debug.panic(
                "EMACS_BIN_DIR={s} does not resolve to a directory containing emacs-module.h",
                .{bin_dir},
            );
        return .{ .cwd_relative = include_dir };
    }

    return b.path(vendored_emacs_module_dir);
}

fn resolveEmacsIncludeDirFromBin(
    allocator: std.mem.Allocator,
    bin_dir: []const u8,
) ?[]const u8 {
    const include_dir = std.fs.path.join(allocator, &.{ bin_dir, "..", "include" }) catch
        @panic("out of memory while resolving EMACS_BIN_DIR");
    if (dirHasEmacsModuleHeader(allocator, include_dir)) {
        return include_dir;
    }
    allocator.free(include_dir);

    const share_include_dir = std.fs.path.join(
        allocator,
        &.{ bin_dir, "..", "share", "emacs", "include" },
    ) catch @panic("out of memory while resolving EMACS_BIN_DIR");
    if (dirHasEmacsModuleHeader(allocator, share_include_dir)) {
        return share_include_dir;
    }
    allocator.free(share_include_dir);

    return null;
}

fn ensureEmacsModuleHeaderExists(
    allocator: std.mem.Allocator,
    env_name: []const u8,
    dir: []const u8,
) void {
    if (!dirHasEmacsModuleHeader(allocator, dir)) {
        std.debug.panic("{s}={s} does not contain emacs-module.h", .{ env_name, dir });
    }
}

fn dirHasEmacsModuleHeader(allocator: std.mem.Allocator, dir: []const u8) bool {
    const header_path = std.fs.path.join(allocator, &.{ dir, "emacs-module.h" }) catch
        @panic("out of memory while resolving emacs-module.h");
    defer allocator.free(header_path);

    std.Io.Dir.cwd().access(io.io(), header_path, .{}) catch return false;
    return true;
}

fn moduleOutputName(target_os: std.Target.Os.Tag) []const u8 {
    return switch (target_os) {
        .macos => "ghostel-module.dylib",
        .windows => "ghostel-module.dll",
        else => "ghostel-module.so",
    };
}

/// Bionic libc paths for an Android target.  Zig bundles no bionic, so
/// headers and crt objects come from an external sysroot.
const AndroidLibC = struct {
    source: enum { ndk, termux },
    include_dir: []const u8,
    sys_include_dir: []const u8,
    crt_dir: []const u8,
    /// Directory holding libraries that carry no API level
    /// (`libc++_shared.so' and friends).
    lib_dir: []const u8,
};

/// Resolve the bionic sysroot for TARGET.  Cross builds use the NDK,
/// located through `ANDROID_NDK_HOME`, or the newest `ndk/<version>`
/// under `ANDROID_HOME`/`ANDROID_SDK_ROOT`.  On-device builds in Termux
/// (no NDK) fall back to the `$PREFIX` sysroot that Termux's
/// `ndk-sysroot` package provides.
fn resolveAndroidLibC(b: *std.Build, target: std.Target) AndroidLibC {
    if (findAndroidNdk(b)) |ndk_dir| return androidNdkLibC(b, target, ndk_dir);
    if (termuxLibC(b, target)) |libc| return libc;
    std.debug.panic(
        "Android builds need the Android NDK (set ANDROID_NDK_HOME or ANDROID_HOME); " ++
            "inside Termux, `pkg install ndk-sysroot` instead",
        .{},
    );
}

fn androidNdkLibC(b: *std.Build, target: std.Target, ndk_dir: []const u8) AndroidLibC {
    const triple = androidTriple(target.cpu.arch) orelse std.debug.panic(
        "unsupported Android architecture: {s}",
        .{@tagName(target.cpu.arch)},
    );
    const host = androidNdkHost() orelse std.debug.panic(
        "unsupported host for Android cross-compilation: {s}",
        .{@tagName(builtin.os.tag)},
    );

    const sysroot = b.pathJoin(&.{ ndk_dir, "toolchains", "llvm", "prebuilt", host, "sysroot" });
    const lib_dir = b.pathJoin(&.{ sysroot, "usr", "lib", triple });
    return .{
        .source = .ndk,
        .include_dir = b.pathJoin(&.{ sysroot, "usr", "include" }),
        .sys_include_dir = b.pathJoin(&.{ sysroot, "usr", "include", triple }),
        .crt_dir = b.pathJoin(&.{ lib_dir, b.fmt("{d}", .{target.os.version_range.linux.android}) }),
        .lib_dir = lib_dir,
    };
}

/// Termux's `ndk-sysroot` package installs the bionic headers into
/// `$PREFIX/include`, the architecture-specific ones (`asm/' and friends) into
/// a target triple subdirectory of it, and the crt objects into `$PREFIX/lib`.
fn termuxLibC(b: *std.Build, target: std.Target) ?AndroidLibC {
    if (b.graph.environ_map.get("TERMUX_VERSION") == null) return null;
    const prefix = b.graph.environ_map.get("PREFIX") orelse return null;
    if (prefix.len == 0) return null;

    const include_dir = b.pathJoin(&.{ prefix, "include" });
    if (!dirHasFile(b.allocator, include_dir, "errno.h")) return null;
    const lib_dir = b.pathJoin(&.{ prefix, "lib" });

    const triple = androidTriple(target.cpu.arch) orelse std.debug.panic(
        "unsupported Android architecture: {s}",
        .{@tagName(target.cpu.arch)},
    );
    const arch_include = b.pathJoin(&.{ include_dir, triple });
    const sys_include_dir = if (dirHasFile(b.allocator, arch_include, "asm/types.h"))
        arch_include
    else
        include_dir;

    // ghostty's vendored android-ndk helper insists on an NDK directory
    // at graph construction time, although none of the artifacts that
    // link through it are built here (simd is disabled on-device).  A
    // stub keeps the graph constructible without an NDK.
    b.graph.environ_map.put("ANDROID_NDK_HOME", prefix) catch @panic("OOM");
    return .{
        .source = .termux,
        .include_dir = include_dir,
        .sys_include_dir = sys_include_dir,
        .crt_dir = termuxCrtDir(b, target.cpu.arch, lib_dir),
        .lib_dir = lib_dir,
    };
}

fn dirHasFile(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ dir, name }) catch
        @panic("out of memory while resolving a libc path");
    defer allocator.free(path);
    std.Io.Dir.cwd().access(io.io(), path, .{}) catch return false;
    return true;
}

/// Zig resolves `-lc' and friends from `crt_dir' alone, so that directory
/// has to hold the crt objects and the bionic stubs together.  Termux's
/// `ndk-sysroot' ships only the former and leaves libc, libm and libdl to
/// the system, so stage a directory carrying both.  A sysroot that already
/// has its own stubs, as an NDK mirror does, is used as-is.
fn termuxCrtDir(b: *std.Build, arch: std.Target.Cpu.Arch, lib_dir: []const u8) []const u8 {
    if (dirHasFile(b.allocator, lib_dir, "libc.so")) return lib_dir;
    return stageTermuxCrtDir(b, arch, lib_dir) catch |err| std.debug.panic(
        "cannot stage the Termux crt directory: {s}",
        .{@errorName(err)},
    );
}

fn stageTermuxCrtDir(b: *std.Build, arch: std.Target.Cpu.Arch, lib_dir: []const u8) ![]const u8 {
    const system_dir: []const u8 = switch (arch) {
        .aarch64, .x86_64 => "/system/lib64",
        else => "/system/lib",
    };
    const cache_root = b.cache_root.path orelse return error.NoCacheRoot;
    const staged = b.pathJoin(&.{ cache_root, "termux-crt" });
    const cwd: std.Io.Dir = .cwd();

    var crt = try cwd.openDir(io.io(), lib_dir, .{ .iterate = true });
    defer crt.close(io.io());
    var it = crt.iterate();
    while (try it.next(io.io())) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".o")) continue;
        try cwd.copyFile(
            b.pathJoin(&.{ lib_dir, entry.name }),
            cwd,
            b.pathJoin(&.{ staged, entry.name }),
            io.io(),
            .{ .make_path = true },
        );
    }

    for ([_][]const u8{ "libc.so", "libm.so", "libdl.so" }) |name| {
        try cwd.copyFile(
            b.pathJoin(&.{ system_dir, name }),
            cwd,
            b.pathJoin(&.{ staged, name }),
            io.io(),
            .{ .make_path = true },
        );
    }

    return staged;
}

fn setAndroidLibCFile(b: *std.Build, lib: *std.Build.Step.Compile, libc: AndroidLibC) void {
    const wf = b.addWriteFiles();
    const libc_file = wf.add("android-libc.txt", b.fmt(
        \\include_dir={s}
        \\sys_include_dir={s}
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ libc.include_dir, libc.sys_include_dir, libc.crt_dir }));

    lib.setLibCFile(libc_file);
    lib.root_module.addLibraryPath(.{ .cwd_relative = libc.lib_dir });
}

/// `zig translate-c` finds no bionic headers on its own (the libc file
/// only reaches the compile step), so Android sysroot includes are fed
/// to every translate-c step explicitly.
fn addAndroidIncludes(translate_c: *std.Build.Step.TranslateC, libc: AndroidLibC) void {
    translate_c.addSystemIncludePath(.{ .cwd_relative = libc.include_dir });
    if (!std.mem.eql(u8, libc.sys_include_dir, libc.include_dir))
        translate_c.addSystemIncludePath(.{ .cwd_relative = libc.sys_include_dir });
    // translate-c's aro frontend lacks the clang extensions bionic
    // annotates its declarations with: nullability specifiers inside
    // array declarators and the `__overloadable' ioctl redeclaration.
    translate_c.defineCMacro("_Nonnull", "");
    translate_c.defineCMacro("_Nullable", "");
    translate_c.defineCMacro("_Null_unspecified", "");
    translate_c.defineCMacro("BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD", "1");
}

fn findAndroidNdk(b: *std.Build) ?[]const u8 {
    if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |dir| {
        if (dir.len > 0) return dir;
    }

    for ([_][]const u8{ "ANDROID_HOME", "ANDROID_SDK_ROOT" }) |env_name| {
        const sdk_dir = b.graph.environ_map.get(env_name) orelse continue;
        if (sdk_dir.len == 0) continue;
        if (findLatestAndroidNdk(b, sdk_dir)) |dir| return dir;
    }

    // Default SDK location, mirroring the ghostty dependency's search.
    const home_env = if (builtin.os.tag == .windows) "LOCALAPPDATA" else "HOME";
    const home = b.graph.environ_map.get(home_env) orelse return null;
    const default_sdk = b.pathJoin(&.{
        home,
        switch (builtin.os.tag) {
            .linux => "Android/sdk",
            .macos => "Library/Android/Sdk",
            .windows => "Android/Sdk",
            else => return null,
        },
    });
    return findLatestAndroidNdk(b, default_sdk);
}

fn findLatestAndroidNdk(b: *std.Build, sdk_dir: []const u8) ?[]const u8 {
    const ndk_root = b.pathJoin(&.{ sdk_dir, "ndk" });
    var dir = std.Io.Dir.cwd().openDir(io.io(), ndk_root, .{ .iterate = true }) catch return null;
    defer dir.close(io.io());

    var latest: ?struct {
        name: []const u8,
        version: std.SemanticVersion,
    } = null;
    var it = dir.iterate();
    while (it.next(io.io()) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const version = std.SemanticVersion.parse(entry.name) catch continue;
        if (latest) |current| {
            if (version.order(current.version) != .gt) continue;
        }
        latest = .{ .name = b.dupe(entry.name), .version = version };
    }

    const found = latest orelse return null;
    return b.pathJoin(&.{ ndk_root, found.name });
}

fn androidTriple(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .arm => "arm-linux-androideabi",
        .aarch64 => "aarch64-linux-android",
        .x86 => "i686-linux-android",
        .x86_64 => "x86_64-linux-android",
        else => null,
    };
}

fn androidNdkHost() ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux-x86_64",
        // Every macOS host uses the same prebuilt toolchain.
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => null,
    };
}

fn installWindowsConptyRuntime(b: *std.Build, arch: std.Target.Cpu.Arch, package_dir: []const u8) void {
    const runtime_arch = windowsConptyRuntimeArch(arch) orelse return;
    const conpty_path = b.pathJoin(&.{ package_dir, "runtimes", b.fmt("win-{s}", .{runtime_arch}), "native", "conpty.dll" });
    const copy_conpty = b.addInstallFile(.{ .cwd_relative = conpty_path }, "conpty.dll");
    b.getInstallStep().dependOn(&copy_conpty.step);

    switch (arch) {
        .x86 => {
            installWindowsOpenConsole(b, package_dir, "x86");
            installWindowsOpenConsole(b, package_dir, "x64");
            installWindowsOpenConsole(b, package_dir, "arm64");
        },
        .x86_64 => {
            installWindowsOpenConsole(b, package_dir, "x64");
            installWindowsOpenConsole(b, package_dir, "arm64");
        },
        .aarch64 => installWindowsOpenConsole(b, package_dir, "arm64"),
        else => {},
    }
}

fn windowsConptyRuntimeArch(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .x86 => "x86",
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => null,
    };
}

fn installWindowsOpenConsole(b: *std.Build, package_dir: []const u8, host_arch: []const u8) void {
    const source = b.pathJoin(&.{ package_dir, "build", "native", "runtimes", host_arch, "OpenConsole.exe" });
    const dest = b.fmt("{s}/OpenConsole.exe", .{host_arch});
    const copy = b.addInstallFile(.{ .cwd_relative = source }, dest);
    b.getInstallStep().dependOn(&copy.step);
}
