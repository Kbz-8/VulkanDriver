const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const kmd = @import("kmd.zig");

const VkError = base.VkError;
const FlintImage = @import("FlintImage.zig");
const FlintCommandBuffer = @import("FlintCommandBuffer.zig");
const MemoryRange = @import("MemoryRange.zig");

const copy = @import("copy_commands.zig");

pub fn blitImageRegion(cmd: *FlintCommandBuffer, src: *base.Image, dst: *base.Image, region: vk.ImageBlit) VkError!void {
    if (region.src_subresource.mip_level >= src.mip_levels or
        region.dst_subresource.mip_level >= dst.mip_levels)
        return VkError.ValidationFailed;
    if (src.samples.toInt() != 1 or dst.samples.toInt() != 1)
        return VkError.ValidationFailed;
    if (src.image_type != dst.image_type)
        return VkError.FeatureNotPresent;
    try validateAspect(src, region.src_subresource.aspect_mask);
    try validateAspect(dst, region.dst_subresource.aspect_mask);
    if (region.src_subresource.aspect_mask != region.dst_subresource.aspect_mask)
        return VkError.ValidationFailed;

    const src_image: *FlintImage = @alignCast(@fieldParentPtr("interface", src));
    const dst_image: *FlintImage = @alignCast(@fieldParentPtr("interface", dst));
    const src_format = src.formatFromAspect(region.src_subresource.aspect_mask);
    const dst_format = dst.formatFromAspect(region.dst_subresource.aspect_mask);
    const src_texel_size = base.format.texelSize(src_format);
    const dst_texel_size = base.format.texelSize(dst_format);

    if (base.format.isCompressed(src_format) or base.format.isCompressed(dst_format))
        return VkError.FormatNotSupported;

    // XY_SRC_COPY_BLT does not perform component conversion. Different Vulkan
    // names are safe only when they describe the same bytes and values.
    if (!bitwiseCompatibleFormats(src_format, dst_format) or src_texel_size != dst_texel_size)
        return VkError.FormatNotSupported;

    if ((base.format.isDepth(src.format) or base.format.isStencil(src.format) or
        base.format.isDepth(dst.format) or base.format.isStencil(dst.format)) and
        src.format != dst.format)
        return VkError.FormatNotSupported;

    const src_extent = src_image.getMipLevelExtent(region.src_subresource.mip_level);
    const dst_extent = dst_image.getMipLevelExtent(region.dst_subresource.mip_level);
    try validateOffsets(region.src_offsets, src_extent);
    try validateOffsets(region.dst_offsets, dst_extent);

    const src_layer_count = try resolveLayerCount(src, region.src_subresource);
    const dst_layer_count = try resolveLayerCount(dst, region.dst_subresource);
    if (src_layer_count != dst_layer_count)
        return VkError.ValidationFailed;

    var src_0 = region.src_offsets[0];
    var src_1 = region.src_offsets[1];
    var dst_0 = region.dst_offsets[0];
    var dst_1 = region.dst_offsets[1];
    inline for (.{ "x", "y", "z" }) |field| {
        if (@field(dst_0, field) > @field(dst_1, field)) {
            std.mem.swap(i32, &@field(src_0, field), &@field(src_1, field));
            std.mem.swap(i32, &@field(dst_0, field), &@field(dst_1, field));
        }
    }

    if (dst_0.x == dst_1.x or dst_0.y == dst_1.y or dst_0.z == dst_1.z or
        src_0.x == src_1.x or src_0.y == src_1.y or src_0.z == src_1.z)
        return VkError.ValidationFailed;

    const copy_whole_rows = src_1.x - src_0.x == dst_1.x - dst_0.x and src_1.x > src_0.x;
    for (0..src_layer_count) |layer| {
        const src_layer = region.src_subresource.base_array_layer + @as(u32, @intCast(layer));
        const dst_layer = region.dst_subresource.base_array_layer + @as(u32, @intCast(layer));

        var dst_z = dst_0.z;
        while (dst_z < dst_1.z) : (dst_z += 1) {
            const src_z = nearestBlitCoordinate(src_0.z, src_1.z, dst_0.z, dst_1.z, dst_z, src_extent.depth);
            var dst_y = dst_0.y;
            while (dst_y < dst_1.y) : (dst_y += 1) {
                const src_y = nearestBlitCoordinate(src_0.y, src_1.y, dst_0.y, dst_1.y, dst_y, src_extent.height);

                if (copy_whole_rows) {
                    const src_offset = try imageTexelOffset(src_image, region.src_subresource.aspect_mask, region.src_subresource.mip_level, src_layer, @intCast(src_0.x), src_y, src_z);
                    const dst_offset = try imageTexelOffset(dst_image, region.dst_subresource.aspect_mask, region.dst_subresource.mip_level, dst_layer, @intCast(dst_0.x), @intCast(dst_y), @intCast(dst_z));
                    const size: usize = @as(usize, @intCast(dst_1.x - dst_0.x)) * dst_texel_size;
                    try copy.emitLinearCopy(
                        cmd,
                        try MemoryRange.fromImage(src, src_offset, size),
                        try MemoryRange.fromImage(dst, dst_offset, size),
                    );
                    continue;
                }

                var dst_x = dst_0.x;
                while (dst_x < dst_1.x) : (dst_x += 1) {
                    const src_x = nearestBlitCoordinate(src_0.x, src_1.x, dst_0.x, dst_1.x, dst_x, src_extent.width);
                    const src_offset = try imageTexelOffset(src_image, region.src_subresource.aspect_mask, region.src_subresource.mip_level, src_layer, src_x, src_y, src_z);
                    const dst_offset = try imageTexelOffset(dst_image, region.dst_subresource.aspect_mask, region.dst_subresource.mip_level, dst_layer, @intCast(dst_x), @intCast(dst_y), @intCast(dst_z));
                    try copy.emitLinearCopy(
                        cmd,
                        try MemoryRange.fromImage(src, src_offset, src_texel_size),
                        try MemoryRange.fromImage(dst, dst_offset, dst_texel_size),
                    );
                }
            }
        }
    }
}

