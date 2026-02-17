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
    copy: *const fn (*Self, vk.CopyDescriptorSet) VkError!void,
    destroy: *const fn (*Self, std.mem.Allocator) void,
    write: *const fn (*Self, vk.WriteDescriptorSet) VkError!void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, layout: *DescriptorSetLayout) VkError!Self {
    _ = allocator;
    layout.ref();
    return .{
        .owner = device,
        .layout = layout,
        .vtable = undefined,
    };
}
pub inline fn copy(self: *Self, copy_data: vk.CopyDescriptorSet) VkError!void {
    try self.vtable.copy(self, copy_data);
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.layout.unref(allocator);
    self.vtable.destroy(self, allocator);
}

pub inline fn write(self: *Self, write_data: vk.WriteDescriptorSet) VkError!void {
    try self.vtable.write(self, write_data);
}
