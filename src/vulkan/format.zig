const std = @import("std");
const vk = @import("vulkan");
const lib = @import("lib.zig");
const zm = @import("zmath");

pub fn fromAspect(format: vk.Format, aspect: vk.ImageAspectFlags) vk.Format {
    if (aspect.color_bit or (aspect.depth_bit and aspect.stencil_bit)) {
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
    return .undefined;
}

pub fn toAspect(format: vk.Format) vk.ImageAspectFlags {
    var aspect: vk.ImageAspectFlags = .{};
    if (lib.c.vkuFormatHasDepth(@intCast(@intFromEnum(format))))
        aspect.depth_bit = true;
    if (lib.c.vkuFormatHasStencil(@intCast(@intFromEnum(format))))
        aspect.stencil_bit = true;

    if (aspect.toInt() == 0)
        aspect.color_bit = true;

    return aspect;
}

pub inline fn texelSize(format: vk.Format) usize {
    return lib.c.vkuFormatTexelBlockSize(@intCast(@intFromEnum(format)));
}

pub inline fn isCompressed(format: vk.Format) bool {
    return blockWidth(format) > 1 or blockHeight(format) > 1;
}

pub inline fn blockWidth(format: vk.Format) usize {
    return switch (format) {
        .bc1_rgb_unorm_block,
        .bc1_rgb_srgb_block,
        .bc1_rgba_unorm_block,
        .bc1_rgba_srgb_block,
        .bc2_unorm_block,
        .bc2_srgb_block,
        .bc3_unorm_block,
        .bc3_srgb_block,
        .bc4_unorm_block,
        .bc4_snorm_block,
        .bc5_unorm_block,
        .bc5_snorm_block,
        .bc6h_ufloat_block,
        .bc6h_sfloat_block,
        .bc7_unorm_block,
        .bc7_srgb_block,
        .eac_r11_unorm_block,
        .eac_r11_snorm_block,
        .eac_r11g11_unorm_block,
        .eac_r11g11_snorm_block,
        .etc2_r8g8b8_unorm_block,
        .etc2_r8g8b8_srgb_block,
        .etc2_r8g8b8a1_unorm_block,
        .etc2_r8g8b8a1_srgb_block,
        .etc2_r8g8b8a8_unorm_block,
        .etc2_r8g8b8a8_srgb_block,
        .astc_4x_4_unorm_block,
        .astc_4x_4_srgb_block,
        => 4,
        .astc_5x_4_unorm_block,
        .astc_5x_5_unorm_block,
        .astc_5x_4_srgb_block,
        .astc_5x_5_srgb_block,
        => 5,
        .astc_6x_5_unorm_block,
        .astc_6x_6_unorm_block,
        .astc_6x_5_srgb_block,
        .astc_6x_6_srgb_block,
        => 6,
        .astc_8x_5_unorm_block,
        .astc_8x_6_unorm_block,
        .astc_8x_8_unorm_block,
        .astc_8x_5_srgb_block,
        .astc_8x_6_srgb_block,
        .astc_8x_8_srgb_block,
        => 8,
        .astc_1_0x_5_unorm_block,
        .astc_1_0x_6_unorm_block,
        .astc_1_0x_8_unorm_block,
        .astc_1_0x_10_unorm_block,
        .astc_1_0x_5_srgb_block,
        .astc_1_0x_6_srgb_block,
        .astc_1_0x_8_srgb_block,
        .astc_1_0x_10_srgb_block,
        => 10,
        .astc_1_2x_10_unorm_block,
        .astc_1_2x_12_unorm_block,
        .astc_1_2x_10_srgb_block,
        .astc_1_2x_12_srgb_block,
        => 12,
        else => 1,
    };
}

pub inline fn blockHeight(format: vk.Format) usize {
    return switch (format) {
        .bc1_rgb_unorm_block,
        .bc1_rgb_srgb_block,
        .bc1_rgba_unorm_block,
        .bc1_rgba_srgb_block,
        .bc2_unorm_block,
        .bc2_srgb_block,
        .bc3_unorm_block,
        .bc3_srgb_block,
        .bc4_unorm_block,
        .bc4_snorm_block,
        .bc5_unorm_block,
        .bc5_snorm_block,
        .bc6h_ufloat_block,
        .bc6h_sfloat_block,
        .bc7_unorm_block,
        .bc7_srgb_block,
        .eac_r11_unorm_block,
        .eac_r11_snorm_block,
        .eac_r11g11_unorm_block,
        .eac_r11g11_snorm_block,
        .etc2_r8g8b8_unorm_block,
        .etc2_r8g8b8_srgb_block,
        .etc2_r8g8b8a1_unorm_block,
        .etc2_r8g8b8a1_srgb_block,
        .etc2_r8g8b8a8_unorm_block,
        .etc2_r8g8b8a8_srgb_block,
        .astc_4x_4_unorm_block,
        .astc_5x_4_unorm_block,
        .astc_4x_4_srgb_block,
        .astc_5x_4_srgb_block,
        => 4,
        .astc_5x_5_unorm_block,
        .astc_6x_5_unorm_block,
        .astc_8x_5_unorm_block,
        .astc_1_0x_5_unorm_block,
        .astc_5x_5_srgb_block,
        .astc_6x_5_srgb_block,
        .astc_8x_5_srgb_block,
        .astc_1_0x_5_srgb_block,
        => 5,
        .astc_6x_6_unorm_block,
        .astc_8x_6_unorm_block,
        .astc_1_0x_6_unorm_block,
        .astc_6x_6_srgb_block,
        .astc_8x_6_srgb_block,
        .astc_1_0x_6_srgb_block,
        => 6,
        .astc_8x_8_unorm_block,
        .astc_1_0x_8_unorm_block,
        .astc_8x_8_srgb_block,
        .astc_1_0x_8_srgb_block,
        => 8,
        .astc_1_0x_10_unorm_block,
        .astc_1_2x_10_unorm_block,
        .astc_1_0x_10_srgb_block,
        .astc_1_2x_10_srgb_block,
        => 10,
        .astc_1_2x_12_unorm_block,
        .astc_1_2x_12_srgb_block,
        => 12,
        else => 1,
    };
}

pub inline fn blockCountX(format: vk.Format, width: usize) usize {
    return std.math.divCeil(usize, width, blockWidth(format)) catch @panic("Division failed");
}

pub inline fn blockCountY(format: vk.Format, height: usize) usize {
    return std.math.divCeil(usize, height, blockHeight(format)) catch @panic("Division failed");
}

pub inline fn componentCount(format: vk.Format) usize {
    return @intCast(lib.c.vkuFormatComponentCount(@intCast(@intFromEnum(format))));
}

pub fn supportsColorAttachemendBlend(format: vk.Format) bool {
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
    return texelSize(format) * blockCountX(format, width);
}

pub inline fn sliceMemSize(format: vk.Format, width: usize, height: usize) usize {
    return pitchMemSize(format, width) * blockCountY(format, height);
}

pub inline fn isDepthAndStencil(format: vk.Format) bool {
    return lib.c.vkuFormatIsDepthAndStencil(@intCast(@intFromEnum(format)));
}

pub inline fn isDepth(format: vk.Format) bool {
    return lib.c.vkuFormatHasDepth(@intCast(@intFromEnum(format)));
}

pub inline fn isStencil(format: vk.Format) bool {
    return lib.c.vkuFormatHasStencil(@intCast(@intFromEnum(format)));
}

pub inline fn isSrgb(format: vk.Format) bool {
    return lib.c.vkuFormatIsSRGB(@intCast(@intFromEnum(format)));
}

pub inline fn isSfloat(format: vk.Format) bool {
    return lib.c.vkuFormatIsSFLOAT(@intCast(@intFromEnum(format)));
}

pub inline fn isSint(format: vk.Format) bool {
    return lib.c.vkuFormatIsSINT(@intCast(@intFromEnum(format)));
}

pub inline fn isSnorm(format: vk.Format) bool {
    return lib.c.vkuFormatIsSNORM(@intCast(@intFromEnum(format)));
}

pub inline fn isUfloat(format: vk.Format) bool {
    return lib.c.vkuFormatIsUFLOAT(@intCast(@intFromEnum(format)));
}

pub inline fn isUint(format: vk.Format) bool {
    return lib.c.vkuFormatIsUINT(@intCast(@intFromEnum(format)));
}

pub inline fn isUnorm(format: vk.Format) bool {
    return lib.c.vkuFormatIsUNORM(@intCast(@intFromEnum(format)));
}

pub inline fn isFloat(format: vk.Format) bool {
    return isSfloat(format) or isUfloat(format);
}

pub fn getScale(format: vk.Format) zm.F32x4 {
    return switch (format) {
        .r4g4_unorm_pack8,
        .r4g4b4a4_unorm_pack16,
        .b4g4r4a4_unorm_pack16,
        .a4r4g4b4_unorm_pack16,
        .a4b4g4r4_unorm_pack16,
        => zm.f32x4(0xf, 0xf, 0xf, 0xf),
        .r8_unorm,
        .r8g8_unorm,
        .a8b8g8r8_unorm_pack32,
        .r8g8b8a8_unorm,
        .b8g8r8a8_unorm,
        .r8_srgb,
        .r8g8_srgb,
        .a8b8g8r8_srgb_pack32,
        .r8g8b8a8_srgb,
        .b8g8r8a8_srgb,
        => zm.f32x4(0xff, 0xff, 0xff, 0xff),
        .r8_snorm,
        .r8g8_snorm,
        .a8b8g8r8_snorm_pack32,
        .r8g8b8a8_snorm,
        .b8g8r8a8_snorm,
        => zm.f32x4(0x7f, 0x7f, 0x7f, 0x7f),
        .r16_unorm,
        .r16g16_unorm,
        .r16g16b16_unorm,
        .r16g16b16a16_unorm,
        => zm.f32x4(0xffff, 0xffff, 0xffff, 0xffff),
        .r16_snorm,
        .r16g16_snorm,
        .r16g16b16_snorm,
        .r16g16b16a16_snorm,
        => zm.f32x4(0x7fff, 0x7fff, 0x7fff, 0x7fff),
        .r8_sint,
        .r8_uint,
        .r8g8_sint,
        .r8g8_uint,
        .r8g8b8a8_sint,
        .r8g8b8a8_uint,
        .a8b8g8r8_sint_pack32,
        .a8b8g8r8_uint_pack32,
        .b8g8r8a8_sint,
        .b8g8r8a8_uint,
        .r8_uscaled,
        .r8g8_uscaled,
        .r8g8b8a8_uscaled,
        .b8g8r8a8_uscaled,
        .a8b8g8r8_uscaled_pack32,
        .r8_sscaled,
        .r8g8_sscaled,
        .r8g8b8a8_sscaled,
        .b8g8r8a8_sscaled,
        .a8b8g8r8_sscaled_pack32,
        .r16_sint,
        .r16_uint,
        .r16g16_sint,
        .r16g16_uint,
        .r16g16b16a16_sint,
        .r16g16b16a16_uint,
        .r16_sscaled,
        .r16g16_sscaled,
        .r16g16b16_sscaled,
        .r16g16b16a16_sscaled,
        .r16_uscaled,
        .r16g16_uscaled,
        .r16g16b16_uscaled,
        .r16g16b16a16_uscaled,
        .r32_sint,
        .r32_uint,
        .r32g32_sint,
        .r32g32_uint,
        .r32g32b32_sint,
        .r32g32b32_uint,
        .r32g32b32a32_sint,
        .r32g32b32a32_uint,
        .r32g32b32a32_sfloat,
        .r32g32b32_sfloat,
        .r32g32_sfloat,
        .r32_sfloat,
        .r16g16b16a16_sfloat,
        .r16g16b16_sfloat,
        .r16g16_sfloat,
        .r16_sfloat,
        .b10g11r11_ufloat_pack32,
        .e5b9g9r9_ufloat_pack32,
        .a2r10g10b10_uscaled_pack32,
        .a2r10g10b10_sscaled_pack32,
        .a2r10g10b10_uint_pack32,
        .a2r10g10b10_sint_pack32,
        .a2b10g10r10_uscaled_pack32,
        .a2b10g10r10_sscaled_pack32,
        .a2b10g10r10_uint_pack32,
        .a2b10g10r10_sint_pack32,
        => zm.f32x4(1.0, 1.0, 1.0, 1.0),
        .r5g5b5a1_unorm_pack16,
        .b5g5r5a1_unorm_pack16,
        .a1r5g5b5_unorm_pack16,
        => zm.f32x4(0x1f, 0x1f, 0x1f, 0x01),
        .r5g6b5_unorm_pack16,
        .b5g6r5_unorm_pack16,
        => zm.f32x4(0x1f, 0x3f, 0x1f, 1.0),
        .a2r10g10b10_unorm_pack32,
        .a2b10g10r10_unorm_pack32,
        => zm.f32x4(0x3ff, 0x3ff, 0x3ff, 0x03),
        .a2r10g10b10_snorm_pack32,
        .a2b10g10r10_snorm_pack32,
        => zm.f32x4(0x1ff, 0x1ff, 0x1ff, 0x01),
        .d16_unorm,
        => zm.f32x4(0xffff, 0.0, 0.0, 0.0),
        .d24_unorm_s8_uint,
        .x8_d24_unorm_pack32,
        => zm.f32x4(0xffffff, 0.0, 0.0, 0.0),
        .d32_sfloat,
        .d32_sfloat_s8_uint,
        .s8_uint,
        => zm.f32x4(1.0, 1.0, 1.0, 1.0),
        else => blk: {
            lib.unsupported("format scale {any}", .{format});
            break :blk zm.f32x4s(1.0);
        },
    };
}

pub fn isUnsignedComponent(format: vk.Format, component: usize) bool {
    return switch (format) {
        .undefined,
        .r4g4_unorm_pack8,
        .r4g4b4a4_unorm_pack16,
        .b4g4r4a4_unorm_pack16,
        .a4r4g4b4_unorm_pack16,
        .a4b4g4r4_unorm_pack16,
        .r5g6b5_unorm_pack16,
        .b5g6r5_unorm_pack16,
        .r5g5b5a1_unorm_pack16,
        .b5g5r5a1_unorm_pack16,
        .a1r5g5b5_unorm_pack16,
        .r8_unorm,
        .r8_uint,
        .r8_srgb,
        .r8g8_unorm,
        .r8g8_uscaled,
        .r8g8_uint,
        .r8g8_srgb,
        .r8g8b8a8_unorm,
        .r8g8b8a8_uscaled,
        .r8g8b8a8_uint,
        .r8g8b8a8_srgb,
        .b8g8r8a8_unorm,
        .b8g8r8a8_uscaled,
        .b8g8r8a8_uint,
        .b8g8r8a8_srgb,
        .a8b8g8r8_unorm_pack32,
        .a8b8g8r8_uscaled_pack32,
        .a8b8g8r8_uint_pack32,
        .a8b8g8r8_srgb_pack32,
        .a2r10g10b10_unorm_pack32,
        .a2r10g10b10_uscaled_pack32,
        .a2r10g10b10_uint_pack32,
        .a2b10g10r10_unorm_pack32,
        .a2b10g10r10_uscaled_pack32,
        .a2b10g10r10_uint_pack32,
        .r16_unorm,
        .r16_uscaled,
        .r16_uint,
        .r16g16_unorm,
        .r16g16_uscaled,
        .r16g16_uint,
        .r16g16b16_unorm,
        .r16g16b16_uscaled,
        .r16g16b16_uint,
        .r16g16b16a16_unorm,
        .r16g16b16a16_uscaled,
        .r16g16b16a16_uint,
        .r32_uint,
        .r32g32_uint,
        .r32g32b32_uint,
        .r32g32b32a32_uint,
        .r64_uint,
        .r64g64_uint,
        .r64g64b64_uint,
        .r64g64b64a64_uint,
        .b10g11r11_ufloat_pack32,
        .e5b9g9r9_ufloat_pack32,
        .d16_unorm,
        .x8_d24_unorm_pack32,
        .s8_uint,
        .d16_unorm_s8_uint,
        .d24_unorm_s8_uint,
        .d32_sfloat,
        .d32_sfloat_s8_uint,
        .bc1_rgb_unorm_block,
        .bc1_rgb_srgb_block,
        .bc1_rgba_unorm_block,
        .bc1_rgba_srgb_block,
        .bc2_unorm_block,
        .bc2_srgb_block,
        .bc3_unorm_block,
        .bc3_srgb_block,
        .bc4_unorm_block,
        .bc5_unorm_block,
        .bc6h_ufloat_block,
        .bc7_unorm_block,
        .bc7_srgb_block,
        .eac_r11_unorm_block,
        .eac_r11g11_unorm_block,
        .etc2_r8g8b8_unorm_block,
        .etc2_r8g8b8_srgb_block,
        .etc2_r8g8b8a1_unorm_block,
        .etc2_r8g8b8a1_srgb_block,
        .etc2_r8g8b8a8_unorm_block,
        .etc2_r8g8b8a8_srgb_block,
        => true,
        .r8g8b8a8_snorm,
        .r8g8b8a8_sscaled,
        .r8g8b8a8_sint,
        .b8g8r8a8_snorm,
        .b8g8r8a8_sscaled,
        .b8g8r8a8_sint,
        .a8b8g8r8_snorm_pack32,
        .a8b8g8r8_sscaled_pack32,
        .a8b8g8r8_sint_pack32,
        .a2r10g10b10_snorm_pack32,
        .a2r10g10b10_sscaled_pack32,
        .a2r10g10b10_sint_pack32,
        .a2b10g10r10_snorm_pack32,
        .a2b10g10r10_sscaled_pack32,
        .a2b10g10r10_sint_pack32,
        .r16g16b16a16_snorm,
        .r16g16b16a16_sscaled,
        .r16g16b16a16_sint,
        .r16g16b16a16_sfloat,
        .r32g32b32a32_sint,
        .r32g32b32a32_sfloat,
        .r64g64b64a64_sint,
        .r64g64b64a64_sfloat,
        .bc4_snorm_block,
        .bc5_snorm_block,
        .bc6h_sfloat_block,
        .eac_r11_snorm_block,
        .eac_r11g11_snorm_block,
        .g8_b8_r8_3plane_420_unorm,
        .g8_b8r8_2plane_420_unorm,
        .g10x6_b10x6r10x6_2plane_420_unorm_3pack16,
        => false,
        .r8_snorm,
        .r8_uscaled,
        .r8_sscaled,
        .r8_sint,
        .r16_snorm,
        .r16_sscaled,
        .r16_sint,
        .r16_sfloat,
        .r32_sint,
        .r32_sfloat,
        .r64_sint,
        .r64_sfloat,
        => component >= 1,
        .r8g8_snorm,
        .r8g8_sscaled,
        .r8g8_sint,
        .r16g16_snorm,
        .r16g16_sscaled,
        .r16g16_sint,
        .r16g16_sfloat,
        .r32g32_sint,
        .r32g32_sfloat,
        .r64g64_sint,
        .r64g64_sfloat,
        => component >= 2,
        .r16g16b16_snorm,
        .r16g16b16_sscaled,
        .r16g16b16_sint,
        .r16g16b16_sfloat,
        .r32g32b32_sint,
        .r32g32b32_sfloat,
        .r64g64b64_sint,
        .r64g64b64_sfloat,
        => component >= 3,

        else => blk: {
            lib.unsupported("Format unsigned component {any}", .{format});
            break :blk false;
        },
    };
}

pub inline fn isUnsigned(format: vk.Format) bool {
    return isUnsignedComponent(format, 0);
}

pub inline fn isUnnormalizedInteger(format: vk.Format) bool {
    return isSint(format) or isUint(format);
}

pub inline fn isSscaled(format: vk.Format) bool {
    return lib.c.vkuFormatIsSSCALED(@intCast(@intFromEnum(format)));
}

pub inline fn isUscaled(format: vk.Format) bool {
    return lib.c.vkuFormatIsUSCALED(@intCast(@intFromEnum(format)));
}

fn maxComponentBits(format: vk.Format) u32 {
    if (lib.c.vkuFormatHasComponentSize(@intCast(@intFromEnum(format)), 64)) return 64;
    if (lib.c.vkuFormatHasComponentSize(@intCast(@intFromEnum(format)), 32)) return 32;
    if (lib.c.vkuFormatHasComponentSize(@intCast(@intFromEnum(format)), 24)) return 24;
    if (lib.c.vkuFormatHasComponentSize(@intCast(@intFromEnum(format)), 16)) return 16;
    if (lib.c.vkuFormatHasComponentSize(@intCast(@intFromEnum(format)), 11)) return 11;
    if (lib.c.vkuFormatHasComponentSize(@intCast(@intFromEnum(format)), 10)) return 10;
    if (lib.c.vkuFormatHasComponentSize(@intCast(@intFromEnum(format)), 8)) return 8;
    if (lib.c.vkuFormatHasComponentSize(@intCast(@intFromEnum(format)), 6)) return 6;
    if (lib.c.vkuFormatHasComponentSize(@intCast(@intFromEnum(format)), 5)) return 5;
    if (lib.c.vkuFormatHasComponentSize(@intCast(@intFromEnum(format)), 4)) return 4;
    if (lib.c.vkuFormatHasComponentSize(@intCast(@intFromEnum(format)), 2)) return 2;
    if (lib.c.vkuFormatHasComponentSize(@intCast(@intFromEnum(format)), 1)) return 1;

    lib.unsupported("format component bits {any}", .{format});
    return 0;
}

fn maxUnsignedValue(bits: u32) f32 {
    return switch (bits) {
        1 => 1.0,
        2 => 3.0,
        4 => 15.0,
        5 => 31.0,
        6 => 63.0,
        8 => @as(f32, @floatFromInt(std.math.maxInt(u8))),
        10 => 1023.0,
        11 => 2047.0,
        16 => @as(f32, @floatFromInt(std.math.maxInt(u16))),
        24 => 0xffffff,
        32 => @as(f32, @floatFromInt(std.math.maxInt(u32))),
        64 => @as(f32, @floatFromInt(std.math.maxInt(u64))),
        else => blk: {
            lib.unsupported("format component bits {d}", .{bits});
            break :blk 1.0;
        },
    };
}

fn maxSignedValue(bits: u32) f32 {
    return switch (bits) {
        2 => 1.0,
        4 => 7.0,
        5 => 15.0,
        6 => 31.0,
        8 => @as(f32, @floatFromInt(std.math.maxInt(i8))),
        10 => 511.0,
        11 => 1023.0,
        16 => @as(f32, @floatFromInt(std.math.maxInt(i16))),
        24 => 0x7fffff,
        32 => @as(f32, @floatFromInt(std.math.maxInt(i32))),
        64 => @as(f32, @floatFromInt(std.math.maxInt(i64))),
        else => blk: {
            lib.unsupported("format component bits {d}", .{bits});
            break :blk 1.0;
        },
    };
}

fn minSignedValue(bits: u32) f32 {
    return switch (bits) {
        2 => -2.0,
        4 => -8.0,
        5 => -16.0,
        6 => -32.0,
        8 => @as(f32, @floatFromInt(std.math.minInt(i8))),
        10 => -512.0,
        11 => -1024.0,
        16 => @as(f32, @floatFromInt(std.math.minInt(i16))),
        24 => -0x800000,
        32 => @as(f32, @floatFromInt(std.math.minInt(i32))),
        64 => @as(f32, @floatFromInt(std.math.minInt(i64))),
        else => blk: {
            lib.unsupported("format component bits {d}", .{bits});
            break :blk -1.0;
        },
    };
}

fn maxFloatValue(format: vk.Format) f32 {
    return switch (format) {
        .r16_sfloat,
        .r16g16_sfloat,
        .r16g16b16_sfloat,
        .r16g16b16a16_sfloat,
        .b10g11r11_ufloat_pack32,
        .e5b9g9r9_ufloat_pack32,
        .bc6h_ufloat_block,
        .bc6h_sfloat_block,
        => std.math.floatMax(f16),
        else => std.math.floatMax(f32),
    };
}

pub fn maxElementValue(format: vk.Format) f32 {
    if (isDepth(format))
        return 1.0;

    if (isStencil(format))
        return maxUnsignedValue(8);

    if (isSnorm(format) or isUnorm(format) or isSrgb(format))
        return 1.0;

    if (isUscaled(format) or isUint(format))
        return maxUnsignedValue(maxComponentBits(format));

    if (isSscaled(format) or isSint(format))
        return maxSignedValue(maxComponentBits(format));

    if (isUfloat(format) or isSfloat(format))
        return maxFloatValue(format);

    lib.unsupported("format max element value {any}", .{format});
    return 1.0;
}

pub fn minElementValue(format: vk.Format) f32 {
    if (isDepth(format) or isStencil(format))
        return 0.0;

    if (isSnorm(format))
        return -1.0;

    if (isUnorm(format) or isSrgb(format) or isUscaled(format) or isUint(format) or isUfloat(format))
        return 0.0;

    if (isSscaled(format) or isSint(format))
        return minSignedValue(maxComponentBits(format));

    if (isSfloat(format))
        return -maxFloatValue(format);

    lib.unsupported("format min element value {any}", .{format});
    return 0.0;
}
