const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const lib = @import("lib.zig");

const VkError = base.VkError;
const Device = base.Device;

const SoftDevice = @import("SoftDevice.zig");

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

pub fn getMemoryRequirements(interface: *Interface, requirements: *vk.MemoryRequirements) void {
    _ = interface;
    requirements.alignment = lib.MEMORY_REQUIREMENTS_IMAGE_ALIGNMENT;
}

inline fn clear(self: *Self, pixel: vk.ClearValue, format: vk.Format, view_format: vk.Format, range: vk.ImageSubresourceRange, area: ?vk.Rect2D) void {
    const soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", self.interface.owner));
    soft_device.blitter.clear(pixel, format, self, view_format, range, area);
}

pub fn clearRange(self: *Self, color: vk.ClearColorValue, range: vk.ImageSubresourceRange) void {
    std.debug.assert(range.aspect_mask == vk.ImageAspectFlags{ .color_bit = true });

    const clear_format: vk.Format = if (base.vku.vkuFormatIsSINT(@intCast(@intFromEnum(self.interface.format))))
        .r32g32b32a32_sint
    else if (base.vku.vkuFormatIsUINT(@intCast(@intFromEnum(self.interface.format))))
        .r32g32b32a32_uint
    else
        .r32g32b32a32_sfloat;
    self.clear(.{ .color = color }, clear_format, self.interface.format, range, null);
}
