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
