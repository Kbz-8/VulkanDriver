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

pub inline fn getFormatPixelSize(format: vk.Format) usize {
    return lib.vku.vkuFormatTexelBlockSize(@intCast(@intFromEnum(format)));
}

pub inline fn getFormatTotalSize(self: *Self, format: vk.Format) usize {
    const pixel_size = self.getFormatPixelSize(format);
    return self.extent.width * self.extent.height * self.extent.depth * pixel_size;
}

pub fn formatSupportsColorAttachemendBlend(format: vk.Format) bool {
    return switch (format) {
        // Vulkan 1.1 mandatory
        .r5g6b5_unorm_pack16,
        .a1r5g5b5_unorm_pack16,
        .r8_unorm,
        .r8g8_unorm,
        .r8g8b8a8_unorm,
        .r8g8b8a8_srgb,
        .b8g8r8a8_unorm,
        .b8g8r8a8_srgb,
        .a8b8g8r8_unorm_pack32,
        .a8b8g8r8_srgb_pack32,
        .a2b10g10r10_unorm_pack32,
        .r16_sfloat,
        .r16g16_sfloat,
        .r16g16b16a16_sfloat,
        // optional
        .r4g4b4a4_unorm_pack16,
        .b4g4r4a4_unorm_pack16,
        .b5g6r5_unorm_pack16,
        .r5g5b5a1_unorm_pack16,
        .b5g5r5a1_unorm_pack16,
        .a2r10g10b10_unorm_pack32,
        .r16_unorm,
        .r16g16_unorm,
        .r16g16b16a16_unorm,
        .r32_sfloat,
        .r32g32_sfloat,
        .r32g32b32a32_sfloat,
        .b10g11r11_ufloat_pack32,
        .a4r4g4b4_unorm_pack16,
        .a4b4g4r4_unorm_pack16,
        => true,
        else => false,
    };
}

pub fn formatFromAspect(base_format: vk.Format, aspect: vk.ImageAspectFlags) vk.Format {
    if (aspect.color_bit or (aspect.color_bit and aspect.stencil_bit)) {
        return base_format;
    } else if (aspect.depth_bit) {
        if (base_format == .d16_unorm or base_format == .d16_unorm_s8_uint) {
            return .d16_unorm;
        } else if (base_format == .d24_unorm_s8_uint) {
            return .x8_d24_unorm_pack32;
        } else if (base_format == .d32_sfloat or base_format == .d32_sfloat_s8_uint) {
            return .d32_sfloat;
        }
    } else if (aspect.stencil_bit) {
        if (base_format == .s8_uint or base_format == .d16_unorm_s8_uint or base_format == .d24_unorm_s8_uint or base_format == .d32_sfloat_s8_uint) {
            return .s8_uint;
        }
    }
    lib.unsupported("format {d}", .{@intFromEnum(base_format)});
    return base_format;
}
