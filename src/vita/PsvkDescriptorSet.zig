const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.DescriptorSet;

interface: Interface,

pub fn create(device: *base.Device, allocator: std.mem.Allocator, layout: *base.DescriptorSetLayout) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, layout);

    interface.vtable = &.{
        .copy = copy,
        .destroy = destroy,
        .write = write,
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

pub fn copy(_: *Interface, _: *const Interface, _: vk.CopyDescriptorSet) VkError!void {
    return;
}

pub fn write(_: *Interface, _: vk.WriteDescriptorSet) VkError!void {
    return;
}
