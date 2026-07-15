const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .semaphore;

owner: *Device,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
    signal: *const fn (*Self) VkError!void,
    wait: *const fn (*Self) VkError!void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.SemaphoreCreateInfo) VkError!Self {
    _ = allocator;
    _ = info;
    return .{
        .owner = device,
        // SAFETY: the backend assigns the vtable before returning the semaphore.
        .vtable = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}

pub inline fn signal(self: *Self) VkError!void {
    try self.vtable.signal(self);
}

pub inline fn wait(self: *Self) VkError!void {
    try self.vtable.wait(self);
}
