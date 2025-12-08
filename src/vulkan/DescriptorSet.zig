const std = @import("std");
const vk = @import("vulkan");

const NonDispatchable = @import("NonDispatchable.zig");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");

const DescriptorSetLayout = @import("DescriptorSetLayout.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .descriptor_set;

owner: *Device,
layout: *DescriptorSetLayout,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, layout: *DescriptorSetLayout) VkError!Self {
    _ = allocator;
    return .{
        .owner = device,
        .layout = layout,
        .vtable = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.layouts);
    self.vtable.destroy(self, allocator);
}
