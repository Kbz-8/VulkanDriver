const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const builtin = @import("builtin");

const Debug = std.builtin.OptimizeMode.Debug;

const SoftCommandPool = @import("SoftCommandPool.zig");
const SoftQueue = @import("SoftQueue.zig");

const SoftBuffer = @import("SoftBuffer.zig");
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
        .allocateMemory = allocateMemory,
        .createBuffer = createBuffer,
        .createCommandPool = createCommandPool,
        .createFence = createFence,
        .destroy = destroy,
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

pub fn createBuffer(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.BufferCreateInfo) VkError!*base.Buffer {
    const buffer = try SoftBuffer.create(interface, allocator, info);
    return &buffer.interface;
}

pub fn createFence(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.FenceCreateInfo) VkError!*base.Fence {
    const fence = try SoftFence.create(interface, allocator, info);
    return &fence.interface;
}

pub fn createCommandPool(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.CommandPoolCreateInfo) VkError!*base.CommandPool {
    const pool = try SoftCommandPool.create(interface, allocator, info);
    return &pool.interface;
}

pub fn allocateMemory(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.MemoryAllocateInfo) VkError!*base.DeviceMemory {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device_memory = try SoftDeviceMemory.create(self, allocator, info.allocation_size, info.memory_type_index);
    return &device_memory.interface;
}
