//! This software blitter is highly inspired by SwiftShaders one

const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;

pub const SoftImage = @import("../SoftImage.zig");
pub const SoftImageView = @import("../SoftImageView.zig");

const Self = @This();

pub const init: Self = .{};

pub fn clear(self: *Self, pixel: vk.ClearValue, format: vk.Format, dest: *SoftImage, view_format: vk.Format, range: vk.ImageSubresourceRange, area: ?vk.Rect2D) VkError!void {
    const dst_format = base.format.fromAspect(view_format, range.aspect_mask);
    if (dst_format == .undefined) {
        return;
    }

    const view_format_value: c_uint = @intCast(@intFromEnum(view_format));

    var clamped_pixel: vk.ClearValue = pixel;
    if (base.vku.vkuFormatIsSINT(view_format_value) or base.vku.vkuFormatIsUINT(view_format_value)) {
        const min_value: f32 = if (base.vku.vkuFormatIsSNORM(view_format_value)) -1.0 else 0.0;

        if (range.aspect_mask.color_bit) {
            clamped_pixel.color.float_32[0] = std.math.clamp(pixel.color.float_32[0], min_value, 1.0);
            clamped_pixel.color.float_32[1] = std.math.clamp(pixel.color.float_32[1], min_value, 1.0);
            clamped_pixel.color.float_32[2] = std.math.clamp(pixel.color.float_32[2], min_value, 1.0);
            clamped_pixel.color.float_32[3] = std.math.clamp(pixel.color.float_32[3], min_value, 1.0);
        }

        // Stencil never requires clamping, so we can check for Depth only
        if (range.aspect_mask.depth_bit) {
            clamped_pixel.depth_stencil.depth = std.math.clamp(pixel.depth_stencil.depth, min_value, 1.0);
        }
    }

    if (try self.fastClear(clamped_pixel, format, dest, dst_format, range, area)) {
        return;
    }
    base.logger.fixme("implement slow clear", .{});
}

fn fastClear(self: *Self, clear_value: vk.ClearValue, clear_format: vk.Format, dest: *SoftImage, view_format: vk.Format, range: vk.ImageSubresourceRange, render_area: ?vk.Rect2D) VkError!bool {
    _ = self;
    _ = render_area;
    _ = range;

    if (clear_format != .r32g32b32a32_sfloat and clear_format != .d32_sfloat and clear_format != .s8_uint) {
        return false;
    }

    const ClearValue = union {
        rgba: struct { r: f32, g: f32, b: f32, a: f32 },
        rgb: [3]f32,
        d: f32,
        d_as_u32: u32,
        s: u32,
    };

    const c: *const ClearValue = @ptrCast(&clear_value);

    var pack: u32 = 0;
    switch (view_format) {
        .r5g6b5_unorm_pack16 => pack = @as(u16, @intFromFloat(31.0 * c.rgba.b + 0.5)) | (@as(u16, @intFromFloat(63.0 * c.rgba.g + 0.5)) << 5) | (@as(u16, @intFromFloat(31.0 * c.rgba.r + 0.5)) << 11),
        .b5g6r5_unorm_pack16 => pack = @as(u16, @intFromFloat(31.0 * c.rgba.r + 0.5)) | (@as(u16, @intFromFloat(63.0 * c.rgba.g + 0.5)) << 5) | (@as(u16, @intFromFloat(31.0 * c.rgba.b + 0.5)) << 11),

        .a8b8g8r8_uint_pack32,
        .a8b8g8r8_unorm_pack32,
        .r8g8b8a8_unorm,
        => pack = (@as(u32, @intFromFloat(255.0 * c.rgba.a + 0.5)) << 24) | (@as(u32, @intFromFloat(255.0 * c.rgba.b + 0.5)) << 16) | (@as(u32, @intFromFloat(255.0 * c.rgba.g + 0.5)) << 8) | @as(u32, @intFromFloat(255.0 * c.rgba.r + 0.5)),

        .b8g8r8a8_unorm => pack = (@as(u32, @intFromFloat(255.0 * c.rgba.a + 0.5)) << 24) | (@as(u32, @intFromFloat(255.0 * c.rgba.r + 0.5)) << 16) | (@as(u32, @intFromFloat(255.0 * c.rgba.g + 0.5)) << 8) | @as(u32, @intFromFloat(255.0 * c.rgba.b + 0.5)),
        //.b10g11r11_ufloat_pack32 => pack = R11G11B10F(c.rgb),
        //.e5b9g9r9_ufloat_pack32 => pack = RGB9E5(c.rgb),
        .d32_sfloat => {
            std.debug.assert(clear_format == .d32_sfloat);
            pack = c.d_as_u32; // float reinterpreted as uint32
        },
        .s8_uint => {
            std.debug.assert(clear_format == .s8_uint);
            pack = @as(u8, @intCast(c.s));
        },
        else => return false,
    }

    if (dest.interface.memory) |memory| {
        const image_size = try dest.interface.getTotalSize();
        const memory_map = memory.map(dest.interface.memory_offset, image_size) catch return false;
        defer memory.unmap();

        const memory_map_as_u32: []u32 = @as([*]u32, @ptrCast(@alignCast(memory_map)))[0..@divExact(image_size, 4)];

        @memset(memory_map_as_u32, pack);

        return true;
    }
    return false;
}

