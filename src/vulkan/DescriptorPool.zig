const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .descriptor_pool;

owner: *Device,
flags: vk.DescriptorPoolCreateFlags,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.DescriptorPoolCreateInfo) VkError!Self {
    _ = allocator;
    return .{
        .owner = device,
        .flags = info.flags,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}
