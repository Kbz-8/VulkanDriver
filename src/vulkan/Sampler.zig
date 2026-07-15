const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .sampler;

owner: *Device,
mag_filter: vk.Filter,
min_filter: vk.Filter,
mipmap_mode: vk.SamplerMipmapMode,
address_mode_u: vk.SamplerAddressMode,
address_mode_v: vk.SamplerAddressMode,
address_mode_w: vk.SamplerAddressMode,
mip_lod_bias: f32,
compare_enable: vk.Bool32,
compare_op: vk.CompareOp,
min_lod: f32,
max_lod: f32,
border_color: vk.BorderColor,
unnormalized_coordinates: vk.Bool32,

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
        .mipmap_mode = info.mipmap_mode,
        .address_mode_u = info.address_mode_u,
        .address_mode_v = info.address_mode_v,
        .address_mode_w = info.address_mode_w,
        .mip_lod_bias = info.mip_lod_bias,
        .compare_enable = info.compare_enable,
        .compare_op = info.compare_op,
        .min_lod = info.min_lod,
        .max_lod = info.max_lod,
        .border_color = info.border_color,
        .unnormalized_coordinates = info.unnormalized_coordinates,
        // SAFETY: the backend assigns the vtable before returning the sampler.
        .vtable = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}
