const std = @import("std");
const vk = @import("vulkan");
const lib = @import("lib.zig");

pub fn fromAspect(format: vk.Format, aspect: vk.ImageAspectFlags) vk.Format {
    if (aspect.color_bit or (aspect.color_bit and aspect.stencil_bit)) {
        return format;
    } else if (aspect.depth_bit) {
        if (format == .d16_unorm or format == .d16_unorm_s8_uint) {
            return .d16_unorm;
        } else if (format == .d24_unorm_s8_uint) {
            return .x8_d24_unorm_pack32;
        } else if (format == .d32_sfloat or format == .d32_sfloat_s8_uint) {
            return .d32_sfloat;
        }
    } else if (aspect.stencil_bit) {
        if (format == .s8_uint or format == .d16_unorm_s8_uint or format == .d24_unorm_s8_uint or format == .d32_sfloat_s8_uint) {
            return .s8_uint;
        }
    }
    lib.unsupported("format {s}", .{@tagName(format)});
    return format;
}

pub fn toAspect(format: vk.Format) vk.ImageAspectFlags {
    var aspect: vk.ImageAspectFlags = .{};
    if (lib.vku.vkuFormatHasDepth(@intCast(@intFromEnum(format))))
        aspect.depth_bit = true;
    if (lib.vku.vkuFormatHasStencil(@intCast(@intFromEnum(format))))
        aspect.stencil_bit = true;

    if (aspect.toInt() == 0)
        aspect.color_bit = true;

    return aspect;
}

pub inline fn texelSize(format: vk.Format) usize {
    return lib.vku.vkuFormatTexelBlockSize(@intCast(@intFromEnum(format)));
}

pub inline fn supportsColorAttachemendBlend(format: vk.Format) bool {
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

pub inline fn pitchMemSize(format: vk.Format, width: usize) usize {
    // To be updated for compressed formats handling
    return texelSize(format) * width;
}

pub inline fn sliceMemSize(format: vk.Format, width: usize, height: usize) usize {
    // To be updated for compressed formats handling
    return pitchMemSize(format, width) * height;
}

pub inline fn isDepthAndStencil(format: vk.Format) bool {
    return lib.vku.vkuFormatIsDepthAndStencil(@intCast(@intFromEnum(format)));
}
