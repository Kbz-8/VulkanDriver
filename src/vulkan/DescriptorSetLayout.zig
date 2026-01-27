const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .descriptor_set_layout;

owner: *Device,
bindings: ?[]const vk.DescriptorSetLayoutBinding,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.DescriptorSetLayoutCreateInfo) VkError!Self {
    const bindings = if (info.p_bindings) |bindings|
        allocator.dupe(vk.DescriptorSetLayoutBinding, bindings[0..info.binding_count]) catch return VkError.OutOfHostMemory
    else
        null;

    return .{
        .owner = device,
        .bindings = bindings,
        .vtable = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    if (self.bindings) |bindings| {
        allocator.free(bindings);
    }
    self.vtable.destroy(self, allocator);
}
