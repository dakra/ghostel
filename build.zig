const std = @import("std");
const module_version = @import("src/version.zig").version;

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
    const emacs_module_dir = resolveEmacsModuleDir(b);
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = ghostty_optimize,
        .@"emit-lib-vt" = true,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = if (is_release) true else null,
        .omit_frame_pointer = if (is_release) true else null,
    });
    mod.addSystemIncludePath(emacs_module_dir);
    mod.addImport(
        "ghostty-vt",
        ghostty_dep.module("ghostty-vt"),
    );

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
        lib.linkSystemLibrary("kernel32");
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
    });
    tests_mod.addIncludePath(b.path("vendor/stb"));
    tests_mod.addCSourceFile(.{ .file = b.path("src/stb_image.c") });
    tests_mod.addImport(
        "ghostty-vt",
        ghostty_dep.module("ghostty-vt"),
    );
    const tests = b.addTest(.{ .root_module = tests_mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn resolveEmacsModuleDir(b: *std.Build) std.Build.LazyPath {
    if (b.graph.env_map.get("EMACS_INCLUDE_DIR")) |dir| {
        ensureEmacsModuleHeaderExists(b.allocator, "EMACS_INCLUDE_DIR", dir);
        return .{ .cwd_relative = dir };
    }

    if (b.graph.env_map.get("EMACS_BIN_DIR")) |bin_dir| {
        const include_dir = resolveEmacsIncludeDirFromBin(b.allocator, bin_dir) orelse
            std.debug.panic(
                "EMACS_BIN_DIR={s} does not resolve to a directory containing emacs-module.h",
                .{bin_dir},
            );
        return .{ .cwd_relative = include_dir };
    }

    return .{ .cwd_relative = vendored_emacs_module_dir };
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

    std.fs.cwd().access(header_path, .{}) catch return false;
    return true;
}

fn moduleOutputName(target_os: std.Target.Os.Tag) []const u8 {
    return switch (target_os) {
        .macos => "ghostel-module.dylib",
        .windows => "ghostel-module.dll",
        else => "ghostel-module.so",
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
