const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const builtin = @import("builtin");

const Debug = std.builtin.OptimizeMode.Debug;

const SoftQueue = @import("SoftQueue.zig");
const Blitter = @import("device/Blitter.zig");

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

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Device;

const SpawnError = std.Thread.SpawnError;

interface: Interface,
device_allocator: if (builtin.mode == Debug) std.heap.DebugAllocator(.{}) else std.heap.ThreadSafeAllocator,
workers: std.Thread.Pool,
blitter: Blitter,

pub fn create(physical_device: *base.PhysicalDevice, allocator: std.mem.Allocator, info: *const vk.DeviceCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, physical_device, info);

    interface.vtable = &.{
        .createQueue = SoftQueue.create,
        .destroyQueue = SoftQueue.destroy,
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
    };

    self.* = .{
        .interface = interface,
        .device_allocator = if (builtin.mode == Debug) .init else .{ .child_allocator = std.heap.c_allocator }, // TODO: better device allocator
        .workers = undefined,
        .blitter = .init,
    };

    self.workers.init(.{ .allocator = self.device_allocator.allocator() }) catch |err| return switch (err) {
        SpawnError.OutOfMemory, SpawnError.LockedMemoryLimitExceeded => VkError.OutOfDeviceMemory,
        else => VkError.Unknown,
    };

    try self.interface.createQueues(allocator, info);
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.workers.deinit();

    if (builtin.mode == Debug) {
        // All device memory allocations should've been freed by now
        if (!self.device_allocator.detectLeaks()) {
            std.log.scoped(.vkDestroyDevice).debug("No device memory leaks detected", .{});
        }
    }

    allocator.destroy(self);
}

pub fn allocateMemory(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.MemoryAllocateInfo) VkError!*base.DeviceMemory {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device_memory = try SoftDeviceMemory.create(self, allocator, info.allocation_size, info.memory_type_index);
    return &device_memory.interface;
}

pub fn createBuffer(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.BufferCreateInfo) VkError!*base.Buffer {
    const buffer = try SoftBuffer.create(interface, allocator, info);
    return &buffer.interface;
}

pub fn createDescriptorPool(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.DescriptorPoolCreateInfo) VkError!*base.DescriptorPool {
    const pool = try SoftDescriptorPool.create(interface, allocator, info);
    return &pool.interface;
}

pub fn createDescriptorSetLayout(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.DescriptorSetLayoutCreateInfo) VkError!*base.DescriptorSetLayout {
    const layout = try SoftDescriptorSetLayout.create(interface, allocator, info);
    return &layout.interface;
}

pub fn createFence(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.FenceCreateInfo) VkError!*base.Fence {
    const fence = try SoftFence.create(interface, allocator, info);
    return &fence.interface;
}

pub fn createCommandPool(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.CommandPoolCreateInfo) VkError!*base.CommandPool {
    const pool = try SoftCommandPool.create(interface, allocator, info);
    return &pool.interface;
}

pub fn createImage(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.ImageCreateInfo) VkError!*base.Image {
    const image = try SoftImage.create(interface, allocator, info);
    return &image.interface;
}

pub fn createImageView(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.ImageViewCreateInfo) VkError!*base.ImageView {
    const view = try SoftImageView.create(interface, allocator, info);
    return &view.interface;
}

pub fn createBufferView(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.BufferViewCreateInfo) VkError!*base.BufferView {
    const view = try SoftBufferView.create(interface, allocator, info);
    return &view.interface;
}

pub fn createComputePipeline(interface: *Interface, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.ComputePipelineCreateInfo) VkError!*base.Pipeline {
    const pipeline = try SoftPipeline.createCompute(interface, allocator, cache, info);
    return &pipeline.interface;
}

pub fn createEvent(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.EventCreateInfo) VkError!*base.Event {
    const event = try SoftEvent.create(interface, allocator, info);
    return &event.interface;
}

pub fn createFramebuffer(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.FramebufferCreateInfo) VkError!*base.Framebuffer {
    const framebuffer = try SoftFramebuffer.create(interface, allocator, info);
    return &framebuffer.interface;
}

pub fn createGraphicsPipeline(interface: *Interface, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.GraphicsPipelineCreateInfo) VkError!*base.Pipeline {
    const pipeline = try SoftPipeline.createGraphics(interface, allocator, cache, info);
    return &pipeline.interface;
}

pub fn createPipelineCache(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.PipelineCacheCreateInfo) VkError!*base.PipelineCache {
    const cache = try SoftPipelineCache.create(interface, allocator, info);
    return &cache.interface;
}

pub fn createPipelineLayout(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.PipelineLayoutCreateInfo) VkError!*base.PipelineLayout {
    const layout = try SoftPipelineLayout.create(interface, allocator, info);
    return &layout.interface;
}

pub fn createQueryPool(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.QueryPoolCreateInfo) VkError!*base.QueryPool {
    const pool = try SoftQueryPool.create(interface, allocator, info);
    return &pool.interface;
}

pub fn createRenderPass(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.RenderPassCreateInfo) VkError!*base.RenderPass {
    const pass = try SoftRenderPass.create(interface, allocator, info);
    return &pass.interface;
}

pub fn createSampler(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.SamplerCreateInfo) VkError!*base.Sampler {
    const sampler = try SoftSampler.create(interface, allocator, info);
    return &sampler.interface;
}

pub fn createSemaphore(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.SemaphoreCreateInfo) VkError!*base.BinarySemaphore {
    const semaphore = try SoftBinarySemaphore.create(interface, allocator, info);
    return &semaphore.interface;
}

pub fn createShaderModule(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.ShaderModuleCreateInfo) VkError!*base.ShaderModule {
    const module = try SoftShaderModule.create(interface, allocator, info);
    return &module.interface;
}
