const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .command_buffer;

owner: *Device,

vtable: *const VTable,
dispatch_table: *const DispatchTable,

pub const DispatchTable = struct {
    begin: *const fn (*Self, *const vk.CommandBufferBeginInfo) VkError!void,
    end: *const fn (*Self) VkError!void,
};

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.CommandBufferAllocateInfo) VkError!Self {
    _ = allocator;
    _ = info;
    return .{
        .owner = device,
        .vtable = undefined,
        .dispatch_table = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}

pub inline fn begin(self: *Self, info: *const vk.CommandBufferBeginInfo) VkError!void {
    try self.dispatch_table.begin(self, info);
}

pub inline fn end(self: *Self) VkError!void {
    try self.dispatch_table.end(self);
}
