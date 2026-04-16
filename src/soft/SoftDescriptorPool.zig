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

list: std.ArrayList(*SoftDescriptorSet),

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
        .list = std.ArrayList(*SoftDescriptorSet).initCapacity(allocator, info.max_sets) catch return VkError.OutOfHostMemory,
    };
    return self;
}

pub fn allocateDescriptorSet(interface: *Interface, layout: *base.DescriptorSetLayout) VkError!*base.DescriptorSet {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = VulkanAllocator.init(null, .object).allocator();
    const set = try SoftDescriptorSet.create(interface.owner, allocator, layout);
    self.list.appendAssumeCapacity(set);
    return &set.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.list.deinit(allocator);
    allocator.destroy(self);
}

pub fn freeDescriptorSet(interface: *Interface, set: *base.DescriptorSet) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const soft_set: *SoftDescriptorSet = @alignCast(@fieldParentPtr("interface", set));

    if (std.mem.indexOfScalar(*SoftDescriptorSet, self.list.items, soft_set)) |pos| {
        _ = self.list.orderedRemove(pos);
    }

    const allocator = VulkanAllocator.init(null, .object).allocator();
    allocator.destroy(soft_set);
}

pub fn reset(interface: *Interface, _: vk.DescriptorPoolResetFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = VulkanAllocator.init(null, .object).allocator();

    for (self.list.items) |set| {
        allocator.destroy(set);
    }
    self.list.clearRetainingCapacity();
}
