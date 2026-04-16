const std = @import("std");

const vendored_emacs_module_dir = "include";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_release = optimize != .Debug;
    const resolved_target = target.result;
    const target_os = resolved_target.os.tag;
    const emacs_module_dir = resolveEmacsModuleDir(b);
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
    });

    const ghostty_lib = ghostty_dep.artifact("ghostty-vt-static");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = if (is_release) true else null,
        .omit_frame_pointer = if (is_release) true else null,
    });
    addModuleIncludes(mod, emacs_module_dir, ghostty_lib);
    mod.linkLibrary(ghostty_lib);

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
        addWindowsRuntimeLibraries(b, lib, resolved_target);
    }

    b.installArtifact(lib);

    const copy_step = b.addInstallFile(
        lib.getEmittedBin(),
        moduleOutputName(target_os),
    );
    b.getInstallStep().dependOn(&copy_step.step);

    // ConPTY module — Windows-only pseudoconsole backend.
    if (target_os == .windows) {
        const emacs_mod = b.createModule(.{
            .root_source_file = b.path("src/emacs.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        emacs_mod.addSystemIncludePath(emacs_module_dir);

        const dyn_loader_abi_mod = b.createModule(.{
            .root_source_file = dynLoaderAbiSourcePath(b),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        dyn_loader_abi_mod.addImport("emacs", emacs_mod);

        const conpty_mod = b.createModule(.{
            .root_source_file = conptyModuleSourcePath(b),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = if (is_release) true else null,
        });
        conpty_mod.addSystemIncludePath(emacs_module_dir);
        conpty_mod.addImport("emacs", emacs_mod);
        conpty_mod.addImport("dyn_loader_abi", dyn_loader_abi_mod);

        const conpty_lib = b.addLibrary(.{
            .name = "conpty-module",
            .linkage = .dynamic,
            .root_module = conpty_mod,
        });
        addWindowsRuntimeLibraries(b, conpty_lib, resolved_target);
        b.installArtifact(conpty_lib);

        const copy_conpty = b.addInstallFile(
            conpty_lib.getEmittedBin(),
            "bin/conpty-module.dll",
        );
        b.getInstallStep().dependOn(&copy_conpty.step);
    }
}

fn addModuleIncludes(
    mod: *std.Build.Module,
    emacs_module_dir: std.Build.LazyPath,
    ghostty_lib: *std.Build.Step.Compile,
) void {
    mod.addSystemIncludePath(emacs_module_dir);
    mod.addIncludePath(ghostty_lib.getEmittedIncludeTree());
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
        .macos => "../ghostel-module.dylib",
        .windows => "bin/ghostel-module.dll",
        else => "../ghostel-module.so",
    };
}

fn conptyModuleSourcePath(b: *std.Build) std.Build.LazyPath {
    const dep = b.dependency("emacs_util_mods", .{});
    return dep.path("src/conpty/module.zig");
}

fn dynLoaderAbiSourcePath(b: *std.Build) std.Build.LazyPath {
    const dep = b.dependency("emacs_util_mods", .{});
    return dep.path("src/dyn-loader/abi.zig");
}

fn addWindowsRuntimeLibraries(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
    rt: std.Target,
) void {
    lib.linkSystemLibrary("kernel32");
    // Future-proofing for MSVC toolchain builds (CI currently uses gnu ABI).
    if (rt.abi != .msvc) return;

    lib.linkSystemLibrary("libvcruntime");

    const arch = rt.cpu.arch;
    const sdk = std.zig.WindowsSdk.find(b.allocator, arch) catch null;
    if (sdk) |s| {
        if (s.windows10sdk) |w10| {
            const arch_str: []const u8 = switch (arch) {
                .x86_64 => "x64",
                .x86 => "x86",
                .aarch64 => "arm64",
                else => "x64",
            };
            const ucrt_lib_path = std.fmt.allocPrint(
                b.allocator,
                "{s}\\Lib\\{s}\\ucrt\\{s}",
                .{ w10.path, w10.version, arch_str },
            ) catch null;

            if (ucrt_lib_path) |path| {
                lib.addLibraryPath(.{ .cwd_relative = path });
            }
        }
    }

    lib.linkSystemLibrary("libucrt");
}
