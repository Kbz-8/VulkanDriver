const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const Dispatchable = @import("Dispatchable.zig").Dispatchable;

const Device = @import("Device.zig");

const DescriptorSet = @import("DescriptorSet.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .descriptor_pool;

owner: *Device,
flags: vk.DescriptorPoolCreateFlags,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
    freeDescriptorSets: *const fn (*Self, []*Dispatchable(DescriptorSet)) VkError!void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.DescriptorPoolCreateInfo) VkError!Self {
    _ = allocator;
    return .{
        .owner = device,
        .flags = info.flags,
        .vtable = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}

pub inline fn freeDescriptorSets(self: *Self, sets: []*Dispatchable(DescriptorSet)) VkError!void {
    try self.vtable.freeDescriptorSets(self, sets);
}
