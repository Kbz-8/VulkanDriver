const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const SoftDeviceMemory = @import("SoftDeviceMemory.zig");
const SoftFence = @import("SoftFence.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Device;

const SpawnError = std.Thread.SpawnError;

interface: Interface,
device_allocator: std.heap.ThreadSafeAllocator,
workers: std.Thread.Pool,

pub fn create(physical_device: *base.PhysicalDevice, allocator: std.mem.Allocator, info: *const vk.DeviceCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, physical_device, info);

    interface.dispatch_table = &.{
        .allocateMemory = allocateMemory,
        .createFence = createFence,
        .destroy = destroy,
        .destroyFence = destroyFence,
        .freeMemory = freeMemory,
        .getFenceStatus = getFenceStatus,
        .resetFences = resetFences,
        .waitForFences = waitForFences,
    };

    self.* = .{
        .interface = interface,
        .device_allocator = .{ .child_allocator = std.heap.c_allocator }, // TODO: better device allocator
        .workers = undefined,
    };

    self.workers.init(.{ .allocator = self.interface.host_allocator.allocator() }) catch |err| return switch (err) {
        SpawnError.OutOfMemory, SpawnError.LockedMemoryLimitExceeded => VkError.OutOfDeviceMemory,
        else => VkError.Unknown,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.workers.deinit();
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

// Memory functions ==================================================================================================================================

pub fn allocateMemory(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.MemoryAllocateInfo) VkError!*base.DeviceMemory {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device_memory = try SoftDeviceMemory.create(self, allocator, info.allocation_size, info.memory_type_index);
    return &device_memory.interface;
}

pub fn freeMemory(_: *Interface, allocator: std.mem.Allocator, device_memory: *base.DeviceMemory) VkError!void {
    device_memory.destroy(allocator);
}
