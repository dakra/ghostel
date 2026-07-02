const std = @import("std");

file: [:0]const u8,
args: [][:0]const u8,
env: *const std.process.EnvMap,
cwd: ?[]const u8 = null,
