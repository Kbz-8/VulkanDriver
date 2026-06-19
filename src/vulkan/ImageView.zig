const std = @import("std");
const vk = @import("vulkan");
const lib = @import("lib.zig");

const VkError = @import("error_set.zig").VkError;
const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;

const Device = @import("Device.zig");
const Image = @import("Image.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .image_view;

owner: *Device,
image: *Image,
view_type: vk.ImageViewType,
format: vk.Format,
components: vk.ComponentMapping,
subresource_range: vk.ImageSubresourceRange,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.ImageViewCreateInfo) VkError!Self {
    _ = allocator;
    return .{
        .owner = device,
        .image = try NonDispatchable(Image).fromHandleObject(info.image),
        .view_type = info.view_type,
        .format = info.format,
        .components = info.components,
        .subresource_range = info.subresource_range,
        .vtable = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}

pub fn levelCount(self: *const Self) u32 {
    return if (self.subresource_range.level_count == vk.REMAINING_MIP_LEVELS)
        self.image.mip_levels - self.subresource_range.base_mip_level
    else
        self.subresource_range.level_count;
}

pub fn layerCount(self: *const Self) u32 {
    return if (self.subresource_range.layer_count == vk.REMAINING_ARRAY_LAYERS)
        self.remainingLayerCount()
    else
        self.subresource_range.layer_count;
}

pub fn resolvedSubresourceRange(self: *const Self) vk.ImageSubresourceRange {
    var range = self.subresource_range;
    range.level_count = self.levelCount();
    range.layer_count = self.layerCount();
    return range;
}

fn remainingLayerCount(self: *const Self) u32 {
    if (self.image.image_type == .@"3d" and self.image.flags.@"2d_array_compatible_bit") {
        const depth = @max(@as(u32, 1), self.image.extent.depth >> @intCast(self.subresource_range.base_mip_level));
        return depth - self.subresource_range.base_array_layer;
    }

    return self.image.array_layers - self.subresource_range.base_array_layer;
}
