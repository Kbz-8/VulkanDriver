const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const PhiQueue = @import("PhiQueue.zig");
const PhiPhysicalDevice = @import("PhiPhysicalDevice.zig");
const PhiTransport = @import("PhiTransport.zig");

pub const PhiBinarySemaphore = @import("PhiBinarySemaphore.zig");
pub const PhiBuffer = @import("PhiBuffer.zig");
pub const PhiBufferView = @import("PhiBufferView.zig");
pub const PhiCommandBuffer = @import("PhiCommandBuffer.zig");
pub const PhiCommandPool = @import("PhiCommandPool.zig");
pub const PhiDescriptorPool = @import("PhiDescriptorPool.zig");
pub const PhiDescriptorSetLayout = @import("PhiDescriptorSetLayout.zig");
pub const PhiDeviceMemory = @import("PhiDeviceMemory.zig");
pub const PhiEvent = @import("PhiEvent.zig");
pub const PhiFence = @import("PhiFence.zig");
pub const PhiFramebuffer = @import("PhiFramebuffer.zig");
pub const PhiImage = @import("PhiImage.zig");
pub const PhiInstance = @import("PhiInstance.zig");
pub const PhiImageView = @import("PhiImageView.zig");
pub const PhiPipeline = @import("PhiPipeline.zig");
pub const PhiPipelineCache = @import("PhiPipelineCache.zig");
pub const PhiPipelineLayout = @import("PhiPipelineLayout.zig");
pub const PhiQueryPool = @import("PhiQueryPool.zig");
pub const PhiRenderPass = @import("PhiRenderPass.zig");
pub const PhiSampler = @import("PhiSampler.zig");
pub const PhiShaderModule = @import("PhiShaderModule.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Device;

interface: Interface,
transport: PhiTransport,

pub fn create(instance: *base.Instance, physical_device: *base.PhysicalDevice, allocator: std.mem.Allocator, info: *const vk.DeviceCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, instance, physical_device, info);

    interface.vtable = &.{
        .createQueue = PhiQueue.create,
        .destroyQueue = PhiQueue.destroy,
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

    const phi_physical_device: *PhiPhysicalDevice = @alignCast(@fieldParentPtr("interface", physical_device));
    const transport = try PhiTransport.init(phi_physical_device.scif_node_id);

    self.* = .{
        .interface = interface,
        .transport = transport,
    };

    try self.interface.createQueues(allocator, info);
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.transport.deinit();
    allocator.destroy(self);
}

pub fn allocateMemory(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.MemoryAllocateInfo) VkError!*base.DeviceMemory {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device_memory = try PhiDeviceMemory.create(self, allocator, info.allocation_size, info.memory_type_index);
    return &device_memory.interface;
}

pub fn createBuffer(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.BufferCreateInfo) VkError!*base.Buffer {
    const buffer = try PhiBuffer.create(interface, allocator, info);
    return &buffer.interface;
}

pub fn createDescriptorPool(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.DescriptorPoolCreateInfo) VkError!*base.DescriptorPool {
    const pool = try PhiDescriptorPool.create(interface, allocator, info);
    return &pool.interface;
}

pub fn createDescriptorSetLayout(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.DescriptorSetLayoutCreateInfo) VkError!*base.DescriptorSetLayout {
    const layout = try PhiDescriptorSetLayout.create(interface, allocator, info);
    return &layout.interface;
}

pub fn createFence(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.FenceCreateInfo) VkError!*base.Fence {
    const fence = try PhiFence.create(interface, allocator, info);
    return &fence.interface;
}

pub fn createCommandPool(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.CommandPoolCreateInfo) VkError!*base.CommandPool {
    const pool = try PhiCommandPool.create(interface, allocator, info);
    return &pool.interface;
}

pub fn createImage(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.ImageCreateInfo) VkError!*base.Image {
    const image = try PhiImage.create(interface, allocator, info);
    return &image.interface;
}

pub fn createImageView(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.ImageViewCreateInfo) VkError!*base.ImageView {
    const view = try PhiImageView.create(interface, allocator, info);
    return &view.interface;
}

pub fn createBufferView(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.BufferViewCreateInfo) VkError!*base.BufferView {
    const view = try PhiBufferView.create(interface, allocator, info);
    return &view.interface;
}

pub fn createComputePipeline(interface: *Interface, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.ComputePipelineCreateInfo) VkError!*base.Pipeline {
    const pipeline = try PhiPipeline.createCompute(interface, allocator, cache, info);
    return &pipeline.interface;
}

pub fn createEvent(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.EventCreateInfo) VkError!*base.Event {
    const event = try PhiEvent.create(interface, allocator, info);
    return &event.interface;
}

pub fn createFramebuffer(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.FramebufferCreateInfo) VkError!*base.Framebuffer {
    const framebuffer = try PhiFramebuffer.create(interface, allocator, info);
    return &framebuffer.interface;
}

pub fn createGraphicsPipeline(interface: *Interface, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.GraphicsPipelineCreateInfo) VkError!*base.Pipeline {
    const pipeline = try PhiPipeline.createGraphics(interface, allocator, cache, info);
    return &pipeline.interface;
}

pub fn createPipelineCache(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.PipelineCacheCreateInfo) VkError!*base.PipelineCache {
    const cache = try PhiPipelineCache.create(interface, allocator, info);
    return &cache.interface;
}

pub fn createPipelineLayout(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.PipelineLayoutCreateInfo) VkError!*base.PipelineLayout {
    const layout = try PhiPipelineLayout.create(interface, allocator, info);
    return &layout.interface;
}

pub fn createQueryPool(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.QueryPoolCreateInfo) VkError!*base.QueryPool {
    const pool = try PhiQueryPool.create(interface, allocator, info);
    return &pool.interface;
}

pub fn createRenderPass(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.RenderPassCreateInfo) VkError!*base.RenderPass {
    const pass = try PhiRenderPass.create(interface, allocator, info);
    return &pass.interface;
}

pub fn createSampler(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.SamplerCreateInfo) VkError!*base.Sampler {
    const sampler = try PhiSampler.create(interface, allocator, info);
    return &sampler.interface;
}

pub fn createSemaphore(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.SemaphoreCreateInfo) VkError!*base.BinarySemaphore {
    const semaphore = try PhiBinarySemaphore.create(interface, allocator, info);
    return &semaphore.interface;
}

pub fn createShaderModule(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.ShaderModuleCreateInfo) VkError!*base.ShaderModule {
    const module = try PhiShaderModule.create(interface, allocator, info);
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
