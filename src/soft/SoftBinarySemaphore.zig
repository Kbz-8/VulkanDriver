const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;
const Device = base.Device;

const Self = @This();
pub const Interface = base.BinarySemaphore;

interface: Interface,
mutex: std.Io.Mutex,
condition: std.Io.Condition,
is_signaled: bool,

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.SemaphoreCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);

    interface.vtable = &.{
        .destroy = destroy,
        .signal = signal,
        .wait = wait,
    };

    self.* = .{
        .interface = interface,
        .mutex = .init,
        .condition = .init,
        .is_signaled = false,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn signal(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const io = interface.owner.io();

    self.mutex.lock(io) catch return VkError.DeviceLost;
    defer self.mutex.unlock(io);

    self.is_signaled = true;
    self.condition.broadcast(io);
}

pub fn wait(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const io = interface.owner.io();

    self.mutex.lock(io) catch return VkError.DeviceLost;
    defer self.mutex.unlock(io);

    while (!self.is_signaled) {
        self.condition.wait(io, &self.mutex) catch return VkError.DeviceLost;
    }
    self.is_signaled = false;
}
