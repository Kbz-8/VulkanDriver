const std = @import("std");
const vk = @import("vulkan");
const lib = @import("lib.zig");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");

const DeviceMemory = @import("DeviceMemory.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .image;

owner: *Device,
image_type: vk.ImageType,
format: vk.Format,
extent: vk.Extent3D,
mip_levels: u32,
array_layers: u32,
samples: vk.SampleCountFlags,
flags: vk.ImageCreateFlags,
tiling: vk.ImageTiling,
usage: vk.ImageUsageFlags,
memory: ?*DeviceMemory,
memory_offset: vk.DeviceSize,
allowed_memory_types: std.bit_set.IntegerBitSet(32),

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
    getMemoryRequirements: *const fn (*Self, *vk.MemoryRequirements) VkError!void,
    getSubresourceLayout: *const fn (*const Self, vk.ImageSubresource) VkError!vk.SubresourceLayout,
    getTotalSizeForAspect: *const fn (*const Self, vk.ImageAspectFlags) VkError!usize,
    getSliceMemSizeForMipLevel: *const fn (*const Self, vk.ImageAspectFlags, u32) usize,
    getRowPitchMemSizeForMipLevel: *const fn (*const Self, vk.ImageAspectFlags, u32) usize,
    copyToMemory: *const fn (*const Self, []u8, vk.ImageSubresourceLayers) VkError!void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.ImageCreateInfo) VkError!Self {
    _ = allocator;
    return .{
        .owner = device,
        .image_type = info.image_type,
        .format = info.format,
        .extent = info.extent,
        .mip_levels = info.mip_levels,
        .array_layers = info.array_layers,
        .samples = info.samples,
        .flags = info.flags,
        .tiling = info.tiling,
        .usage = info.usage,
        .memory = null,
        .memory_offset = 0,
        .allowed_memory_types = std.bit_set.IntegerBitSet(32).initFull(),
        // SAFETY: the backend assigns the vtable before returning the image.
        .vtable = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}

pub fn bindMemory(self: *Self, memory: *DeviceMemory, offset: vk.DeviceSize) VkError!void {
    const image_size = try self.getTotalSize();
    if (offset > memory.size or image_size > memory.size - offset or !self.allowed_memory_types.isSet(memory.memory_type_index)) {
        return VkError.ValidationFailed;
    }
    self.memory = memory;
    self.memory_offset = offset;
}

pub fn getMemoryRequirements(self: *Self, requirements: *vk.MemoryRequirements) VkError!void {
    requirements.size = try self.getTotalSize();
    requirements.memory_type_bits = self.allowed_memory_types.mask;
    try self.vtable.getMemoryRequirements(self, requirements);
}

pub fn getSliceMemSizeForMipLevel(self: *const Self, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    return self.vtable.getSliceMemSizeForMipLevel(self, aspect_mask, mip_level);
}

pub fn getRowPitchMemSizeForMipLevel(self: *const Self, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    return self.vtable.getRowPitchMemSizeForMipLevel(self, aspect_mask, mip_level);
}

pub inline fn copyToMemory(self: *const Self, memory: []u8, subresource: vk.ImageSubresourceLayers) VkError!void {
    try self.vtable.copyToMemory(self, memory, subresource);
}

pub inline fn getTexelSize(self: *const Self) usize {
    return lib.format.texelSize(self.format);
}

pub inline fn getTotalSizeForAspect(self: *const Self, aspect: vk.ImageAspectFlags) VkError!usize {
    return self.vtable.getTotalSizeForAspect(self, aspect);
}

pub inline fn getTotalSize(self: *const Self) VkError!usize {
    return self.vtable.getTotalSizeForAspect(self, lib.format.toAspect(self.format));
}

pub inline fn formatFromAspect(self: *const Self, aspect_mask: vk.ImageAspectFlags) vk.Format {
    return lib.format.fromAspect(self.format, aspect_mask);
}

pub inline fn formatToAspect(self: *const Self, aspect_mask: vk.ImageAspectFlags) vk.ImageAspectFlags {
    return lib.format.toAspect(self.format, aspect_mask);
}

pub fn getLastLayerIndex(self: *const Self, range: vk.ImageSubresourceRange) u32 {
    return (if (range.layer_count == vk.REMAINING_ARRAY_LAYERS) self.array_layers else range.base_array_layer + range.layer_count) - 1;
}

pub fn getLastMipLevel(self: *const Self, range: vk.ImageSubresourceRange) u32 {
    return (if (range.level_count == vk.REMAINING_MIP_LEVELS) self.mip_levels else range.base_mip_level + range.level_count) - 1;
}

pub inline fn getSubresourceLayout(self: *const Self, subresource: vk.ImageSubresource) VkError!vk.SubresourceLayout {
    return self.vtable.getSubresourceLayout(self, subresource);
}