fn validateAspect(image: *const base.Image, aspect: vk.ImageAspectFlags) VkError!void {
    const valid_aspects = base.format.toAspect(image.format);
    if (aspect.toInt() == 0 or @popCount(aspect.toInt()) != 1 or
        aspect.subtract(valid_aspects).toInt() != 0)
        return VkError.ValidationFailed;
}

fn validateOffsets(offsets: [2]vk.Offset3D, extent: vk.Extent3D) VkError!void {
    for (offsets) |offset| {
        if (offset.x < 0 or offset.y < 0 or offset.z < 0 or
            offset.x > extent.width or offset.y > extent.height or offset.z > extent.depth)
            return VkError.ValidationFailed;
    }
}

fn resolveLayerCount(image: *const base.Image, subresource: vk.ImageSubresourceLayers) VkError!u32 {
    if (subresource.base_array_layer >= image.array_layers)
        return VkError.ValidationFailed;
    const available = image.array_layers - subresource.base_array_layer;
    const count = if (subresource.layer_count == vk.REMAINING_ARRAY_LAYERS)
        available
    else
        subresource.layer_count;
    if (count == 0 or count > available)
        return VkError.ValidationFailed;
    return count;
}

fn bitwiseCompatibleFormats(src: vk.Format, dst: vk.Format) bool {
    if (src == dst) return true;

    // On little-endian the packed A8B8G8R8 formats have the same byte
    // representation and component interpretation as their R8G8B8A8 peers.
    return switch (src) {
        .r8g8b8a8_unorm => dst == .a8b8g8r8_unorm_pack32,
        .a8b8g8r8_unorm_pack32 => dst == .r8g8b8a8_unorm,
        .r8g8b8a8_snorm => dst == .a8b8g8r8_snorm_pack32,
        .a8b8g8r8_snorm_pack32 => dst == .r8g8b8a8_snorm,
        .r8g8b8a8_uint => dst == .a8b8g8r8_uint_pack32,
        .a8b8g8r8_uint_pack32 => dst == .r8g8b8a8_uint,
        .r8g8b8a8_sint => dst == .a8b8g8r8_sint_pack32,
        .a8b8g8r8_sint_pack32 => dst == .r8g8b8a8_sint,
        .r8g8b8a8_srgb => dst == .a8b8g8r8_srgb_pack32,
        .a8b8g8r8_srgb_pack32 => dst == .r8g8b8a8_srgb,
        else => false,
    };
}

fn nearestBlitCoordinate(src_0: i32, src_1: i32, dst_0: i32, dst_1: i32, dst: i32, extent: u32) usize {
    const numerator = @as(i64, 2 * (dst - dst_0) + 1) * @as(i64, src_1 - src_0);
    const denominator = @as(i64, 2 * (dst_1 - dst_0));
    const coordinate = @as(i64, src_0) + @divFloor(numerator, denominator);
    return @intCast(std.math.clamp(coordinate, 0, @as(i64, extent) - 1));
}

fn imageTexelOffset(image: *const FlintImage, aspect: vk.ImageAspectFlags, mip_level: u32, layer: u32, x: usize, y: usize, z: usize) VkError!usize {
    const format = image.interface.formatFromAspect(aspect);
    return try image.getSubresourceOffset(aspect, mip_level, layer) +
        z * image.interface.getSliceMemSizeForMipLevel(aspect, mip_level) +
        y * image.interface.getRowPitchMemSizeForMipLevel(aspect, mip_level) +
        x * base.format.texelSize(format);
}
