const std = @import("std");
const vk = @import("vulkan");
pub const base = @import("base");

pub const c = @import("phi_c");
pub const proto = @import("phi_protocol_c");
pub const config = base.config;
pub const mic = @import("miclib");
pub const scif = @import("scif.zig");

pub const PhiInstance = @import("PhiInstance.zig");
pub const PhiDevice = @import("PhiDevice.zig");
pub const PhiPhysicalDevice = @import("PhiPhysicalDevice.zig");
pub const PhiQueue = @import("PhiQueue.zig");
pub const PhiTransport = @import("PhiTransport.zig");

pub const PhiBinarySemaphore = @import("PhiBinarySemaphore.zig");
pub const PhiBuffer = @import("PhiBuffer.zig");
pub const PhiBufferView = @import("PhiBufferView.zig");
pub const PhiCommandBuffer = @import("PhiCommandBuffer.zig");
pub const PhiCommandPool = @import("PhiCommandPool.zig");
pub const PhiDescriptorPool = @import("PhiDescriptorPool.zig");
pub const PhiDescriptorSet = @import("PhiDescriptorSet.zig");
pub const PhiDescriptorSetLayout = @import("PhiDescriptorSetLayout.zig");
pub const PhiDeviceMemory = @import("PhiDeviceMemory.zig");
pub const PhiEvent = @import("PhiEvent.zig");
pub const PhiFence = @import("PhiFence.zig");
pub const PhiFramebuffer = @import("PhiFramebuffer.zig");
pub const PhiImage = @import("PhiImage.zig");
pub const PhiImageView = @import("PhiImageView.zig");
pub const PhiPipeline = @import("PhiPipeline.zig");
pub const PhiPipelineCache = @import("PhiPipelineCache.zig");
pub const PhiPipelineLayout = @import("PhiPipelineLayout.zig");
pub const PhiQueryPool = @import("PhiQueryPool.zig");
pub const PhiRenderPass = @import("PhiRenderPass.zig");
pub const PhiSampler = @import("PhiSampler.zig");
pub const PhiShaderModule = @import("PhiShaderModule.zig");

pub const Instance = PhiInstance;

pub const driver_name = "Phi";

pub const physical_device_default_name = "Intel(R) Xeon Phi(TM) Coprocessor";

pub const vulkan_version = vk.makeApiVersion(
    0,
    config.phi_vulkan_version.major,
    config.phi_vulkan_version.minor,
    config.phi_vulkan_version.patch,
);

pub const std_options = base.std_options;

comptime {
    _ = base;
}

test {
    std.testing.refAllDecls(PhiBinarySemaphore);
    std.testing.refAllDecls(PhiBuffer);
    std.testing.refAllDecls(PhiBufferView);
    std.testing.refAllDecls(PhiCommandBuffer);
    std.testing.refAllDecls(PhiCommandPool);
    std.testing.refAllDecls(PhiDescriptorPool);
    std.testing.refAllDecls(PhiDescriptorSet);
    std.testing.refAllDecls(PhiDescriptorSetLayout);
    std.testing.refAllDecls(PhiDevice);
    std.testing.refAllDecls(PhiDeviceMemory);
    std.testing.refAllDecls(PhiEvent);
    std.testing.refAllDecls(PhiFence);
    std.testing.refAllDecls(PhiFramebuffer);
    std.testing.refAllDecls(PhiImage);
    std.testing.refAllDecls(PhiImageView);
    std.testing.refAllDecls(PhiInstance);
    std.testing.refAllDecls(PhiPhysicalDevice);
    std.testing.refAllDecls(PhiTransport);
    std.testing.refAllDecls(scif);
    std.testing.refAllDecls(PhiPipeline);
    std.testing.refAllDecls(PhiPipelineCache);
    std.testing.refAllDecls(PhiPipelineLayout);
    std.testing.refAllDecls(PhiQueryPool);
    std.testing.refAllDecls(PhiQueue);
    std.testing.refAllDecls(PhiRenderPass);
    std.testing.refAllDecls(PhiSampler);
    std.testing.refAllDecls(PhiShaderModule);
    std.testing.refAllDecls(base);
}
