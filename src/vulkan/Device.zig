const std = @import("std");
const vk = @import("vulkan");

const logger = @import("lib.zig").logger;

const Dispatchable = @import("Dispatchable.zig").Dispatchable;
const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;
const VulkanAllocator = @import("VulkanAllocator.zig");
const VkError = @import("error_set.zig").VkError;

const PhysicalDevice = @import("PhysicalDevice.zig");
const Queue = @import("Queue.zig");

const BinarySemaphore = @import("BinarySemaphore.zig");
const Buffer = @import("Buffer.zig");
const BufferView = @import("BufferView.zig");
const CommandPool = @import("CommandPool.zig");
const DescriptorPool = @import("DescriptorPool.zig");
const DescriptorSet = @import("DescriptorSet.zig");
const DescriptorSetLayout = @import("DescriptorSetLayout.zig");
const DeviceMemory = @import("DeviceMemory.zig");
const Event = @import("Event.zig");
const Fence = @import("Fence.zig");
const Framebuffer = @import("Framebuffer.zig");
const Image = @import("Image.zig");
const ImageView = @import("ImageView.zig");
const Pipeline = @import("Pipeline.zig");
const PipelineCache = @import("PipelineCache.zig");
const PipelineLayout = @import("PipelineLayout.zig");
const QueryPool = @import("QueryPool.zig");
const RenderPass = @import("RenderPass.zig");
const Sampler = @import("Sampler.zig");
const ShaderModule = @import("ShaderModule.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .device;

physical_device: *const PhysicalDevice,
queues: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(*Dispatchable(Queue))),
host_allocator: VulkanAllocator,

dispatch_table: *const DispatchTable,
vtable: *const VTable,

pub const VTable = struct {
    createQueue: *const fn (std.mem.Allocator, *Self, u32, u32, vk.DeviceQueueCreateFlags) VkError!*Queue,
    destroyQueue: *const fn (*Queue, std.mem.Allocator) VkError!void,
};

pub const DispatchTable = struct {
    allocateMemory: *const fn (*Self, std.mem.Allocator, *const vk.MemoryAllocateInfo) VkError!*DeviceMemory,
    createBuffer: *const fn (*Self, std.mem.Allocator, *const vk.BufferCreateInfo) VkError!*Buffer,
    createBufferView: *const fn (*Self, std.mem.Allocator, *const vk.BufferViewCreateInfo) VkError!*BufferView,
    createCommandPool: *const fn (*Self, std.mem.Allocator, *const vk.CommandPoolCreateInfo) VkError!*CommandPool,
    createComputePipeline: *const fn (*Self, std.mem.Allocator, ?*PipelineCache, *const vk.ComputePipelineCreateInfo) VkError!*Pipeline,
    createDescriptorPool: *const fn (*Self, std.mem.Allocator, *const vk.DescriptorPoolCreateInfo) VkError!*DescriptorPool,
    createDescriptorSetLayout: *const fn (*Self, std.mem.Allocator, *const vk.DescriptorSetLayoutCreateInfo) VkError!*DescriptorSetLayout,
    createEvent: *const fn (*Self, std.mem.Allocator, *const vk.EventCreateInfo) VkError!*Event,
    createFence: *const fn (*Self, std.mem.Allocator, *const vk.FenceCreateInfo) VkError!*Fence,
    createFramebuffer: *const fn (*Self, std.mem.Allocator, *const vk.FramebufferCreateInfo) VkError!*Framebuffer,
    createGraphicsPipeline: *const fn (*Self, std.mem.Allocator, ?*PipelineCache, *const vk.GraphicsPipelineCreateInfo) VkError!*Pipeline,
    createImage: *const fn (*Self, std.mem.Allocator, *const vk.ImageCreateInfo) VkError!*Image,
    createImageView: *const fn (*Self, std.mem.Allocator, *const vk.ImageViewCreateInfo) VkError!*ImageView,
    createPipelineCache: *const fn (*Self, std.mem.Allocator, *const vk.PipelineCacheCreateInfo) VkError!*PipelineCache,
    createPipelineLayout: *const fn (*Self, std.mem.Allocator, *const vk.PipelineLayoutCreateInfo) VkError!*PipelineLayout,
    createQueryPool: *const fn (*Self, std.mem.Allocator, *const vk.QueryPoolCreateInfo) VkError!*QueryPool,
    createRenderPass: *const fn (*Self, std.mem.Allocator, *const vk.RenderPassCreateInfo) VkError!*RenderPass,
    createSampler: *const fn (*Self, std.mem.Allocator, *const vk.SamplerCreateInfo) VkError!*Sampler,
    createSemaphore: *const fn (*Self, std.mem.Allocator, *const vk.SemaphoreCreateInfo) VkError!*BinarySemaphore,
    createShaderModule: *const fn (*Self, std.mem.Allocator, *const vk.ShaderModuleCreateInfo) VkError!*ShaderModule,
    destroy: *const fn (*Self, std.mem.Allocator) VkError!void,
};

