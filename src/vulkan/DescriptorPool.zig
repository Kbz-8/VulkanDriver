const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;

const Device = @import("Device.zig");

const DescriptorSet = @import("DescriptorSet.zig");
const DescriptorSetLayout = @import("DescriptorSetLayout.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .descriptor_pool;

owner: *Device,
flags: vk.DescriptorPoolCreateFlags,

vtable: *const VTable,

pub const VTable = struct {
    allocateDescriptorSet: *const fn (*Self, *DescriptorSetLayout) VkError!*DescriptorSet,
    destroy: *const fn (*Self, std.mem.Allocator) void,
    freeDescriptorSet: *const fn (*Self, *DescriptorSet) VkError!void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.DescriptorPoolCreateInfo) VkError!Self {
    _ = allocator;
    return .{
        .owner = device,
        .flags = info.flags,
        .vtable = undefined,
    };
}

pub inline fn allocateDescriptorSet(self: *Self, layout: *DescriptorSetLayout) VkError!*DescriptorSet {
    return self.vtable.allocateDescriptorSet(self, layout);
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}

pub inline fn freeDescriptorSet(self: *Self, set: *DescriptorSet) VkError!void {
    try self.vtable.freeDescriptorSet(self, set);
}
