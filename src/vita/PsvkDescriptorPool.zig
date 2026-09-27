const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const PsvkDescriptorSet = @import("PsvkDescriptorSet.zig");

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
    return &(try PsvkDescriptorSet.create(interface.owner, interface.owner.host_allocator.allocator(), layout)).interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    allocator.destroy(self);
}

pub fn freeDescriptorSet(_: *Interface, set: *base.DescriptorSet) VkError!void {
    set.destroy(set.owner.host_allocator.allocator());
}

pub fn reset(_: *Interface, _: vk.DescriptorPoolResetFlags) VkError!void {
    return;
}
