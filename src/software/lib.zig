const std = @import("std");
const vk = @import("vulkan");
pub const base = @import("base");

pub const c = @import("soft_c");
pub const config = base.config;

pub const Device = @import("device/Device.zig");

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
pub const SoftDescriptorSet = @import("SoftDescriptorSet.zig");
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

pub const driver_name = "Soft";

pub const vulkan_version = vk.makeApiVersion(
    0,
    config.soft_vulkan_version.major,
    config.soft_vulkan_version.minor,
    config.soft_vulkan_version.patch,
);
pub const device_id = 0x600DCAFE;
pub const pipeline_cache_uuid: [vk.UUID_SIZE]u8 = "ApeSoftCacheUUID".*;

/// Generic system memory.
pub const memory_type_generic_bit = 0;

/// 16 bytes for 128-bit vector types.
pub const memory_requirements_buffer_alignment = 16;

pub const memory_requirements_image_alignment = 256;

/// Vulkan 1.2 requires buffer offset alignment to be at most 256.
pub const min_texel_buffer_alignment = 256;
/// Vulkan 1.2 requires buffer offset alignment to be at most 256.
pub const min_uniform_buffer_alignment = 256;
/// Vulkan 1.2 requires buffer offset alignment to be at most 256.
pub const min_storage_buffer_alignment = 256;

pub const max_vertex_input_bindings = 16;
pub const max_vertex_input_attributes = 16;

pub const push_constant_size = 128;

pub const max_image_levels_1d = 15;
pub const max_image_levels_2d = 15;
pub const max_image_levels_3d = 12;
pub const max_image_levels_cube = 15;
pub const max_image_array_layers = 2048;

pub const physical_device_default_name = "Ape software device";
pub const physical_device_fallback_heap_size = 0x10000000; // 256MB

pub const std_options = base.std_options;

comptime {
    _ = base;
}

test {
    std.testing.refAllDecls(Device);
    std.testing.refAllDecls(SoftBinarySemaphore);
    std.testing.refAllDecls(SoftBuffer);
    std.testing.refAllDecls(SoftBufferView);
    std.testing.refAllDecls(SoftCommandBuffer);
    std.testing.refAllDecls(SoftCommandPool);
    std.testing.refAllDecls(SoftDescriptorPool);
    std.testing.refAllDecls(SoftDescriptorSet);
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
