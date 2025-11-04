const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const PhysicalDevice = @import("PhysicalDevice.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .device;

physical_device: *const PhysicalDevice,
dispatch_table: *const DispatchTable,

pub const DispatchTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) VkError!void,
};

pub fn init(allocator: std.mem.Allocator, physical_device: *const PhysicalDevice, infos: *const vk.DeviceCreateInfo) VkError!Self {
    _ = allocator;
    _ = infos;
    return .{
        .physical_device = physical_device,
        .dispatch_table = undefined,
    };
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) VkError!void {
    try self.dispatch_table.destroy(self, allocator);
}
