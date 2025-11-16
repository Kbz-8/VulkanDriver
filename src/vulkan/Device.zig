const std = @import("std");
const vk = @import("vulkan");

const Dispatchable = @import("Dispatchable.zig").Dispatchable;
const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;
const VulkanAllocator = @import("VulkanAllocator.zig");
const VkError = @import("error_set.zig").VkError;

const PhysicalDevice = @import("PhysicalDevice.zig");
const Queue = @import("Queue.zig");

const CommandBuffer = @import("CommandBuffer.zig");
const CommandPool = @import("CommandPool.zig");
const DeviceMemory = @import("DeviceMemory.zig");
const Fence = @import("Fence.zig");

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
    allocateCommandBuffers: *const fn (*Self, *const vk.CommandBufferAllocateInfo) VkError![]*Dispatchable(CommandBuffer),
    allocateMemory: *const fn (*Self, std.mem.Allocator, *const vk.MemoryAllocateInfo) VkError!*DeviceMemory,
    createCommandPool: *const fn (*Self, std.mem.Allocator, *const vk.CommandPoolCreateInfo) VkError!*CommandPool,
    createFence: *const fn (*Self, std.mem.Allocator, *const vk.FenceCreateInfo) VkError!*Fence,
    destroy: *const fn (*Self, std.mem.Allocator) VkError!void,
    destroyCommandPool: *const fn (*Self, std.mem.Allocator, *CommandPool) VkError!void,
    destroyFence: *const fn (*Self, std.mem.Allocator, *Fence) VkError!void,
    freeCommandBuffers: *const fn (*Self, *CommandPool, []*Dispatchable(CommandBuffer)) VkError!void,
    freeMemory: *const fn (*Self, std.mem.Allocator, *DeviceMemory) VkError!void,
    getFenceStatus: *const fn (*Self, *Fence) VkError!void,
    resetFences: *const fn (*Self, []*Fence) VkError!void,
    waitForFences: *const fn (*Self, []*Fence, bool, u64) VkError!void,
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

// Fence functions ===================================================================================================================================

pub inline fn createFence(self: *Self, allocator: std.mem.Allocator, info: *const vk.FenceCreateInfo) VkError!*Fence {
    return self.dispatch_table.createFence(self, allocator, info);
}

pub inline fn destroyFence(self: *Self, allocator: std.mem.Allocator, fence: *Fence) VkError!void {
    try self.dispatch_table.destroyFence(self, allocator, fence);
}

pub inline fn getFenceStatus(self: *Self, fence: *Fence) VkError!void {
    try self.dispatch_table.getFenceStatus(self, fence);
}

pub inline fn resetFences(self: *Self, fences: []*Fence) VkError!void {
    try self.dispatch_table.resetFences(self, fences);
}

pub inline fn waitForFences(self: *Self, fences: []*Fence, waitForAll: bool, timeout: u64) VkError!void {
    try self.dispatch_table.waitForFences(self, fences, waitForAll, timeout);
}

// Command Pool functions ============================================================================================================================

pub inline fn allocateCommandBuffers(self: *Self, info: *const vk.CommandBufferAllocateInfo) VkError![]*Dispatchable(CommandBuffer) {
    return self.dispatch_table.allocateCommandBuffers(self, info);
}

pub inline fn createCommandPool(self: *Self, allocator: std.mem.Allocator, info: *const vk.CommandPoolCreateInfo) VkError!*CommandPool {
    return self.dispatch_table.createCommandPool(self, allocator, info);
}

pub inline fn destroyCommandPool(self: *Self, allocator: std.mem.Allocator, pool: *CommandPool) VkError!void {
    try self.dispatch_table.destroyCommandPool(self, allocator, pool);
}

pub inline fn freeCommandBuffers(self: *Self, pool: *CommandPool, cmds: []*Dispatchable(CommandBuffer)) VkError!void {
    try self.dispatch_table.freeCommandBuffers(self, pool, cmds);
}

// Memory functions ==================================================================================================================================

pub inline fn allocateMemory(self: *Self, allocator: std.mem.Allocator, info: *const vk.MemoryAllocateInfo) VkError!*DeviceMemory {
    return self.dispatch_table.allocateMemory(self, allocator, info);
}

pub inline fn freeMemory(self: *Self, allocator: std.mem.Allocator, device_memory: *DeviceMemory) VkError!void {
    try self.dispatch_table.freeMemory(self, allocator, device_memory);
}

pub inline fn mapMemory(_: *Self, device_memory: *DeviceMemory, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!?*anyopaque {
    return device_memory.map(offset, size);
}

pub inline fn unmapMemory(_: *Self, device_memory: *DeviceMemory) void {
    return device_memory.unmap();
}
