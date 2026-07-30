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
        .flushRange = flushRange,
        .invalidateRange = invalidateRange,
    };

    const allocation_size = std.math.cast(usize, size) orelse return VkError.OutOfDeviceMemory;
    self.* = .{
        .interface = interface,
        .data = device.interface.device_allocator.allocator().alloc(u8, allocation_size) catch return VkError.OutOfDeviceMemory,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    interface.owner.device_allocator.allocator().free(self.data);
    allocator.destroy(self);
}

pub fn flushRange(interface: *Interface, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!void {
    // No-op, host and device memory are the same for software driver
    _ = interface;
    _ = offset;
    _ = size;
}

pub fn invalidateRange(interface: *Interface, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!void {
    // No-op, host and device memory are the same for software driver
    _ = interface;
    _ = offset;
    _ = size;
}

pub fn map(interface: *Interface, offset: vk.DeviceSize, size: vk.DeviceSize) VkError![]u8 {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const map_offset = std.math.cast(usize, offset) orelse return VkError.MemoryMapFailed;
    if (map_offset >= self.data.len) {
        return VkError.MemoryMapFailed;
    }
    const map_size = if (size == vk.WHOLE_SIZE)
        self.data.len - map_offset
    else
        std.math.cast(usize, size) orelse return VkError.MemoryMapFailed;
    if (map_size > self.data.len - map_offset) {
        return VkError.MemoryMapFailed;
    }
    return self.data[map_offset..][0..map_size];
}

pub fn unmap(_: *Interface) void {
    // no-op
}
