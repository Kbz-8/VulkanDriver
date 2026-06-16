const std = @import("std");
const vk = @import("vulkan");
const IntelDevice = @import("IntelDevice.zig");
const base = @import("base");
const lib = @import("lib.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.DeviceMemory;

interface: Interface,

pub fn create(device: *IntelDevice, allocator: std.mem.Allocator, size: vk.DeviceSize, memory_type_index: u32) VkError!*Self {
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

pub fn flushRange(interface: *Interface, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!void {
    _ = interface;
    _ = offset;
    _ = size;
}

pub fn invalidateRange(interface: *Interface, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!void {
    _ = interface;
    _ = offset;
    _ = size;
}

pub fn map(interface: *Interface, offset: vk.DeviceSize, size: vk.DeviceSize) VkError![]u8 {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = self;
    _ = offset;
    _ = size;
    return VkError.Unknown;
}

pub fn unmap(_: *Interface) void {}
