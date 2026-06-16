const std = @import("std");
const vk = @import("vulkan");
pub const base = @import("base");

pub const c = @import("intel_c");
pub const config = base.config;

pub const IntelInstance = @import("IntelInstance.zig");
pub const IntelDevice = @import("IntelDevice.zig");
pub const IntelPhysicalDevice = @import("IntelPhysicalDevice.zig");
pub const IntelQueue = @import("IntelQueue.zig");

pub const IntelBinarySemaphore = @import("IntelBinarySemaphore.zig");
pub const IntelBuffer = @import("IntelBuffer.zig");
pub const IntelBufferView = @import("IntelBufferView.zig");
pub const IntelCommandBuffer = @import("IntelCommandBuffer.zig");
pub const IntelCommandPool = @import("IntelCommandPool.zig");
pub const IntelDescriptorPool = @import("IntelDescriptorPool.zig");
pub const IntelDescriptorSet = @import("IntelDescriptorSet.zig");
pub const IntelDescriptorSetLayout = @import("IntelDescriptorSetLayout.zig");
pub const IntelDeviceMemory = @import("IntelDeviceMemory.zig");
pub const IntelEvent = @import("IntelEvent.zig");
pub const IntelFence = @import("IntelFence.zig");
pub const IntelFramebuffer = @import("IntelFramebuffer.zig");
pub const IntelImage = @import("IntelImage.zig");
pub const IntelImageView = @import("IntelImageView.zig");
pub const IntelPipeline = @import("IntelPipeline.zig");
pub const IntelPipelineCache = @import("IntelPipelineCache.zig");
pub const IntelPipelineLayout = @import("IntelPipelineLayout.zig");
pub const IntelQueryPool = @import("IntelQueryPool.zig");
pub const IntelRenderPass = @import("IntelRenderPass.zig");
pub const IntelSampler = @import("IntelSampler.zig");
pub const IntelShaderModule = @import("IntelShaderModule.zig");

pub const Instance = IntelInstance;

pub const DRIVER_NAME = "Intel";

pub const VULKAN_VERSION = vk.makeApiVersion(
    0,
    config.intel_vulkan_version.major,
    config.intel_vulkan_version.minor,
    config.intel_vulkan_version.patch,
);

pub const DEVICE_ID = 0x00000000;
pub const PIPELINE_CACHE_UUID: [vk.UUID_SIZE]u8 = "ApeIntelCacheUUI".*;

pub const PHYSICAL_DEVICE_DEFAULT_NAME = "Ape Intel device";

pub const std_options = base.std_options;

comptime {
    _ = base;
}

test {
    std.testing.refAllDecls(IntelBinarySemaphore);
    std.testing.refAllDecls(IntelBuffer);
    std.testing.refAllDecls(IntelBufferView);
    std.testing.refAllDecls(IntelCommandBuffer);
    std.testing.refAllDecls(IntelCommandPool);
    std.testing.refAllDecls(IntelDescriptorPool);
    std.testing.refAllDecls(IntelDescriptorSet);
    std.testing.refAllDecls(IntelDescriptorSetLayout);
    std.testing.refAllDecls(IntelDevice);
    std.testing.refAllDecls(IntelDeviceMemory);
    std.testing.refAllDecls(IntelEvent);
    std.testing.refAllDecls(IntelFence);
    std.testing.refAllDecls(IntelFramebuffer);
    std.testing.refAllDecls(IntelImage);
    std.testing.refAllDecls(IntelImageView);
    std.testing.refAllDecls(IntelInstance);
    std.testing.refAllDecls(IntelPhysicalDevice);
    std.testing.refAllDecls(IntelPipeline);
    std.testing.refAllDecls(IntelPipelineCache);
    std.testing.refAllDecls(IntelPipelineLayout);
    std.testing.refAllDecls(IntelQueryPool);
    std.testing.refAllDecls(IntelQueue);
    std.testing.refAllDecls(IntelRenderPass);
    std.testing.refAllDecls(IntelSampler);
    std.testing.refAllDecls(IntelShaderModule);
    std.testing.refAllDecls(base);
}