pub fn init(allocator: std.mem.Allocator, physical_device: *const PhysicalDevice, info: *const vk.DeviceCreateInfo) VkError!Self {
    _ = info;
    return .{
        .physical_device = physical_device,
        .queues = .empty,
        .host_allocator = VulkanAllocator.from(allocator).clone(),
        .dispatch_table = undefined,
        .vtable = undefined,
    };
}

pub fn createQueues(self: *Self, allocator: std.mem.Allocator, info: *const vk.DeviceCreateInfo) VkError!void {
    if (info.queue_create_info_count == 0) {
        return;
    } else if (info.p_queue_create_infos == null) {
        return VkError.ValidationFailed;
    }

    for (0..info.queue_create_info_count) |i| {
        const queue_info = info.p_queue_create_infos.?[i];
        const res = (self.queues.getOrPut(allocator, queue_info.queue_family_index) catch return VkError.OutOfHostMemory);
        const family_ptr = res.value_ptr;
        if (!res.found_existing) {
            family_ptr.* = .empty;
        }

        const queue = try self.vtable.createQueue(allocator, self, queue_info.queue_family_index, @intCast(family_ptr.items.len), queue_info.flags);

        logger.getManager().get().indent();
        defer logger.getManager().get().unindent();

        const dispatchable_queue = try Dispatchable(Queue).wrap(allocator, queue);
        family_ptr.append(allocator, dispatchable_queue) catch return VkError.OutOfHostMemory;
    }
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) VkError!void {
    var it = self.queues.iterator();
    while (it.next()) |entry| {
        const family = entry.value_ptr;
        for (family.items) |dispatchable_queue| {
            try self.vtable.destroyQueue(dispatchable_queue.object, allocator);
            dispatchable_queue.destroy(allocator);
        }
        family.deinit(allocator);
    }
    self.queues.deinit(allocator);
    try self.dispatch_table.destroy(self, allocator);
}

pub inline fn allocateMemory(self: *Self, allocator: std.mem.Allocator, info: *const vk.MemoryAllocateInfo) VkError!*DeviceMemory {
    return self.dispatch_table.allocateMemory(self, allocator, info);
}

pub inline fn createBuffer(self: *Self, allocator: std.mem.Allocator, info: *const vk.BufferCreateInfo) VkError!*Buffer {
    return self.dispatch_table.createBuffer(self, allocator, info);
}

pub inline fn createDescriptorPool(self: *Self, allocator: std.mem.Allocator, info: *const vk.DescriptorPoolCreateInfo) VkError!*DescriptorPool {
    return self.dispatch_table.createDescriptorPool(self, allocator, info);
}

pub inline fn createDescriptorSetLayout(self: *Self, allocator: std.mem.Allocator, info: *const vk.DescriptorSetLayoutCreateInfo) VkError!*DescriptorSetLayout {
    return self.dispatch_table.createDescriptorSetLayout(self, allocator, info);
}

