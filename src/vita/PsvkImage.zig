const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Image;

interface: Interface,

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.ImageCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);

    interface.vtable = &.{
        .destroy = destroy,
        .getMemoryRequirements = getMemoryRequirements,
        .getSubresourceLayout = getSubresourceLayout,
        .getTotalSizeForAspect = getTotalSizeForAspect,
        .getSliceMemSizeForMipLevel = getSliceMemSizeForMipLevel,
        .getRowPitchMemSizeForMipLevel = getRowPitchMemSizeForMipLevel,
        .copyToMemory = copyToMemory,
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

pub fn getMemoryRequirements(_: *Interface, requirements: *vk.MemoryRequirements) VkError!void {
    requirements.* = .{ .size = 0, .alignment = 1, .memory_type_bits = 0 };
}

pub fn getSubresourceLayout(_: *const Interface, _: vk.ImageSubresource) VkError!vk.SubresourceLayout {
    return .{ .offset = 0, .size = 0, .row_pitch = 0, .array_pitch = 0, .depth_pitch = 0 };
}

pub fn getTotalSizeForAspect(_: *const Interface, _: vk.ImageAspectFlags) VkError!usize {
    return 0;
}

pub fn getSliceMemSizeForMipLevel(_: *const Interface, _: vk.ImageAspectFlags, _: u32) usize {
    return 0;
}

pub fn getRowPitchMemSizeForMipLevel(_: *const Interface, _: vk.ImageAspectFlags, _: u32) usize {
    return 0;
}

pub fn copyToMemory(_: *const Interface, _: []u8, _: vk.ImageSubresourceLayers) VkError!void {
    return;
}
