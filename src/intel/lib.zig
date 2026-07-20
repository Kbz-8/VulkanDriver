const std = @import("std");
const vk = @import("vulkan");
pub const base = @import("base");

pub const c = @import("intel_c");
pub const config = base.config;

pub const FlintInstance = @import("FlintInstance.zig");
pub const FlintDevice = @import("FlintDevice.zig");
pub const FlintPhysicalDevice = @import("FlintPhysicalDevice.zig");
pub const FlintQueue = @import("FlintQueue.zig");
pub const kmd = @import("kmd.zig");

pub const FlintBinarySemaphore = @import("FlintBinarySemaphore.zig");
pub const FlintBuffer = @import("FlintBuffer.zig");
pub const FlintBufferView = @import("FlintBufferView.zig");
pub const FlintCommandBuffer = @import("FlintCommandBuffer.zig");
pub const FlintCommandPool = @import("FlintCommandPool.zig");
pub const FlintDescriptorPool = @import("FlintDescriptorPool.zig");
pub const FlintDescriptorSet = @import("FlintDescriptorSet.zig");
pub const FlintDescriptorSetLayout = @import("FlintDescriptorSetLayout.zig");
pub const FlintDeviceMemory = @import("FlintDeviceMemory.zig");
pub const FlintEvent = @import("FlintEvent.zig");
pub const FlintFence = @import("FlintFence.zig");
pub const FlintFramebuffer = @import("FlintFramebuffer.zig");
pub const FlintImage = @import("FlintImage.zig");
pub const FlintImageView = @import("FlintImageView.zig");
pub const FlintPipeline = @import("FlintPipeline.zig");
pub const FlintPipelineCache = @import("FlintPipelineCache.zig");
pub const FlintPipelineLayout = @import("FlintPipelineLayout.zig");
pub const FlintQueryPool = @import("FlintQueryPool.zig");
pub const FlintRenderPass = @import("FlintRenderPass.zig");
pub const FlintSampler = @import("FlintSampler.zig");
pub const FlintShaderModule = @import("FlintShaderModule.zig");

pub const Instance = FlintInstance;

pub const driver_name = "Flint";

pub const physical_device_default_name = "Unkown Intel device";

pub const intel_pci_vendor_id = 0x8086;

pub const vulkan_version = vk.makeApiVersion(
    0,
    config.flint_vulkan_version.major,
    config.flint_vulkan_version.minor,
    config.flint_vulkan_version.patch,
);

/// GEM buffer objects are page based
pub const image_memory_alignment = std.heap.page_size_max;

pub const KmdType = enum {
    invalid,
    i915,
    xe,
};

pub const std_options = base.std_options;

comptime {
    _ = base;
}

test {
    std.testing.refAllDecls(FlintBinarySemaphore);
    std.testing.refAllDecls(FlintBuffer);
    std.testing.refAllDecls(FlintBufferView);
    std.testing.refAllDecls(FlintCommandBuffer);
    std.testing.refAllDecls(FlintCommandPool);
    std.testing.refAllDecls(FlintDescriptorPool);
    std.testing.refAllDecls(FlintDescriptorSet);
    std.testing.refAllDecls(FlintDescriptorSetLayout);
    std.testing.refAllDecls(FlintDevice);
    std.testing.refAllDecls(FlintDeviceMemory);
    std.testing.refAllDecls(FlintEvent);
    std.testing.refAllDecls(FlintFence);
    std.testing.refAllDecls(FlintFramebuffer);
    std.testing.refAllDecls(FlintImage);
    std.testing.refAllDecls(FlintImageView);
    std.testing.refAllDecls(FlintInstance);
    std.testing.refAllDecls(FlintPhysicalDevice);
    std.testing.refAllDecls(FlintPipeline);
    std.testing.refAllDecls(FlintPipelineCache);
    std.testing.refAllDecls(FlintPipelineLayout);
    std.testing.refAllDecls(FlintQueryPool);
    std.testing.refAllDecls(FlintQueue);
    std.testing.refAllDecls(FlintRenderPass);
    std.testing.refAllDecls(FlintSampler);
    std.testing.refAllDecls(FlintShaderModule);
    std.testing.refAllDecls(kmd);
    std.testing.refAllDecls(base);
}
