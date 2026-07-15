const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.DescriptorPool;

interface: Interface,

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.DescriptorPoolCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);

    interface.vtable = &.{
        .allocateDescriptorSet = allocateDescriptorSet,
        .destroy = destroy,
        .freeDescriptorSet = freeDescriptorSet,
        .reset = reset,
    };

    self.* = .{
        .interface = interface,
    };
    return self;
}

pub fn allocateDescriptorSet(interface: *Interface, layout: *base.DescriptorSetLayout) VkError!*base.DescriptorSet {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = self;
    _ = layout;
    return VkError.Unknown;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn freeDescriptorSet(interface: *Interface, set: *base.DescriptorSet) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = self;
    _ = set;
}

pub fn reset(interface: *Interface, _: vk.DescriptorPoolResetFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = self;
}
