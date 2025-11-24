const std = @import("std");
const vk = @import("vulkan");
const lib = @import("lib.zig");

const VkError = @import("error_set.zig").VkError;
const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;

const Device = @import("Device.zig");

const DeviceMemory = @import("DeviceMemory.zig");
const Image = @import("Image.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .image;

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
