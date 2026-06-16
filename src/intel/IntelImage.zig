const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("lib.zig");

const VkError = base.VkError;
const IntelBuffer = @import("IntelBuffer.zig");

const Self = @This();
pub const Interface = base.Image;

pub const F32x4 = @Vector(4, f32);
pub const U32x4 = @Vector(4, u32);

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
    requirements.alignment = lib.MEMORY_REQUIREMENTS_IMAGE_ALIGNMENT;
}

pub fn copyToMemory(interface: *const Interface, memory: []u8, subresource: vk.ImageSubresourceLayers) VkError!void {
    _ = interface;
    _ = subresource;
    @memset(memory, 0);
}

pub fn getTotalSizeForAspect(interface: *const Interface, aspect_mask: vk.ImageAspectFlags) VkError!usize {
    _ = aspect_mask;
    return interface.extent.width * interface.extent.height * interface.extent.depth * base.format.texelSize(interface.format);
}

pub fn getSubresourceLayout(interface: *const Interface, subresource: vk.ImageSubresource) VkError!vk.SubresourceLayout {
    _ = subresource;
    return .{
        .offset = 0,
        .size = try getTotalSizeForAspect(interface, base.format.toAspect(interface.format)),
        .row_pitch = getRowPitchMemSizeForMipLevel(interface, base.format.toAspect(interface.format), 0),
        .array_pitch = getSliceMemSizeForMipLevel(interface, base.format.toAspect(interface.format), 0),
        .depth_pitch = getSliceMemSizeForMipLevel(interface, base.format.toAspect(interface.format), 0),
    };
}

pub fn getSliceMemSizeForMipLevel(interface: *const Interface, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    _ = aspect_mask;
    _ = mip_level;
    return interface.extent.width * interface.extent.height * base.format.texelSize(interface.format);
}

pub fn getRowPitchMemSizeForMipLevel(interface: *const Interface, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    _ = aspect_mask;
    _ = mip_level;
    return interface.extent.width * base.format.texelSize(interface.format);
}
