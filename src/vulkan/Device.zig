const std = @import("std");
const vk = @import("vulkan");

const Dispatchable = @import("Dispatchable.zig").Dispatchable;
const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;
const VulkanAllocator = @import("VulkanAllocator.zig");
const VkError = @import("error_set.zig").VkError;

const PhysicalDevice = @import("PhysicalDevice.zig");
const Queue = @import("Queue.zig");

const Buffer = @import("Buffer.zig");
const CommandBuffer = @import("CommandBuffer.zig");
const CommandPool = @import("CommandPool.zig");
const DeviceMemory = @import("DeviceMemory.zig");
const DescriptorPool = @import("DescriptorPool.zig");
const DescriptorSet = @import("DescriptorSet.zig");
const DescriptorSetLayout = @import("DescriptorSetLayout.zig");
const Fence = @import("Fence.zig");
const Image = @import("Image.zig");
const ImageView = @import("ImageView.zig");

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
    createCommandPool: *const fn (*Self, std.mem.Allocator, *const vk.CommandPoolCreateInfo) VkError!*CommandPool,
    createDescriptorPool: *const fn (*Self, std.mem.Allocator, *const vk.DescriptorPoolCreateInfo) VkError!*DescriptorPool,
    createDescriptorSetLayout: *const fn (*Self, std.mem.Allocator, *const vk.DescriptorSetLayoutCreateInfo) VkError!*DescriptorSetLayout,
    createFence: *const fn (*Self, std.mem.Allocator, *const vk.FenceCreateInfo) VkError!*Fence,
    createImage: *const fn (*Self, std.mem.Allocator, *const vk.ImageCreateInfo) VkError!*Image,
    createImageView: *const fn (*Self, std.mem.Allocator, *const vk.ImageViewCreateInfo) VkError!*ImageView,
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
