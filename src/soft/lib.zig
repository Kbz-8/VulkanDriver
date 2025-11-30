const std = @import("std");
const vk = @import("vulkan");
pub const base = @import("base");

pub const Executor = @import("Executor.zig");

pub const SoftInstance = @import("SoftInstance.zig");
pub const SoftDevice = @import("SoftDevice.zig");
pub const SoftPhysicalDevice = @import("SoftPhysicalDevice.zig");
pub const SoftQueue = @import("SoftQueue.zig");

pub const SoftBinarySemaphore = @import("SoftBinarySemaphore.zig");
pub const SoftBuffer = @import("SoftBuffer.zig");
pub const SoftBufferView = @import("SoftBufferView.zig");
pub const SoftCommandBuffer = @import("SoftCommandBuffer.zig");
pub const SoftCommandPool = @import("SoftCommandPool.zig");
pub const SoftDescriptorPool = @import("SoftDescriptorPool.zig");
pub const SoftDescriptorSetLayout = @import("SoftDescriptorSetLayout.zig");
pub const SoftDeviceMemory = @import("SoftDeviceMemory.zig");
pub const SoftEvent = @import("SoftEvent.zig");
pub const SoftFence = @import("SoftFence.zig");
pub const SoftFramebuffer = @import("SoftFramebuffer.zig");
pub const SoftImage = @import("SoftImage.zig");
pub const SoftImageView = @import("SoftImageView.zig");
pub const SoftPipeline = @import("SoftPipeline.zig");
pub const SoftPipelineCache = @import("SoftPipelineCache.zig");
pub const SoftPipelineLayout = @import("SoftPipelineLayout.zig");
pub const SoftQueryPool = @import("SoftQueryPool.zig");
pub const SoftRenderPass = @import("SoftRenderPass.zig");
pub const SoftSampler = @import("SoftSampler.zig");
pub const SoftShaderModule = @import("SoftShaderModule.zig");

pub const Instance = SoftInstance;

pub const DRIVER_LOGS_ENV_NAME = base.DRIVER_LOGS_ENV_NAME;
pub const DRIVER_NAME = "Soft";

pub const VULKAN_VERSION = vk.makeApiVersion(0, 1, 0, 0);
pub const DRIVER_VERSION = vk.makeApiVersion(0, 0, 0, 1);
pub const DEVICE_ID = 0x600DCAFE;

/// Generic system memory.
pub const MEMORY_TYPE_GENERIC_BIT = 0;

/// 16 bytes for 128-bit vector types.
pub const MEMORY_REQUIREMENTS_BUFFER_ALIGNMENT = 16;

pub const MEMORY_REQUIREMENTS_IMAGE_ALIGNMENT = 256;

/// Vulkan 1.2 requires buffer offset alignment to be at most 256.
pub const MIN_TEXEL_BUFFER_ALIGNMENT = 256;
/// Vulkan 1.2 requires buffer offset alignment to be at most 256.
pub const MIN_UNIFORM_BUFFER_ALIGNMENT = 256;
/// Vulkan 1.2 requires buffer offset alignment to be at most 256.
pub const MIN_STORAGE_BUFFER_ALIGNMENT = 256;

pub const std_options = base.std_options;

comptime {
    _ = base;
}

test {
    std.testing.refAllDecls(Executor);
    std.testing.refAllDecls(SoftBinarySemaphore);
    std.testing.refAllDecls(SoftBuffer);
    std.testing.refAllDecls(SoftBufferView);
    std.testing.refAllDecls(SoftCommandBuffer);
    std.testing.refAllDecls(SoftCommandPool);
    std.testing.refAllDecls(SoftDescriptorPool);
    std.testing.refAllDecls(SoftDescriptorSetLayout);
    std.testing.refAllDecls(SoftDevice);
    std.testing.refAllDecls(SoftDeviceMemory);
    std.testing.refAllDecls(SoftEvent);
    std.testing.refAllDecls(SoftFence);
    std.testing.refAllDecls(SoftFramebuffer);
    std.testing.refAllDecls(SoftImage);
    std.testing.refAllDecls(SoftImageView);
    std.testing.refAllDecls(SoftInstance);
    std.testing.refAllDecls(SoftPhysicalDevice);
    std.testing.refAllDecls(SoftPipeline);
    std.testing.refAllDecls(SoftPipelineCache);
    std.testing.refAllDecls(SoftPipelineLayout);
    std.testing.refAllDecls(SoftQueryPool);
    std.testing.refAllDecls(SoftQueue);
    std.testing.refAllDecls(SoftRenderPass);
    std.testing.refAllDecls(SoftSampler);
    std.testing.refAllDecls(SoftShaderModule);
    std.testing.refAllDecls(base);
}
