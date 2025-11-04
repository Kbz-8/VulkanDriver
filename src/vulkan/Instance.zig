const std = @import("std");
const vk = @import("vulkan");
const VkError = @import("error_set.zig").VkError;
const Dispatchable = @import("Dispatchable.zig").Dispatchable;
const PhysicalDevice = @import("PhysicalDevice.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .instance;

physical_devices: std.ArrayList(*Dispatchable(PhysicalDevice)),
dispatch_table: *const DispatchTable,

pub const DispatchTable = struct {
    requestPhysicalDevices: *const fn (*Self, std.mem.Allocator) VkError!void,
    releasePhysicalDevices: *const fn (*Self, std.mem.Allocator) VkError!void,
    destroyInstance: *const fn (*Self, std.mem.Allocator) VkError!void,
};

pub fn init(allocator: std.mem.Allocator, infos: *const vk.InstanceCreateInfo) VkError!Self {
    _ = allocator;
    _ = infos;
    return .{
        .physical_devices = .empty,
        .dispatch_table = undefined,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) VkError!void {
    try self.dispatch_table.releasePhysicalDevices(self, allocator);
    try self.dispatch_table.destroyInstance(self, allocator);
}
