const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.BinarySemaphore;

interface: Interface,
mutex: std.Io.Mutex,
condition: std.Io.Condition,
is_signaled: bool,
is_failed: bool,

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
        .is_failed = false,
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

    if (self.is_failed) return VkError.DeviceLost;
    self.is_signaled = true;
    self.condition.broadcast(io);
}

/// Latch an asynchronous queue/device failure and wake all host waiters
pub fn fail(interface: *Interface) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const io = interface.owner.io();

    self.mutex.lock(io) catch return;
    defer self.mutex.unlock(io);

    self.is_failed = true;
    self.condition.broadcast(io);
}

pub fn wait(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const io = interface.owner.io();

    self.mutex.lock(io) catch return VkError.DeviceLost;
    defer self.mutex.unlock(io);

    while (!self.is_signaled and !self.is_failed) {
        self.condition.wait(io, &self.mutex) catch return VkError.DeviceLost;
    }
    if (self.is_failed) return VkError.DeviceLost;

    self.is_signaled = false;
}
