const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const Self = @This();
pub const ObjectType: vk.ObjectType = .device;

physical_device: *const PhysicalDevice,
dispatch_table: DispatchTable,
driver_data: ?*anyopaque,

pub const DispatchTable = struct {};

pub fn createImplDevice(physical_device: *base.PhysicalDevice, infos: vk.DeviceCreateInfo, allocator: std.mem.Allocator) !*anyopaque {
}
