const std = @import("std");
const vk = @import("vulkan");

const NonDispatchable = @import("NonDispatchable.zig");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .sampler;

owner: *Device,
mag_filter: vk.Filter,
min_filter: vk.Filter,
address_mode_u: vk.SamplerAddressMode,
address_mode_v: vk.SamplerAddressMode,
address_mode_w: vk.SamplerAddressMode,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.SamplerCreateInfo) VkError!Self {
    _ = allocator;
    return .{
        .owner = device,
        .mag_filter = info.mag_filter,
        .min_filter = info.min_filter,
        .address_mode_u = info.address_mode_u,
        .address_mode_v = info.address_mode_v,
        .address_mode_w = info.address_mode_w,
        .vtable = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}
