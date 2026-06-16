const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const FlintQueue = @import("FlintQueue.zig");

pub const FlintBinarySemaphore = @import("FlintBinarySemaphore.zig");
pub const FlintBuffer = @import("FlintBuffer.zig");
pub const FlintBufferView = @import("FlintBufferView.zig");
pub const FlintCommandBuffer = @import("FlintCommandBuffer.zig");
pub const FlintCommandPool = @import("FlintCommandPool.zig");
pub const FlintDescriptorPool = @import("FlintDescriptorPool.zig");
pub const FlintDescriptorSetLayout = @import("FlintDescriptorSetLayout.zig");
pub const FlintDeviceMemory = @import("FlintDeviceMemory.zig");
pub const FlintEvent = @import("FlintEvent.zig");
pub const FlintFence = @import("FlintFence.zig");
pub const FlintFramebuffer = @import("FlintFramebuffer.zig");
pub const FlintImage = @import("FlintImage.zig");
pub const FlintInstance = @import("FlintInstance.zig");
pub const FlintImageView = @import("FlintImageView.zig");
pub const FlintPipeline = @import("FlintPipeline.zig");
pub const FlintPipelineCache = @import("FlintPipelineCache.zig");
pub const FlintPipelineLayout = @import("FlintPipelineLayout.zig");
pub const FlintQueryPool = @import("FlintQueryPool.zig");
pub const FlintRenderPass = @import("FlintRenderPass.zig");
pub const FlintSampler = @import("FlintSampler.zig");
pub const FlintShaderModule = @import("FlintShaderModule.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Device;

interface: Interface,

pub fn create(instance: *base.Instance, physical_device: *base.PhysicalDevice, allocator: std.mem.Allocator, info: *const vk.DeviceCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, instance, physical_device, info);

    interface.vtable = &.{
        .createQueue = FlintQueue.create,
        .destroyQueue = FlintQueue.destroy,
    };

    interface.dispatch_table = &.{
        .allocateMemory = allocateMemory,
        .createBuffer = createBuffer,
        .createBufferView = createBufferView,
        .createCommandPool = createCommandPool,
        .createComputePipeline = createComputePipeline,
        .createDescriptorPool = createDescriptorPool,
        .createDescriptorSetLayout = createDescriptorSetLayout,
        .createEvent = createEvent,
        .createFence = createFence,
        .createFramebuffer = createFramebuffer,
        .createGraphicsPipeline = createGraphicsPipeline,
        .createImage = createImage,
        .createImageView = createImageView,
        .createPipelineCache = createPipelineCache,
        .createPipelineLayout = createPipelineLayout,
        .createQueryPool = createQueryPool,
        .createRenderPass = createRenderPass,
        .createSampler = createSampler,
        .createSemaphore = createSemaphore,
        .createShaderModule = createShaderModule,
        .destroy = destroy,
        .getDeviceGroupPeerMemoryFeatures = getDeviceGroupPeerMemoryFeatures,
        .getDeviceGroupPresentCapabilitiesKHR = getDeviceGroupPresentCapabilitiesKHR,
        .getDeviceGroupSurfacePresentModesKHR = getDeviceGroupSurfacePresentModesKHR,
    };

    self.* = .{
        .interface = interface,
    };

    try self.interface.createQueues(allocator, info);
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn allocateMemory(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.MemoryAllocateInfo) VkError!*base.DeviceMemory {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device_memory = try FlintDeviceMemory.create(self, allocator, info.allocation_size, info.memory_type_index);
    return &device_memory.interface;
}

pub fn createBuffer(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.BufferCreateInfo) VkError!*base.Buffer {
    const buffer = try FlintBuffer.create(interface, allocator, info);
    return &buffer.interface;
}

pub fn createDescriptorPool(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.DescriptorPoolCreateInfo) VkError!*base.DescriptorPool {
    const pool = try FlintDescriptorPool.create(interface, allocator, info);
    return &pool.interface;
}

pub fn createDescriptorSetLayout(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.DescriptorSetLayoutCreateInfo) VkError!*base.DescriptorSetLayout {
    const layout = try FlintDescriptorSetLayout.create(interface, allocator, info);
    return &layout.interface;
}

pub fn createFence(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.FenceCreateInfo) VkError!*base.Fence {
    const fence = try FlintFence.create(interface, allocator, info);
    return &fence.interface;
}

pub fn createCommandPool(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.CommandPoolCreateInfo) VkError!*base.CommandPool {
    const pool = try FlintCommandPool.create(interface, allocator, info);
    return &pool.interface;
}

pub fn createImage(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.ImageCreateInfo) VkError!*base.Image {
    const image = try FlintImage.create(interface, allocator, info);
    return &image.interface;
}

pub fn createImageView(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.ImageViewCreateInfo) VkError!*base.ImageView {
    const view = try FlintImageView.create(interface, allocator, info);
    return &view.interface;
}

pub fn createBufferView(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.BufferViewCreateInfo) VkError!*base.BufferView {
    const view = try FlintBufferView.create(interface, allocator, info);
    return &view.interface;
}

pub fn createComputePipeline(interface: *Interface, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.ComputePipelineCreateInfo) VkError!*base.Pipeline {
    const pipeline = try FlintPipeline.createCompute(interface, allocator, cache, info);
    return &pipeline.interface;
}

pub fn createEvent(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.EventCreateInfo) VkError!*base.Event {
    const event = try FlintEvent.create(interface, allocator, info);
    return &event.interface;
}

pub fn createFramebuffer(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.FramebufferCreateInfo) VkError!*base.Framebuffer {
    const framebuffer = try FlintFramebuffer.create(interface, allocator, info);
    return &framebuffer.interface;
}

pub fn createGraphicsPipeline(interface: *Interface, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.GraphicsPipelineCreateInfo) VkError!*base.Pipeline {
    const pipeline = try FlintPipeline.createGraphics(interface, allocator, cache, info);
    return &pipeline.interface;
}

pub fn createPipelineCache(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.PipelineCacheCreateInfo) VkError!*base.PipelineCache {
    const cache = try FlintPipelineCache.create(interface, allocator, info);
    return &cache.interface;
}

pub fn createPipelineLayout(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.PipelineLayoutCreateInfo) VkError!*base.PipelineLayout {
    const layout = try FlintPipelineLayout.create(interface, allocator, info);
    return &layout.interface;
}

pub fn createQueryPool(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.QueryPoolCreateInfo) VkError!*base.QueryPool {
    const pool = try FlintQueryPool.create(interface, allocator, info);
    return &pool.interface;
}

pub fn createRenderPass(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.RenderPassCreateInfo) VkError!*base.RenderPass {
    const pass = try FlintRenderPass.create(interface, allocator, info);
    return &pass.interface;
}

pub fn createSampler(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.SamplerCreateInfo) VkError!*base.Sampler {
    const sampler = try FlintSampler.create(interface, allocator, info);
    return &sampler.interface;
}

pub fn createSemaphore(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.SemaphoreCreateInfo) VkError!*base.BinarySemaphore {
    const semaphore = try FlintBinarySemaphore.create(interface, allocator, info);
    return &semaphore.interface;
}

pub fn createShaderModule(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.ShaderModuleCreateInfo) VkError!*base.ShaderModule {
    const module = try FlintShaderModule.create(interface, allocator, info);
    return &module.interface;
}

pub fn getDeviceGroupPeerMemoryFeatures(interface: *Interface, heap_index: u32, local_device_index: u32, remote_device_index: u32) VkError!vk.PeerMemoryFeatureFlags {
    if (heap_index >= interface.physical_device.mem_props.memory_heap_count) return VkError.ValidationFailed;
    if (local_device_index != 0 or remote_device_index != 0) return VkError.ValidationFailed;

    return .{
        .copy_src_bit = true,
        .copy_dst_bit = true,
        .generic_src_bit = true,
        .generic_dst_bit = true,
    };
}

pub fn getDeviceGroupPresentCapabilitiesKHR(_: *Interface, capabilities: *vk.DeviceGroupPresentCapabilitiesKHR) VkError!void {
    capabilities.present_mask = @splat(0);
    capabilities.present_mask[0] = 1;
    capabilities.modes = .{ .local_bit_khr = true };
}

pub fn getDeviceGroupSurfacePresentModesKHR(_: *Interface, _: *base.SurfaceKHR) VkError!vk.DeviceGroupPresentModeFlagsKHR {
    return .{ .local_bit_khr = true };
}
