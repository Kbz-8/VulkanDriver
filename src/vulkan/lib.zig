const std = @import("std");
const vk = @import("vulkan");

pub const icd = @import("icd.zig");
pub const dispatchable = @import("dispatchable.zig");

pub const Instance = @import("Instance.zig");
pub const PhysicalDevice = @import("PhysicalDevice.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logFn,
};

pub fn logFn(comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    _ = level;
    _ = scope;
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.fs.File.stderr().deprecatedWriter();
    nosuspend stderr.print(format ++ "\n", args) catch return;
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
