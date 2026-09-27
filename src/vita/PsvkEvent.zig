const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Event;

interface: Interface,

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.EventCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);

    interface.vtable = &.{
        .destroy = destroy,
        .getStatus = getStatus,
        .reset = reset,
        .signal = signal,
        .wait = wait,
    };

    self.* = .{
        .interface = interface,
    };

    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    allocator.destroy(self);
}

pub fn getStatus(_: *Interface) VkError!void {
    return;
}

pub fn reset(_: *Interface) VkError!void {
    return;
}

pub fn signal(_: *Interface) VkError!void {
    return;
}

pub fn wait(_: *Interface) VkError!void {
    return;
}
