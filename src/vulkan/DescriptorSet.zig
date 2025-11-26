const std = @import("std");
const vk = @import("vulkan");

const NonDispatchable = @import("NonDispatchable.zig");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");

const DescriptorSetLayout = @import("DescriptorSetLayout.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .descriptor_set;

owner: *Device,
layouts: []*const DescriptorSetLayout,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.DescriptorSetAllocateInfo) VkError!Self {
    var layouts = allocator.alloc(*DescriptorSetLayout, info.descriptor_set_count) catch return VkError.OutOfHostMemory;
    errdefer allocator.free(layouts);

    for (info.p_set_layouts, 0..info.descriptor_set_count) |p_set_layout, i| {
        layouts[i] = try NonDispatchable(DescriptorSetLayout).fromHandleObject(p_set_layout);
    }

    return .{
        .owner = device,
        .layouts = layouts,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.layouts);
    self.vtable.destroy(self, allocator);
}
