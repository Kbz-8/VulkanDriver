const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;
const VulkanAllocator = base.VulkanAllocator;

const FlintDescriptorSet = @import("FlintDescriptorSet.zig");

const Self = @This();
pub const Interface = base.DescriptorPool;

interface: Interface,
sets: std.ArrayList(*FlintDescriptorSet),

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
        .sets = std.ArrayList(*FlintDescriptorSet).initCapacity(allocator, info.max_sets) catch return VkError.OutOfHostMemory,
    };
    return self;
}

pub fn allocateDescriptorSet(interface: *Interface, layout: *base.DescriptorSetLayout) VkError!*base.DescriptorSet {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    if (self.sets.items.len == self.sets.capacity) return VkError.OutOfPoolMemory;

    const allocator = VulkanAllocator.init(null, .object).allocator();
    const set = try FlintDescriptorSet.create(interface.owner, allocator, layout);
    self.sets.appendAssumeCapacity(set);
    return &set.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const set_allocator = VulkanAllocator.init(null, .object).allocator();
    for (self.sets.items) |set| set.interface.destroy(set_allocator);
    self.sets.deinit(allocator);
    allocator.destroy(self);
}

pub fn freeDescriptorSet(interface: *Interface, set: *base.DescriptorSet) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const flint_set: *FlintDescriptorSet = @alignCast(@fieldParentPtr("interface", set));
    const index = std.mem.indexOfScalar(*FlintDescriptorSet, self.sets.items, flint_set) orelse return VkError.ValidationFailed;
    _ = self.sets.orderedRemove(index);

    const allocator = VulkanAllocator.init(null, .object).allocator();
    set.destroy(allocator);
}

pub fn reset(interface: *Interface, _: vk.DescriptorPoolResetFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = VulkanAllocator.init(null, .object).allocator();
    for (self.sets.items) |set| set.interface.destroy(allocator);
    self.sets.clearRetainingCapacity();
}
