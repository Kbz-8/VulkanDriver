const std = @import("std");
const vk = @import("vulkan");
pub const base = @import("base");

pub const config = base.config;

pub const PsvkBinarySemaphore = @import("PsvkBinarySemaphore.zig");
pub const PsvkBuffer = @import("PsvkBuffer.zig");
pub const PsvkBufferView = @import("PsvkBufferView.zig");
pub const PsvkCommandBuffer = @import("PsvkCommandBuffer.zig");
pub const PsvkCommandPool = @import("PsvkCommandPool.zig");
pub const PsvkDescriptorPool = @import("PsvkDescriptorPool.zig");
pub const PsvkDescriptorSet = @import("PsvkDescriptorSet.zig");
pub const PsvkDescriptorSetLayout = @import("PsvkDescriptorSetLayout.zig");
pub const PsvkDevice = @import("PsvkDevice.zig");
pub const PsvkDeviceMemory = @import("PsvkDeviceMemory.zig");
pub const PsvkEvent = @import("PsvkEvent.zig");
pub const PsvkFence = @import("PsvkFence.zig");
pub const PsvkFramebuffer = @import("PsvkFramebuffer.zig");
pub const PsvkImage = @import("PsvkImage.zig");
pub const PsvkImageView = @import("PsvkImageView.zig");
pub const PsvkInstance = @import("PsvkInstance.zig");
pub const PsvkPhysicalDevice = @import("PsvkPhysicalDevice.zig");
pub const PsvkPipeline = @import("PsvkPipeline.zig");
pub const PsvkPipelineCache = @import("PsvkPipelineCache.zig");
pub const PsvkPipelineLayout = @import("PsvkPipelineLayout.zig");
pub const PsvkQueryPool = @import("PsvkQueryPool.zig");
pub const PsvkQueue = @import("PsvkQueue.zig");
pub const PsvkRenderPass = @import("PsvkRenderPass.zig");
pub const PsvkSampler = @import("PsvkSampler.zig");
pub const PsvkShaderModule = @import("PsvkShaderModule.zig");

pub const Instance = PsvkInstance;

pub const driver_name = "Psvk";

pub const vulkan_version = vk.makeApiVersion(
    0,
    config.psvk_vulkan_version.major,
    config.psvk_vulkan_version.minor,
    config.psvk_vulkan_version.patch,
);

pub const std_options: std.Options = .{
    .log_level = base.std_options.log_level,
    .logFn = base.std_options.logFn,
    .page_size_min = 4096,
    .page_size_max = 4096,
};

comptime {
    _ = base;
}

test {
    std.testing.refAllDecls(PsvkBinarySemaphore);
    std.testing.refAllDecls(PsvkBuffer);
    std.testing.refAllDecls(PsvkBufferView);
    std.testing.refAllDecls(PsvkCommandBuffer);
    std.testing.refAllDecls(PsvkCommandPool);
    std.testing.refAllDecls(PsvkDescriptorPool);
    std.testing.refAllDecls(PsvkDescriptorSet);
    std.testing.refAllDecls(PsvkDescriptorSetLayout);
    std.testing.refAllDecls(PsvkDevice);
    std.testing.refAllDecls(PsvkDeviceMemory);
    std.testing.refAllDecls(PsvkEvent);
    std.testing.refAllDecls(PsvkFence);
    std.testing.refAllDecls(PsvkFramebuffer);
    std.testing.refAllDecls(PsvkImage);
    std.testing.refAllDecls(PsvkImageView);
    std.testing.refAllDecls(PsvkInstance);
    std.testing.refAllDecls(PsvkPhysicalDevice);
    std.testing.refAllDecls(PsvkPipeline);
    std.testing.refAllDecls(PsvkPipelineCache);
    std.testing.refAllDecls(PsvkPipelineLayout);
    std.testing.refAllDecls(PsvkQueryPool);
    std.testing.refAllDecls(PsvkQueue);
    std.testing.refAllDecls(PsvkRenderPass);
    std.testing.refAllDecls(PsvkSampler);
    std.testing.refAllDecls(PsvkShaderModule);
    std.testing.refAllDecls(base);
}
