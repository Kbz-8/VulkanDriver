const std = @import("std");
const vk = @import("vulkan");
const SoftDeviceMemory = @import("SoftDeviceMemory.zig");
const base = @import("base");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Device;

interface: Interface,
device_allocator: std.heap.ThreadSafeAllocator,

pub fn create(physical_device: *base.PhysicalDevice, allocator: std.mem.Allocator, infos: *const vk.DeviceCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, physical_device, infos);

    interface.dispatch_table = &.{
        .allocateMemory = allocateMemory,
        .freeMemory = freeMemory,
        .destroy = destroy,
    };

    self.* = .{
        .interface = interface,
        .device_allocator = .{ .child_allocator = std.heap.c_allocator }, // TODO: better device allocator base
    };
    return self;
}

pub fn allocateMemory(interface: *Interface, allocator: std.mem.Allocator, infos: *const vk.MemoryAllocateInfo) VkError!*base.DeviceMemory {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device_memory = try SoftDeviceMemory.create(self, allocator, infos.allocation_size, infos.memory_type_index);
    return &device_memory.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn freeMemory(_: *Interface, allocator: std.mem.Allocator, device_memory: *base.DeviceMemory) VkError!void {
    device_memory.destroy(allocator);
}
