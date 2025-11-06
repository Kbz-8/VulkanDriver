const std = @import("std");
const vk = @import("vulkan");

pub const lib_vulkan = @import("lib_vulkan.zig");
pub const logger = @import("logger.zig");

pub const Dispatchable = @import("Dispatchable.zig").Dispatchable;
pub const VkError = @import("error_set.zig").VkError;

pub const Instance = @import("Instance.zig");
pub const Device = @import("Device.zig");
pub const PhysicalDevice = @import("PhysicalDevice.zig");
pub const VulkanAllocator = @import("VulkanAllocator.zig");

pub const VULKAN_VENDOR_ID = @typeInfo(vk.VendorId).@"enum".fields[@typeInfo(vk.VendorId).@"enum".fields.len - 1].value + 1;
pub const DRIVER_LOGS_ENV_NAME = "STROLL_LOGS_LEVEL";

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logger.log,
};

pub const LogVerboseLevel = enum {
    None,
    Standard,
    High,
};

pub inline fn getLogVerboseLevel() LogVerboseLevel {
    const allocator = std.heap.page_allocator;
    const level = std.process.getEnvVarOwned(allocator, DRIVER_LOGS_ENV_NAME) catch return .None;
    return if (std.mem.eql(u8, level, "none"))
        .None
    else if (std.mem.eql(u8, level, "all"))
        .High
    else
        .Standard;
}

comptime {
    _ = lib_vulkan;
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
