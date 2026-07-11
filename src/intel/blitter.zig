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
    const src_image: *FlintImage = @alignCast(@fieldParentPtr("interface", src));
    const dst_image: *FlintImage = @alignCast(@fieldParentPtr("interface", dst));
    const src_format = src.formatFromAspect(region.src_subresource.aspect_mask);
    const dst_format = dst.formatFromAspect(region.dst_subresource.aspect_mask);
    const src_texel_size = base.format.texelSize(src_format);
    const dst_texel_size = base.format.texelSize(dst_format);

    if (src_format != dst_format or base.format.isCompressed(src_format) or base.format.isCompressed(dst_format) or src_texel_size != dst_texel_size)
        return VkError.FormatNotSupported;

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

    if (dst_0.x < 0 or dst_0.y < 0 or dst_0.z < 0 or
        dst_0.x == dst_1.x or dst_0.y == dst_1.y or dst_0.z == dst_1.z)
        return VkError.ValidationFailed;

    const src_extent = src_image.getMipLevelExtent(region.src_subresource.mip_level);
    const layer_count = if (region.dst_subresource.layer_count == vk.REMAINING_ARRAY_LAYERS)
        dst.array_layers - region.dst_subresource.base_array_layer
    else
        region.dst_subresource.layer_count;

    if (layer_count == 0 or
        layer_count > src.array_layers - region.src_subresource.base_array_layer or
        layer_count > dst.array_layers - region.dst_subresource.base_array_layer)
        return VkError.ValidationFailed;

    const copy_whole_rows = src_1.x - src_0.x == dst_1.x - dst_0.x and src_1.x > src_0.x;
    for (0..layer_count) |layer| {
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
