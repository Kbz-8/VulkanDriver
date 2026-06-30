const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;
const Device = base.Device;

const Self = @This();
pub const Interface = base.Fence;

interface: Interface,
mutex: std.Io.Mutex,
condition: std.Io.Condition,
is_signaled: bool,

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
        .mutex = .init,
        .condition = .init,
        .is_signaled = info.flags.signaled_bit,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn getStatus(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const io = interface.owner.io();

    self.mutex.lock(io) catch return VkError.DeviceLost;
    defer self.mutex.unlock(io);

    if (!self.is_signaled) {
        return VkError.NotReady;
    }
}

pub fn reset(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const io = interface.owner.io();

    self.mutex.lock(io) catch return VkError.DeviceLost;
    defer self.mutex.unlock(io);

    self.is_signaled = false;
}

pub fn signal(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const io = interface.owner.io();

    self.mutex.lock(io) catch return VkError.DeviceLost;
    defer self.mutex.unlock(io);

    self.is_signaled = true;
    self.condition.broadcast(io);
}

pub fn wait(interface: *Interface, timeout: u64) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const io = interface.owner.io();

    if (timeout == std.math.maxInt(@TypeOf(timeout))) {
        self.mutex.lock(io) catch return VkError.DeviceLost;
        defer self.mutex.unlock(io);

        while (!self.is_signaled) {
            self.condition.wait(io, &self.mutex) catch return VkError.DeviceLost;
        }
        return;
    }

    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromNanoseconds(@intCast(timeout)),
        .clock = .awake,
    });
    while (true) {
        {
            self.mutex.lock(io) catch return VkError.DeviceLost;
            defer self.mutex.unlock(io);

            if (self.is_signaled) return;
        }

        const remaining = deadline.durationFromNow(io);
        if (remaining.raw.nanoseconds <= 0) return VkError.Timeout;

        (std.Io.Clock.Duration{
            .raw = .fromNanoseconds(@min(remaining.raw.nanoseconds, std.time.ns_per_ms)),
            .clock = .awake,
        }).sleep(io) catch return VkError.DeviceLost;
    }
}
