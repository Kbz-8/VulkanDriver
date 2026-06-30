const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .fence;

owner: *Device,
flags: vk.FenceCreateFlags,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
    getStatus: *const fn (*Self) VkError!void,
    reset: *const fn (*Self) VkError!void,
    signal: *const fn (*Self) VkError!void,
    wait: *const fn (*Self, u64) VkError!void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.FenceCreateInfo) VkError!Self {
    _ = allocator;
    return .{
        .owner = device,
        .flags = info.flags,
        .vtable = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}

pub inline fn getStatus(self: *Self) VkError!void {
    try self.vtable.getStatus(self);
}

pub inline fn reset(self: *Self) VkError!void {
    try self.vtable.reset(self);
}

pub inline fn signal(self: *Self) VkError!void {
    try self.vtable.signal(self);
}

pub inline fn wait(self: *Self, timeout: u64) VkError!void {
    try self.vtable.wait(self, timeout);
}

pub fn waitMany(device: *Device, fences: []const *Self, wait_for_all: vk.Bool32, timeout: u64) VkError!void {
    const forever = timeout == std.math.maxInt(@TypeOf(timeout));
    const io = device.io();
    const deadline = if (forever) null else std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromNanoseconds(@intCast(timeout)),
        .clock = .awake,
    });

    while (true) {
        var signaled_count: usize = 0;
        for (fences) |fence| {
            if (fence.owner != device) return VkError.InvalidHandleDrv;

            fence.getStatus() catch |err| switch (err) {
                VkError.NotReady => continue,
                else => return err,
            };

            if (wait_for_all == .false) return;
            signaled_count += 1;
        }

        if (signaled_count == fences.len) return;
        if (timeout == 0) return VkError.Timeout;

        const sleep_ns = if (deadline) |value| blk: {
            const remaining = value.durationFromNow(io);
            if (remaining.raw.nanoseconds <= 0) return VkError.Timeout;
            break :blk @min(remaining.raw.nanoseconds, std.time.ns_per_ms);
        } else std.time.ns_per_ms;

        (std.Io.Clock.Duration{
            .raw = .fromNanoseconds(sleep_ns),
            .clock = .awake,
        }).sleep(io) catch return VkError.DeviceLost;
    }
}
