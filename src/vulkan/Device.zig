const std = @import("std");
const vk = @import("vulkan");

const Dispatchable = @import("Dispatchable.zig").Dispatchable;
const VulkanAllocator = @import("VulkanAllocator.zig");
const VkError = @import("error_set.zig").VkError;
const PhysicalDevice = @import("PhysicalDevice.zig");
const DeviceMemory = @import("DeviceMemory.zig");
const Fence = @import("Fence.zig");
const Queue = @import("Queue.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .device;

physical_device: *const PhysicalDevice,
dispatch_table: *const DispatchTable,
host_allocator: VulkanAllocator,
queues: std.AutoArrayHashMapUnmanaged(u32, *Dispatchable(Queue)),

pub const DispatchTable = struct {
    allocateMemory: *const fn (*Self, std.mem.Allocator, *const vk.MemoryAllocateInfo) VkError!*DeviceMemory,
    createFence: *const fn (*Self, std.mem.Allocator, *const vk.FenceCreateInfo) VkError!*Fence,
    destroyFence: *const fn (*Self, std.mem.Allocator, *Fence) VkError!void,
    freeMemory: *const fn (*Self, std.mem.Allocator, *DeviceMemory) VkError!void,
    getFenceStatus: *const fn (*Self, *Fence) VkError!void,
    destroy: *const fn (*Self, std.mem.Allocator) VkError!void,
    resetFences: *const fn (*Self, []*Fence) VkError!void,
    waitForFences: *const fn (*Self, []*Fence, bool, u64) VkError!void,
};

pub fn init(allocator: std.mem.Allocator, physical_device: *const PhysicalDevice, info: *const vk.DeviceCreateInfo) VkError!Self {
    const vulkan_allocator: *VulkanAllocator = @ptrCast(@alignCast(allocator.ptr));
    _ = info;
    return .{
        .physical_device = physical_device,
        .dispatch_table = undefined,
        .host_allocator = vulkan_allocator.*,
        .queues = .empty,
    };
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) VkError!void {
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