pub fn blitRegion(_: *Self, src: *const SoftImage, dst: *SoftImage, region: vk.ImageBlit, filter: vk.Filter) VkError!void {
    var dst_offset_0 = region.dst_offsets[0];
    var dst_offset_1 = region.dst_offsets[1];
    var src_offset_0 = region.src_offsets[0];
    var src_offset_1 = region.src_offsets[1];

    if (dst_offset_0.x > dst_offset_1.x) {
        std.mem.swap(i32, &src_offset_0.x, &src_offset_1.x);
        std.mem.swap(i32, &dst_offset_0.x, &dst_offset_1.x);
    }

    if (dst_offset_0.y > dst_offset_1.y) {
        std.mem.swap(i32, &src_offset_0.y, &src_offset_1.y);
        std.mem.swap(i32, &dst_offset_0.y, &dst_offset_1.y);
    }

    if (dst_offset_0.z > dst_offset_1.z) {
        std.mem.swap(i32, &src_offset_0.z, &src_offset_1.z);
        std.mem.swap(i32, &dst_offset_0.z, &dst_offset_1.z);
    }

    const src_extent = src.getMipLevelExtent(region.src_subresource.mip_level);

    _ = src_extent;

    const width_ratio = @as(f32, @floatFromInt(src_offset_1.x - src_offset_0.x)) / @as(f32, @floatFromInt(dst_offset_1.x - dst_offset_0.x));
    const height_ratio = @as(f32, @floatFromInt(src_offset_1.y - src_offset_0.y)) / @as(f32, @floatFromInt(dst_offset_1.y - dst_offset_0.y));
    const depth_ratio = @as(f32, @floatFromInt(src_offset_1.z - src_offset_0.z)) / @as(f32, @floatFromInt(dst_offset_1.z - dst_offset_0.z));
    const x0 = @as(f32, @floatFromInt(src_offset_0.x)) + (0.5 - @as(f32, @floatFromInt(dst_offset_0.x))) * width_ratio;
    const y0 = @as(f32, @floatFromInt(src_offset_0.y)) + (0.5 - @as(f32, @floatFromInt(dst_offset_0.y))) * height_ratio;
    const z0 = @as(f32, @floatFromInt(src_offset_0.z)) + (0.5 - @as(f32, @floatFromInt(dst_offset_0.z))) * depth_ratio;

    _ = x0;
    _ = y0;
    _ = z0;

    const src_format = base.format.fromAspect(src.interface.format, region.src_subresource.aspect_mask);
    const dst_format = base.format.fromAspect(dst.interface.format, region.dst_subresource.aspect_mask);

    const apply_filter = (filter != .nearest);
    const allow_srgb_conversion = apply_filter or base.format.isSrgb(src_format) != base.format.isSrgb(dst_format);

    _ = allow_srgb_conversion;
}

