const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const PsvkDescriptorSet = @import("PsvkDescriptorSet.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.DescriptorPool;

interface: Interface,
sets: std.ArrayList(*PsvkDescriptorSet),

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
        .sets = std.ArrayList(*PsvkDescriptorSet).initCapacity(allocator, info.max_sets) catch return VkError.OutOfHostMemory,
    };

    return self;
}

pub fn allocateDescriptorSet(interface: *Interface, layout: *base.DescriptorSetLayout) VkError!*base.DescriptorSet {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    if (self.sets.items.len == self.sets.capacity) return VkError.OutOfPoolMemory;

    const set = try PsvkDescriptorSet.create(interface.owner, interface.allocator(), layout);
    self.sets.appendAssumeCapacity(set);
    return &set.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    for (self.sets.items) |set| set.interface.destroy(allocator);
    self.sets.deinit(allocator);
    allocator.destroy(self);
}

pub fn freeDescriptorSet(interface: *Interface, set: *base.DescriptorSet) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const psvk_set: *PsvkDescriptorSet = @alignCast(@fieldParentPtr("interface", set));
    const index = std.mem.indexOfScalar(*PsvkDescriptorSet, self.sets.items, psvk_set) orelse
        return VkError.ValidationFailed;

    _ = self.sets.swapRemove(index);
    set.destroy(interface.allocator());
}

pub fn reset(interface: *Interface, _: vk.DescriptorPoolResetFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = interface.allocator();

    for (self.sets.items) |set| set.interface.destroy(allocator);
    self.sets.clearRetainingCapacity();
}
