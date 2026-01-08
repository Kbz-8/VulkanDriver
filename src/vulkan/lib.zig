//! Here lies the documentation of the common internal API that backends need to implement

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
pub const vku = @cImport({
    @cInclude("vulkan/utility/vk_format_utils.h");
});

pub const commands = @import("commands.zig");
pub const errors = @import("error_set.zig");
pub const lib_vulkan = @import("lib_vulkan.zig");
pub const logger = @import("logger/logger.zig");

pub const Dispatchable = @import("Dispatchable.zig").Dispatchable;
pub const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;
pub const VkError = errors.VkError;
pub const VulkanAllocator = @import("VulkanAllocator.zig");
pub const RefCounter = @import("RefCounter.zig");

pub const CommandBuffer = @import("CommandBuffer.zig");
pub const Device = @import("Device.zig");
pub const Instance = @import("Instance.zig");
pub const PhysicalDevice = @import("PhysicalDevice.zig");
pub const Queue = @import("Queue.zig");

pub const BinarySemaphore = @import("BinarySemaphore.zig");
pub const Buffer = @import("Buffer.zig");
pub const BufferView = @import("BufferView.zig");
pub const CommandPool = @import("CommandPool.zig");
pub const DescriptorPool = @import("DescriptorPool.zig");
pub const DescriptorSet = @import("DescriptorSet.zig");
pub const DescriptorSetLayout = @import("DescriptorSetLayout.zig");
pub const DeviceMemory = @import("DeviceMemory.zig");
pub const Event = @import("Event.zig");
pub const Fence = @import("Fence.zig");
pub const Framebuffer = @import("Framebuffer.zig");
pub const Image = @import("Image.zig");
pub const ImageView = @import("ImageView.zig");
pub const Pipeline = @import("Pipeline.zig");
pub const PipelineCache = @import("PipelineCache.zig");
pub const PipelineLayout = @import("PipelineLayout.zig");
pub const QueryPool = @import("QueryPool.zig");
pub const RenderPass = @import("RenderPass.zig");
pub const Sampler = @import("Sampler.zig");
pub const ShaderModule = @import("ShaderModule.zig");

pub const VULKAN_VENDOR_ID = @typeInfo(vk.VendorId).@"enum".fields[@typeInfo(vk.VendorId).@"enum".fields.len - 1].value + 1;

pub const DRIVER_DEBUG_ALLOCATOR_ENV_NAME = "STROLL_DEBUG_ALLOCATOR";
pub const DRIVER_LOGS_ENV_NAME = "STROLL_LOGS_LEVEL";

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
    const allocator = std.heap.c_allocator;
    const level = std.process.getEnvVarOwned(allocator, DRIVER_LOGS_ENV_NAME) catch return .None;
    defer allocator.free(level);
    return if (std.mem.eql(u8, level, "none"))
        .None
    else if (std.mem.eql(u8, level, "all"))
        .High
    else if (std.mem.eql(u8, level, "stupid"))
        .TooMuch
    else
        .Standard;
}

pub fn unsupported(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode == std.builtin.OptimizeMode.Debug) {
        std.debug.panic("UNSUPPORTED " ++ fmt, args);
    } else {
        std.log.scoped(.UNSUPPORTED).warn(fmt, args);
    }
}

comptime {
    _ = lib_vulkan;
}