// State state(srcFormat, dstFormat, src->getSampleCount(), dst->getSampleCount(),
//             Options{ doFilter, allowSRGBConversion });
// state.clampToEdge = (region.srcOffsets[0].x < 0) ||
//                     (region.srcOffsets[0].y < 0) ||
//                     (static_cast<uint32_t>(region.srcOffsets[1].x) > srcExtent.width) ||
//                     (static_cast<uint32_t>(region.srcOffsets[1].y) > srcExtent.height) ||
//                     (doFilter && ((x0 < 0.5f) || (y0 < 0.5f)));
// state.filter3D = (region.srcOffsets[1].z - region.srcOffsets[0].z) !=
//                  (region.dstOffsets[1].z - region.dstOffsets[0].z);
//
// auto blitRoutine = getBlitRoutine(state);
// if(!blitRoutine)
// {
//     return;
// }
//
// BlitData data = {
//     nullptr,                                                                                 // source
//     nullptr,                                                                                 // dest
//     assert_cast<uint32_t>(src->rowPitchBytes(srcAspect, region.srcSubresource.mipLevel)),    // sPitchB
//     assert_cast<uint32_t>(dst->rowPitchBytes(dstAspect, region.dstSubresource.mipLevel)),    // dPitchB
//     assert_cast<uint32_t>(src->slicePitchBytes(srcAspect, region.srcSubresource.mipLevel)),  // sSliceB
//     assert_cast<uint32_t>(dst->slicePitchBytes(dstAspect, region.dstSubresource.mipLevel)),  // dSliceB
//
//     x0,
//     y0,
//     z0,
//     widthRatio,
//     heightRatio,
//     depthRatio,
//
//     region.dstOffsets[0].x,  // x0d
//     region.dstOffsets[1].x,  // x1d
//     region.dstOffsets[0].y,  // y0d
//     region.dstOffsets[1].y,  // y1d
//     region.dstOffsets[0].z,  // z0d
//     region.dstOffsets[1].z,  // z1d
//
//     static_cast<int>(srcExtent.width),   // sWidth
//     static_cast<int>(srcExtent.height),  // sHeight
//     static_cast<int>(srcExtent.depth),   // sDepth
//
//     false,  // filter3D
// };
//
// VkImageSubresource srcSubres = {
//     region.srcSubresource.aspectMask,
//     region.srcSubresource.mipLevel,
//     region.srcSubresource.baseArrayLayer
// };
//
// VkImageSubresource dstSubres = {
//     region.dstSubresource.aspectMask,
//     region.dstSubresource.mipLevel,
//     region.dstSubresource.baseArrayLayer
// };
//
// VkImageSubresourceRange dstSubresRange = {
//     region.dstSubresource.aspectMask,
//     region.dstSubresource.mipLevel,
//     1,  // levelCount
//     region.dstSubresource.baseArrayLayer,
//     region.dstSubresource.layerCount
// };
//
// uint32_t lastLayer = src->getLastLayerIndex(dstSubresRange);
//
// for(; dstSubres.arrayLayer <= lastLayer; srcSubres.arrayLayer++, dstSubres.arrayLayer++)
// {
//     data.source = src->getTexelPointer({ 0, 0, 0 }, srcSubres);
//     data.dest = dst->getTexelPointer({ 0, 0, 0 }, dstSubres);
//
//     ASSERT(data.source < src->end());
//     ASSERT(data.dest < dst->end());
//
//     blitRoutine(&data);
// }
