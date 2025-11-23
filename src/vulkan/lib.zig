//! Here lies the documentation of the common internal API that backends need to implement

const std = @import("std");
const vk = @import("vulkan");
pub const vku = @cImport({
    @cInclude("vulkan/utility/vk_format_utils.h");
});

pub const commands = @import("commands.zig");
pub const lib_vulkan = @import("lib_vulkan.zig");
pub const logger = @import("logger.zig");
pub const errors = @import("error_set.zig");

pub const Dispatchable = @import("Dispatchable.zig").Dispatchable;
pub const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;
pub const VkError = errors.VkError;
pub const VulkanAllocator = @import("VulkanAllocator.zig");

pub const Instance = @import("Instance.zig");
pub const Device = @import("Device.zig");
pub const PhysicalDevice = @import("PhysicalDevice.zig");
pub const Queue = @import("Queue.zig");

pub const Buffer = @import("Buffer.zig");
pub const CommandBuffer = @import("CommandBuffer.zig");
pub const CommandPool = @import("CommandPool.zig");
pub const DeviceMemory = @import("DeviceMemory.zig");
pub const Fence = @import("Fence.zig");
pub const Image = @import("Image.zig");

pub const VULKAN_VENDOR_ID = @typeInfo(vk.VendorId).@"enum".fields[@typeInfo(vk.VendorId).@"enum".fields.len - 1].value + 1;

pub const DRIVER_LOGS_ENV_NAME = "STROLL_LOGS_LEVEL";
pub const DRIVER_DEBUG_ALLOCATOR_ENV_NAME = "STROLL_DEBUG_ALLOCATOR";

/// Default driver name
pub const DRIVER_NAME = "Unnamed Driver";
/// Default Vulkan version
pub const VULKAN_VERSION = vk.makeApiVersion(0, 1, 0, 0);

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logger.log,
};

pub const LogVerboseLevel = enum {
    None,
    Standard,
    High,
    TooMuch,
};

pub inline fn getLogVerboseLevel() LogVerboseLevel {
    const allocator = std.heap.page_allocator;
    const level = std.process.getEnvVarOwned(allocator, DRIVER_LOGS_ENV_NAME) catch return .None;
    return if (std.mem.eql(u8, level, "none"))
        .None
    else if (std.mem.eql(u8, level, "all"))
        .High
    else if (std.mem.eql(u8, level, "stupid"))
        .TooMuch
    else
        .Standard;
}

comptime {
    _ = lib_vulkan;
}
