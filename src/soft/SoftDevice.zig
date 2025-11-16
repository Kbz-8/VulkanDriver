const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const builtin = @import("builtin");

const Debug = std.builtin.OptimizeMode.Debug;

const SoftQueue = @import("SoftQueue.zig");

const SoftCommandPool = @import("SoftCommandPool.zig");
const SoftDeviceMemory = @import("SoftDeviceMemory.zig");
const SoftFence = @import("SoftFence.zig");

const VkError = base.VkError;
const Dispatchable = base.Dispatchable;
const NonDispatchable = base.NonDispatchable;

const Self = @This();
pub const Interface = base.Device;

const SpawnError = std.Thread.SpawnError;

interface: Interface,
device_allocator: if (builtin.mode == Debug) std.heap.DebugAllocator(.{}) else std.heap.ThreadSafeAllocator,
workers: std.Thread.Pool,

pub fn create(physical_device: *base.PhysicalDevice, allocator: std.mem.Allocator, info: *const vk.DeviceCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, physical_device, info);

    interface.vtable = &.{
        .createQueue = SoftQueue.create,
        .destroyQueue = SoftQueue.destroy,
    };

    interface.dispatch_table = &.{
        .allocateCommandBuffers = allocateCommandBuffers,
        .allocateMemory = allocateMemory,
        .createCommandPool = createCommandPool,
        .createFence = createFence,
        .destroy = destroy,
        .destroyCommandPool = destroyCommandPool,
        .destroyFence = destroyFence,
        .freeCommandBuffers = freeCommandBuffers,
        .freeMemory = freeMemory,
        .getFenceStatus = getFenceStatus,
        .resetFences = resetFences,
        .waitForFences = waitForFences,
    };

    self.* = .{
        .interface = interface,
        .device_allocator = if (builtin.mode == Debug) .init else .{ .child_allocator = std.heap.c_allocator }, // TODO: better device allocator
        .workers = undefined,
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

// Fence functions ===================================================================================================================================

pub fn createFence(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.FenceCreateInfo) VkError!*base.Fence {
    const fence = try SoftFence.create(interface, allocator, info);
    return &fence.interface;
}

pub fn destroyFence(_: *Interface, allocator: std.mem.Allocator, fence: *base.Fence) VkError!void {
    fence.destroy(allocator);
}

pub fn getFenceStatus(_: *Interface, fence: *base.Fence) VkError!void {
    try fence.getStatus();
}

pub fn resetFences(_: *Interface, fences: []*base.Fence) VkError!void {
    for (fences) |fence| {
        try fence.reset();
    }
}

pub fn waitForFences(_: *Interface, fences: []*base.Fence, waitForAll: bool, timeout: u64) VkError!void {
    for (fences) |fence| {
        try fence.wait(timeout);
        if (!waitForAll) return;
    }
}

// Command Pool functions ============================================================================================================================

pub fn allocateCommandBuffers(_: *Interface, info: *const vk.CommandBufferAllocateInfo) VkError![]*Dispatchable(base.CommandBuffer) {
    const pool = try NonDispatchable(base.CommandPool).fromHandleObject(info.command_pool);
    return pool.allocateCommandBuffers(info);
}

pub fn createCommandPool(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.CommandPoolCreateInfo) VkError!*base.CommandPool {
    const pool = try SoftCommandPool.create(interface, allocator, info);
    return &pool.interface;
}

pub fn destroyCommandPool(_: *Interface, allocator: std.mem.Allocator, pool: *base.CommandPool) VkError!void {
    pool.destroy(allocator);
}

pub fn freeCommandBuffers(_: *Interface, pool: *base.CommandPool, cmds: []*Dispatchable(base.CommandBuffer)) VkError!void {
    try pool.freeCommandBuffers(cmds);
}

// Memory functions ==================================================================================================================================

pub fn allocateMemory(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.MemoryAllocateInfo) VkError!*base.DeviceMemory {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device_memory = try SoftDeviceMemory.create(self, allocator, info.allocation_size, info.memory_type_index);
    return &device_memory.interface;
}

pub fn freeMemory(_: *Interface, allocator: std.mem.Allocator, device_memory: *base.DeviceMemory) VkError!void {
    device_memory.destroy(allocator);
}
