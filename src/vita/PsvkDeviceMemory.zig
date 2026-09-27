const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const PsvkDevice = @import("PsvkDevice.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.DeviceMemory;

interface: Interface,

pub fn create(device: *PsvkDevice, allocator: std.mem.Allocator, size: vk.DeviceSize, memory_type_index: u32) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(&device.interface, size, memory_type_index);

    interface.vtable = &.{
        .destroy = destroy,
        .map = map,
        .unmap = unmap,
        .flushRange = flushRange,
        .invalidateRange = invalidateRange,
    };

    self.* = .{
        .interface = interface,
    };

    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    allocator.destroy(self);
}

pub fn flushRange(_: *Interface, _: vk.DeviceSize, _: vk.DeviceSize) VkError!void {
    return;
}

pub fn invalidateRange(_: *Interface, _: vk.DeviceSize, _: vk.DeviceSize) VkError!void {
    return;
}

pub fn map(_: *Interface, _: vk.DeviceSize, _: vk.DeviceSize) VkError![]u8 {
    return @constCast(&.{});
}

pub fn unmap(_: *Interface) void {
    return;
}