pub inline fn createFence(self: *Self, allocator: std.mem.Allocator, info: *const vk.FenceCreateInfo) VkError!*Fence {
    return self.dispatch_table.createFence(self, allocator, info);
}

pub inline fn createCommandPool(self: *Self, allocator: std.mem.Allocator, info: *const vk.CommandPoolCreateInfo) VkError!*CommandPool {
    return self.dispatch_table.createCommandPool(self, allocator, info);
}

pub inline fn createImage(self: *Self, allocator: std.mem.Allocator, info: *const vk.ImageCreateInfo) VkError!*Image {
    return self.dispatch_table.createImage(self, allocator, info);
}

pub inline fn createImageView(self: *Self, allocator: std.mem.Allocator, info: *const vk.ImageViewCreateInfo) VkError!*ImageView {
    return self.dispatch_table.createImageView(self, allocator, info);
}

pub inline fn createBufferView(self: *Self, allocator: std.mem.Allocator, info: *const vk.BufferViewCreateInfo) VkError!*BufferView {
    return self.dispatch_table.createBufferView(self, allocator, info);
}

pub inline fn createComputePipeline(self: *Self, allocator: std.mem.Allocator, cache: ?*PipelineCache, info: *const vk.ComputePipelineCreateInfo) VkError!*Pipeline {
    return self.dispatch_table.createComputePipeline(self, allocator, cache, info);
}

pub inline fn createEvent(self: *Self, allocator: std.mem.Allocator, info: *const vk.EventCreateInfo) VkError!*Event {
    return self.dispatch_table.createEvent(self, allocator, info);
}

pub inline fn createFramebuffer(self: *Self, allocator: std.mem.Allocator, info: *const vk.FramebufferCreateInfo) VkError!*Framebuffer {
    return self.dispatch_table.createFramebuffer(self, allocator, info);
}

pub inline fn createGraphicsPipeline(self: *Self, allocator: std.mem.Allocator, cache: ?*PipelineCache, info: *const vk.GraphicsPipelineCreateInfo) VkError!*Pipeline {
    return self.dispatch_table.createGraphicsPipeline(self, allocator, cache, info);
}

pub inline fn createPipelineCache(self: *Self, allocator: std.mem.Allocator, info: *const vk.PipelineCacheCreateInfo) VkError!*PipelineCache {
    return self.dispatch_table.createPipelineCache(self, allocator, info);
}

pub inline fn createPipelineLayout(self: *Self, allocator: std.mem.Allocator, info: *const vk.PipelineLayoutCreateInfo) VkError!*PipelineLayout {
    return self.dispatch_table.createPipelineLayout(self, allocator, info);
}

pub inline fn createQueryPool(self: *Self, allocator: std.mem.Allocator, info: *const vk.QueryPoolCreateInfo) VkError!*QueryPool {
    return self.dispatch_table.createQueryPool(self, allocator, info);
}

pub inline fn createRenderPass(self: *Self, allocator: std.mem.Allocator, info: *const vk.RenderPassCreateInfo) VkError!*RenderPass {
    return self.dispatch_table.createRenderPass(self, allocator, info);
}

pub inline fn createSampler(self: *Self, allocator: std.mem.Allocator, info: *const vk.SamplerCreateInfo) VkError!*Sampler {
    return self.dispatch_table.createSampler(self, allocator, info);
}

pub inline fn createSemaphore(self: *Self, allocator: std.mem.Allocator, info: *const vk.SemaphoreCreateInfo) VkError!*BinarySemaphore {
    return self.dispatch_table.createSemaphore(self, allocator, info);
}

pub inline fn createShaderModule(self: *Self, allocator: std.mem.Allocator, info: *const vk.ShaderModuleCreateInfo) VkError!*ShaderModule {
    return self.dispatch_table.createShaderModule(self, allocator, info);
}

pub inline fn waitIdle(self: *Self) VkError!void {
    var it = self.queues.iterator();
    while (it.next()) |family| {
        for (family.value_ptr.items) |queue| {
            try queue.object.waitIdle();
        }
    }
}
