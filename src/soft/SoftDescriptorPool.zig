const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;
const VulkanAllocator = base.VulkanAllocator;

const Device = base.Device;

const SoftDescriptorSet = @import("SoftDescriptorSet.zig");

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
    };

    self.* = .{
        .interface = interface,
    };
    return self;
}

pub fn allocateDescriptorSet(interface: *Interface, layout: *base.DescriptorSetLayout) VkError!*base.DescriptorSet {
    const allocator = VulkanAllocator.init(null, .object).allocator();
    const set = try SoftDescriptorSet.create(interface.owner, allocator, layout);
    return &set.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn freeDescriptorSet(interface: *Interface, set: *base.DescriptorSet) VkError!void {
    _ = interface;
    const allocator = VulkanAllocator.init(null, .object).allocator();
    allocator.destroy(set);
}
