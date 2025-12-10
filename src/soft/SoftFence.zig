const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;
const Device = base.Device;

const Self = @This();
pub const Interface = base.Fence;

interface: Interface,
mutex: std.Thread.Mutex,
condition: std.Thread.Condition,
is_signaled: std.atomic.Value(bool),

pub fn create(device: *Device, allocator: std.mem.Allocator, info: *const vk.FenceCreateInfo) VkError!*Self {
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
        .mutex = std.Thread.Mutex{},
        .condition = std.Thread.Condition{},
        .is_signaled = std.atomic.Value(bool).init(info.flags.signaled_bit),
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn getStatus(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    if (!self.is_signaled.load(.seq_cst)) {
        return VkError.NotReady;
    }
}

pub fn reset(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.is_signaled.store(false, .seq_cst);
}

pub fn signal(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.is_signaled.store(true, .seq_cst);
    self.condition.broadcast();
}

pub fn wait(interface: *Interface, timeout: u64) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    if (self.is_signaled.load(.seq_cst)) return;
    if (timeout == 0) return VkError.Timeout;

    self.mutex.lock();
    defer self.mutex.unlock();

    if (timeout == std.math.maxInt(@TypeOf(timeout))) {
        self.condition.wait(&self.mutex);
    } else {
        self.condition.timedWait(&self.mutex, timeout) catch return VkError.Timeout;
    }
}
