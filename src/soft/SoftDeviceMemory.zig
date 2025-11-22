const std = @import("std");
const vk = @import("vulkan");
const SoftDevice = @import("SoftDevice.zig");
const base = @import("base");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.DeviceMemory;

interface: Interface,
data: []u8,

pub fn create(device: *SoftDevice, allocator: std.mem.Allocator, size: vk.DeviceSize, memory_type_index: u32) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(&device.interface, size, memory_type_index);

    interface.vtable = &.{
        .destroy = destroy,
        .map = map,
        .unmap = unmap,
    };

    self.* = .{
        .interface = interface,
        .data = device.device_allocator.allocator().alloc(u8, size) catch return VkError.OutOfDeviceMemory,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", interface.owner));
    soft_device.device_allocator.allocator().free(self.data);
    allocator.destroy(self);
}

pub fn map(interface: *Interface, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!?*anyopaque {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    if (offset >= self.data.len or (size != vk.WHOLE_SIZE and offset + size > self.data.len)) {
        return VkError.MemoryMapFailed;
    }
    interface.is_mapped = true;
    return @ptrCast(&self.data[offset]);
}

pub fn unmap(interface: *Interface) void {
    interface.is_mapped = false;
}
