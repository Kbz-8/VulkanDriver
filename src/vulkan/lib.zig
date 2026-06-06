//! Here lies the documentation of the common internal API that backends need to implement

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
pub const c = @import("base_c");

pub const zm = @import("zmath");

pub const errors = @import("error_set.zig");
pub const lib_vulkan = @import("lib_vulkan.zig");
pub const logger = @import("logger.zig");
pub const format = @import("format.zig");
pub const config = @import("config");
pub const utils = @import("utils.zig");

pub const Dispatchable = @import("Dispatchable.zig").Dispatchable;
pub const fallback_host_allocator = @import("fallback_host_allocator.zig").fallback_host_allocator;
pub const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;
pub const VkError = errors.VkError;
pub const VulkanAllocator = @import("VulkanAllocator.zig");
pub const RefCounter = @import("RefCounter.zig");
pub const SpinMutex = @import("SpinMutex.zig");

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

pub const SurfaceKHR = @import("wsi/SurfaceKHR.zig");
pub const SwapchainKHR = @import("wsi/SwapchainKHR.zig");

pub const VULKAN_VENDOR_ID = 0x10008;

/// Default driver name
pub const DRIVER_NAME = "Unnamed Ape Driver";
/// Default Vulkan version
pub const VULKAN_VERSION = vk.makeApiVersion(0, 1, 0, 0);

/// Maximum number of descriptor sets per pipeline
pub const VULKAN_MAX_DESCRIPTOR_SETS = 8;

/// The number of push constant ranges is effectively bounded
/// by the number of possible shader stages. Not the number of stages that can
/// be compiled together (a pipeline layout can be used in multiple pipelnes
/// wth different sets of shaders) but the total number of stage bits supported
/// by the implementation. Currently, those are
/// - VK_SHADER_STAGE_VERTEX_BIT
/// - VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT
/// - VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT
/// - VK_SHADER_STAGE_GEOMETRY_BIT
/// - VK_SHADER_STAGE_FRAGMENT_BIT
/// - VK_SHADER_STAGE_COMPUTE_BIT
pub const VULKAN_MAX_PUSH_CONSTANT_RANGES = 6;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logger.log,
};

pub inline fn unsupported(comptime fmt: []const u8, args: anytype) void {
    std.log.scoped(.UNSUPPORTED).warn(fmt, args);
}

comptime {
    _ = lib_vulkan;
}
