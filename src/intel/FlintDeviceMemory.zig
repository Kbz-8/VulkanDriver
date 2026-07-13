const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const FlintDevice = @import("FlintDevice.zig");
const kmd = @import("kmd.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.DeviceMemory;

interface: Interface,
allocation: kmd.Memory,

pub fn create(device: *FlintDevice, allocator: std.mem.Allocator, size: vk.DeviceSize, memory_type_index: u32) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    if (memory_type_index >= device.interface.physical_device.mem_props.memory_type_count) {
        return VkError.ValidationFailed;
    }

    var interface = try Interface.init(&device.interface, size, memory_type_index);
    var allocation = try device.kmd.allocateMemory(device.interface.io(), size);
    errdefer allocation.deinit(&device.kmd, device.interface.io());

    interface.vtable = &.{
        .destroy = destroy,
        .map = map,
        .unmap = unmap,
        .flushRange = flushRange,
        .invalidateRange = invalidateRange,
    };

    self.* = .{
        .interface = interface,
        .allocation = allocation,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device: *FlintDevice = @alignCast(@fieldParentPtr("interface", interface.owner));
    self.allocation.deinit(&device.kmd, interface.owner.io());
    allocator.destroy(self);
}

pub fn flushRange(interface: *Interface, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device: *FlintDevice = @alignCast(@fieldParentPtr("interface", interface.owner));
    try self.allocation.flushRange(&device.kmd, interface.owner.io(), offset, size);
}

pub fn invalidateRange(interface: *Interface, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device: *FlintDevice = @alignCast(@fieldParentPtr("interface", interface.owner));
    try self.allocation.invalidateRange(&device.kmd, interface.owner.io(), offset, size);
}

pub fn map(interface: *Interface, offset: vk.DeviceSize, size: vk.DeviceSize) VkError![]u8 {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    if (interface.is_mapped) return VkError.MemoryMapFailed;

    const device: *FlintDevice = @alignCast(@fieldParentPtr("interface", interface.owner));
    const data = try self.allocation.map(&device.kmd, interface.owner.io(), offset, size);
    interface.is_mapped = true;
    return data;
}

pub fn unmap(interface: *Interface) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.allocation.unmap();
    interface.is_mapped = false;
}
