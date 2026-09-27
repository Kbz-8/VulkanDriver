const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const PsvkQueue = @import("PsvkQueue.zig");
const PsvkBinarySemaphore = @import("PsvkBinarySemaphore.zig");
const PsvkBuffer = @import("PsvkBuffer.zig");
const PsvkBufferView = @import("PsvkBufferView.zig");
const PsvkCommandPool = @import("PsvkCommandPool.zig");
const PsvkDescriptorPool = @import("PsvkDescriptorPool.zig");
const PsvkDescriptorSetLayout = @import("PsvkDescriptorSetLayout.zig");
const PsvkDeviceMemory = @import("PsvkDeviceMemory.zig");
const PsvkEvent = @import("PsvkEvent.zig");
const PsvkFence = @import("PsvkFence.zig");
const PsvkFramebuffer = @import("PsvkFramebuffer.zig");
const PsvkImage = @import("PsvkImage.zig");
const PsvkImageView = @import("PsvkImageView.zig");
const PsvkPipeline = @import("PsvkPipeline.zig");
const PsvkPipelineCache = @import("PsvkPipelineCache.zig");
const PsvkPipelineLayout = @import("PsvkPipelineLayout.zig");
const PsvkQueryPool = @import("PsvkQueryPool.zig");
const PsvkRenderPass = @import("PsvkRenderPass.zig");
const PsvkSampler = @import("PsvkSampler.zig");
const PsvkShaderModule = @import("PsvkShaderModule.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Device;

interface: Interface,

pub fn create(instance: *base.Instance, physical_device: *base.PhysicalDevice, allocator: std.mem.Allocator, info: *const vk.DeviceCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, instance, physical_device, info);

    interface.vtable = &.{
        .createQueue = PsvkQueue.create,
        .destroyQueue = PsvkQueue.destroy,
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
    return &(try PsvkDeviceMemory.create(@as(*Self, @alignCast(@fieldParentPtr("interface", interface))), allocator, info.allocation_size, info.memory_type_index)).interface;
}

pub fn createBuffer(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.BufferCreateInfo) VkError!*base.Buffer {
    return &(try PsvkBuffer.create(interface, allocator, info)).interface;
}

pub fn createBufferView(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.BufferViewCreateInfo) VkError!*base.BufferView {
    return &(try PsvkBufferView.create(interface, allocator, info)).interface;
}

pub fn createCommandPool(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.CommandPoolCreateInfo) VkError!*base.CommandPool {
    return &(try PsvkCommandPool.create(interface, allocator, info)).interface;
}

pub fn createComputePipeline(interface: *Interface, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.ComputePipelineCreateInfo) VkError!*base.Pipeline {
    return &(try PsvkPipeline.createCompute(interface, allocator, cache, info)).interface;
}

pub fn createDescriptorPool(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.DescriptorPoolCreateInfo) VkError!*base.DescriptorPool {
    return &(try PsvkDescriptorPool.create(interface, allocator, info)).interface;
}

pub fn createDescriptorSetLayout(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.DescriptorSetLayoutCreateInfo) VkError!*base.DescriptorSetLayout {
    return &(try PsvkDescriptorSetLayout.create(interface, allocator, info)).interface;
}

pub fn createEvent(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.EventCreateInfo) VkError!*base.Event {
    return &(try PsvkEvent.create(interface, allocator, info)).interface;
}

pub fn createFence(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.FenceCreateInfo) VkError!*base.Fence {
    return &(try PsvkFence.create(interface, allocator, info)).interface;
}

pub fn createFramebuffer(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.FramebufferCreateInfo) VkError!*base.Framebuffer {
    return &(try PsvkFramebuffer.create(interface, allocator, info)).interface;
}

pub fn createGraphicsPipeline(interface: *Interface, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.GraphicsPipelineCreateInfo) VkError!*base.Pipeline {
    return &(try PsvkPipeline.createGraphics(interface, allocator, cache, info)).interface;
}

pub fn createImage(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.ImageCreateInfo) VkError!*base.Image {
    return &(try PsvkImage.create(interface, allocator, info)).interface;
}

pub fn createImageView(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.ImageViewCreateInfo) VkError!*base.ImageView {
    return &(try PsvkImageView.create(interface, allocator, info)).interface;
}

pub fn createPipelineCache(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.PipelineCacheCreateInfo) VkError!*base.PipelineCache {
    return &(try PsvkPipelineCache.create(interface, allocator, info)).interface;
}

pub fn createPipelineLayout(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.PipelineLayoutCreateInfo) VkError!*base.PipelineLayout {
    return &(try PsvkPipelineLayout.create(interface, allocator, info)).interface;
}

pub fn createQueryPool(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.QueryPoolCreateInfo) VkError!*base.QueryPool {
    return &(try PsvkQueryPool.create(interface, allocator, info)).interface;
}

pub fn createRenderPass(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.RenderPassCreateInfo) VkError!*base.RenderPass {
    return &(try PsvkRenderPass.create(interface, allocator, info)).interface;
}

pub fn createSampler(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.SamplerCreateInfo) VkError!*base.Sampler {
    return &(try PsvkSampler.create(interface, allocator, info)).interface;
}

pub fn createSemaphore(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.SemaphoreCreateInfo) VkError!*base.BinarySemaphore {
    return &(try PsvkBinarySemaphore.create(interface, allocator, info)).interface;
}

pub fn createShaderModule(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.ShaderModuleCreateInfo) VkError!*base.ShaderModule {
    return &(try PsvkShaderModule.create(interface, allocator, info)).interface;
}

pub fn getDeviceGroupPeerMemoryFeatures(_: *Interface, _: u32, _: u32, _: u32) VkError!vk.PeerMemoryFeatureFlags {
    return .{};
}

pub fn getDeviceGroupPresentCapabilitiesKHR(_: *Interface, capabilities: *vk.DeviceGroupPresentCapabilitiesKHR) VkError!void {
    capabilities.present_mask = @splat(0);
    capabilities.modes = .{};
}

pub fn getDeviceGroupSurfacePresentModesKHR(_: *Interface, _: *base.SurfaceKHR) VkError!vk.DeviceGroupPresentModeFlagsKHR {
    return .{};
}
