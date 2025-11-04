const std = @import("std");
const vk = @import("vulkan");
const Instance = @import("Instance.zig");
const base = @import("base");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Device;

interface: Interface,

pub fn create(physical_device: *base.PhysicalDevice, allocator: std.mem.Allocator, infos: *const vk.DeviceCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, physical_device, infos);

    interface.dispatch_table = &.{
        .destroy = destroy,
    };

    self.* = .{
        .interface = interface,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}
