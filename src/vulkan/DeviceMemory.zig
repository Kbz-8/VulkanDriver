const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .device_memory;

owner: *const Device,
size: vk.DeviceSize,
memory_type_index: u32,
is_mapped: bool,

vtable: *const VTable,

pub const VTable = struct {
    map: *const fn (*Self, vk.DeviceSize, vk.DeviceSize) VkError!?*anyopaque,
    unmap: *const fn (*Self) void,
};

pub fn init(device: *const Device, size: vk.DeviceSize, memory_type_index: u32) VkError!Self {
    return .{
        .owner = device,
        .size = size,
        .memory_type_index = memory_type_index,
        .is_mapped = false,
    };
}

pub inline fn map(self: *Self, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!?*anyopaque {
    return self.vtable.map(self, offset, size);
}

pub inline fn unmap(self: *Self) void {
    return self.vtable.unmap(self);
}
