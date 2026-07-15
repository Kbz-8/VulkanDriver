const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;

const Device = @import("Device.zig");
const Buffer = @import("Buffer.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .buffer_view;

owner: *Device,
buffer: *Buffer,
format: vk.Format,
offset: vk.DeviceSize,
range: vk.DeviceSize,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.BufferViewCreateInfo) VkError!Self {
    _ = allocator;
    return .{
        .owner = device,
        .buffer = try NonDispatchable(Buffer).fromHandleObject(info.buffer),
        // SAFETY: the backend assigns the vtable before returning the buffer view.
        .vtable = undefined,
        .format = info.format,
        .offset = info.offset,
        .range = info.range,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}
