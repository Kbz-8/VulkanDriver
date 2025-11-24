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
tiling: vk.ImageTiling,
usage: vk.ImageUsageFlags,
memory: ?*DeviceMemory,
memory_offset: vk.DeviceSize,
allowed_memory_types: std.bit_set.IntegerBitSet(32),

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
    getMemoryRequirements: *const fn (*Self, *vk.MemoryRequirements) void,
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
        .tiling = info.tiling,
        .usage = info.usage,
        .memory = null,
        .memory_offset = 0,
        .allowed_memory_types = std.bit_set.IntegerBitSet(32).initFull(),
        .vtable = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}

pub inline fn bindMemory(self: *Self, memory: *DeviceMemory, offset: vk.DeviceSize) VkError!void {
    const image_size = self.getTotalSize();
    if (offset >= image_size or !self.allowed_memory_types.isSet(memory.memory_type_index)) {
        return VkError.ValidationFailed;
    }
    self.memory = memory;
    self.memory_offset = offset;
}

pub inline fn getMemoryRequirements(self: *Self, requirements: *vk.MemoryRequirements) void {
    const image_size = self.getTotalSize();
    requirements.size = image_size;
    requirements.memory_type_bits = self.allowed_memory_types.mask;
    self.vtable.getMemoryRequirements(self, requirements);
}

pub inline fn getClearFormat(self: *Self) vk.Format {
    return if (lib.vku.vkuFormatIsSINT(@intCast(@intFromEnum(self.format))))
        .r32g32b32a32_sint
    else if (lib.vku.vkuFormatIsUINT(@intCast(@intFromEnum(self.format))))
        .r32g32b32a32_uint
    else
        .r32g32b32a32_sfloat;
}

pub inline fn getPixelSize(self: *Self) usize {
    return lib.vku.vkuFormatTexelBlockSize(@intCast(@intFromEnum(self.format)));
}

pub inline fn getTotalSize(self: *Self) usize {
    const pixel_size = self.getPixelSize();
    return self.extent.width * self.extent.height * self.extent.depth * pixel_size;
}
