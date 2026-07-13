const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const kmd = @import("kmd.zig");

const VkError = base.VkError;
const FlintImage = @import("FlintImage.zig");
const FlintCommandBuffer = @import("FlintCommandBuffer.zig");
const MemoryRange = @import("MemoryRange.zig");

pub fn emitLinearCopy(cmd: *FlintCommandBuffer, src: MemoryRange, dst: MemoryRange) VkError!void {
    if (src.size != dst.size) return VkError.ValidationFailed;

    var copied: vk.DeviceSize = 0;
    while (copied < src.size) {
        const chunk = @min(src.size - copied, kmd.max_blt_span);
        const src_chunk: MemoryRange = .{ .memory = src.memory, .offset = src.offset + copied, .size = chunk };
        const dst_chunk: MemoryRange = .{ .memory = dst.memory, .offset = dst.offset + copied, .size = chunk };
        const width: u32 = @intCast(chunk);

        try cmd.emit(kmd.xy_src_copy_blt | kmd.xy_blt_write_alpha | kmd.xy_blt_write_rgb);
        try cmd.emit(kmd.blt_depth_8 | kmd.rop_source_copy | width);
        try cmd.emit(0);
        try cmd.emit((1 << 16) | width);
        try cmd.emitRelocatedAddress(dst_chunk, false, true);
        try cmd.emit(0);
        try cmd.emit(width);
        try cmd.emitRelocatedAddress(src_chunk, true, false);

        copied += chunk;
    }
}

pub fn copyBufferImage(cmd: *FlintCommandBuffer, buffer: *base.Buffer, image_interface: *base.Image, region: vk.BufferImageCopy, image_is_dst: bool) VkError!void {
    if (region.image_extent.width == 0 or region.image_extent.height == 0 or region.image_extent.depth == 0)
        return;
    if (region.image_offset.x < 0 or region.image_offset.y < 0 or region.image_offset.z < 0)
        return VkError.ValidationFailed;

    const image: *FlintImage = @alignCast(@fieldParentPtr("interface", image_interface));
    const format = image_interface.formatFromAspect(region.image_subresource.aspect_mask);
    const bytes_per_block = base.format.texelSize(format);
    const block_width = base.format.blockWidth(format);
    const block_height = base.format.blockHeight(format);

    const buffer_width = if (region.buffer_row_length == 0) region.image_extent.width else region.buffer_row_length;
    const buffer_height = if (region.buffer_image_height == 0) region.image_extent.height else region.buffer_image_height;
    const buffer_row_pitch = base.format.pitchMemSize(format, buffer_width);
    const buffer_slice_pitch = base.format.sliceMemSize(format, buffer_width, buffer_height);
    const copy_row_size = base.format.pitchMemSize(format, region.image_extent.width);
    const copy_rows = base.format.blockCountY(format, region.image_extent.height);

    const layer_count = if (region.image_subresource.layer_count == vk.REMAINING_ARRAY_LAYERS)
        image_interface.array_layers - region.image_subresource.base_array_layer
    else
        region.image_subresource.layer_count;
    if (layer_count == 0 or layer_count > image_interface.array_layers - region.image_subresource.base_array_layer)
        return VkError.ValidationFailed;

    const image_row_pitch = image_interface.getRowPitchMemSizeForMipLevel(region.image_subresource.aspect_mask, region.image_subresource.mip_level);
    const image_slice_pitch = image_interface.getSliceMemSizeForMipLevel(region.image_subresource.aspect_mask, region.image_subresource.mip_level);
    const image_x_offset = @divFloor(@as(usize, @intCast(region.image_offset.x)), block_width) * bytes_per_block;
    const image_y_offset = @divFloor(@as(usize, @intCast(region.image_offset.y)), block_height);

    for (0..layer_count) |layer| {
        const image_subresource_offset = try image.getSubresourceOffset(
            region.image_subresource.aspect_mask,
            region.image_subresource.mip_level,
            region.image_subresource.base_array_layer + @as(u32, @intCast(layer)),
        );

        for (0..region.image_extent.depth) |z| {
            for (0..copy_rows) |row| {
                const buffer_offset = region.buffer_offset +
                    (layer * region.image_extent.depth + z) * buffer_slice_pitch +
                    row * buffer_row_pitch;
                const image_offset = image_subresource_offset +
                    (@as(usize, @intCast(region.image_offset.z)) + z) * image_slice_pitch +
                    (image_y_offset + row) * image_row_pitch +
                    image_x_offset;

                const buffer_range = try MemoryRange.fromBuffer(buffer, buffer_offset, copy_row_size);
                const image_range = try MemoryRange.fromImage(image_interface, image_offset, copy_row_size);
                if (image_is_dst)
                    try emitLinearCopy(cmd, buffer_range, image_range)
                else
                    try emitLinearCopy(cmd, image_range, buffer_range);
            }
        }
    }
}

pub fn copyImage(cmd: *FlintCommandBuffer, src_interface: *base.Image, dst_interface: *base.Image, region: vk.ImageCopy) VkError!void {
    const depth_stencil: vk.ImageAspectFlags = .{ .depth_bit = true, .stencil_bit = true };
    if (region.src_subresource.aspect_mask == depth_stencil and region.dst_subresource.aspect_mask == depth_stencil) {
        var single_aspect_region = region;
        single_aspect_region.src_subresource.aspect_mask = .{ .depth_bit = true };
        single_aspect_region.dst_subresource.aspect_mask = .{ .depth_bit = true };
        try copyImageSingleAspect(cmd, src_interface, dst_interface, single_aspect_region);

        single_aspect_region.src_subresource.aspect_mask = .{ .stencil_bit = true };
        single_aspect_region.dst_subresource.aspect_mask = .{ .stencil_bit = true };
        try copyImageSingleAspect(cmd, src_interface, dst_interface, single_aspect_region);
        return;
    }

    try copyImageSingleAspect(cmd, src_interface, dst_interface, region);
}

fn copyImageSingleAspect(cmd: *FlintCommandBuffer, src_interface: *base.Image, dst_interface: *base.Image, region: vk.ImageCopy) VkError!void {
    if (region.extent.width == 0 or region.extent.height == 0 or region.extent.depth == 0)
        return;
    if (region.src_offset.x < 0 or region.src_offset.y < 0 or region.src_offset.z < 0 or
        region.dst_offset.x < 0 or region.dst_offset.y < 0 or region.dst_offset.z < 0)
        return VkError.ValidationFailed;
    if (@popCount(region.src_subresource.aspect_mask.toInt()) != 1 or
        @popCount(region.dst_subresource.aspect_mask.toInt()) != 1)
        return VkError.ValidationFailed;
    if (region.src_subresource.aspect_mask.subtract(base.format.toAspect(src_interface.format)).toInt() != 0 or
        region.dst_subresource.aspect_mask.subtract(base.format.toAspect(dst_interface.format)).toInt() != 0)
        return VkError.ValidationFailed;
    if (src_interface.samples.toInt() != dst_interface.samples.toInt())
        return VkError.ValidationFailed;

    const src: *FlintImage = @alignCast(@fieldParentPtr("interface", src_interface));
    const dst: *FlintImage = @alignCast(@fieldParentPtr("interface", dst_interface));
    const src_format = src_interface.formatFromAspect(region.src_subresource.aspect_mask);
    const dst_format = dst_interface.formatFromAspect(region.dst_subresource.aspect_mask);
    const bytes_per_block = base.format.texelSize(src_format);

    if (bytes_per_block != base.format.texelSize(dst_format))
        return VkError.FormatNotSupported;

    const src_block_width = base.format.blockWidth(src_format);
    const src_block_height = base.format.blockHeight(src_format);
    const dst_block_width = base.format.blockWidth(dst_format);
    const dst_block_height = base.format.blockHeight(dst_format);
    if (base.format.isCompressed(src_format) and base.format.isCompressed(dst_format) and
        (src_block_width != dst_block_width or src_block_height != dst_block_height))
        return VkError.FormatNotSupported;

    const src_x: usize = @intCast(region.src_offset.x);
    const src_y: usize = @intCast(region.src_offset.y);
    const src_z: usize = @intCast(region.src_offset.z);
    const dst_x: usize = @intCast(region.dst_offset.x);
    const dst_y: usize = @intCast(region.dst_offset.y);
    const dst_z: usize = @intCast(region.dst_offset.z);
    if (@mod(src_x, src_block_width) != 0 or @mod(src_y, src_block_height) != 0 or
        @mod(dst_x, dst_block_width) != 0 or @mod(dst_y, dst_block_height) != 0)
        return VkError.ValidationFailed;

    if (region.src_subresource.mip_level >= src_interface.mip_levels or
        region.dst_subresource.mip_level >= dst_interface.mip_levels)
        return VkError.ValidationFailed;
    const src_extent = src.getMipLevelExtent(region.src_subresource.mip_level);
    const dst_extent = dst.getMipLevelExtent(region.dst_subresource.mip_level);
    const copy_blocks_x = base.format.blockCountX(src_format, region.extent.width);
    const copy_blocks_y = base.format.blockCountY(src_format, region.extent.height);
    const src_block_x = src_x / src_block_width;
    const src_block_y = src_y / src_block_height;
    const dst_block_x = dst_x / dst_block_width;
    const dst_block_y = dst_y / dst_block_height;
    if (src_block_x + copy_blocks_x > base.format.blockCountX(src_format, src_extent.width) or
        src_block_y + copy_blocks_y > base.format.blockCountY(src_format, src_extent.height) or
        dst_block_x + copy_blocks_x > base.format.blockCountX(dst_format, dst_extent.width) or
        dst_block_y + copy_blocks_y > base.format.blockCountY(dst_format, dst_extent.height) or
        src_z + region.extent.depth > src_extent.depth or
        dst_z + region.extent.depth > dst_extent.depth)
        return VkError.ValidationFailed;

    const src_layer_count = try resolveLayerCount(src_interface, region.src_subresource);
    const dst_layer_count = try resolveLayerCount(dst_interface, region.dst_subresource);
    if (src_layer_count != dst_layer_count)
        return VkError.ValidationFailed;

    const src_row_pitch = src_interface.getRowPitchMemSizeForMipLevel(region.src_subresource.aspect_mask, region.src_subresource.mip_level);
    const src_slice_pitch = src_interface.getSliceMemSizeForMipLevel(region.src_subresource.aspect_mask, region.src_subresource.mip_level);
    const src_sample_pitch = src.getMipLevelSize(region.src_subresource.aspect_mask, region.src_subresource.mip_level);
    const dst_row_pitch = dst_interface.getRowPitchMemSizeForMipLevel(region.dst_subresource.aspect_mask, region.dst_subresource.mip_level);
    const dst_slice_pitch = dst_interface.getSliceMemSizeForMipLevel(region.dst_subresource.aspect_mask, region.dst_subresource.mip_level);
    const dst_sample_pitch = dst.getMipLevelSize(region.dst_subresource.aspect_mask, region.dst_subresource.mip_level);
    const copy_row_size = copy_blocks_x * bytes_per_block;

    for (0..src_layer_count) |layer| {
        const src_subresource_offset = try src.getSubresourceOffset(
            region.src_subresource.aspect_mask,
            region.src_subresource.mip_level,
            region.src_subresource.base_array_layer + @as(u32, @intCast(layer)),
        );
        const dst_subresource_offset = try dst.getSubresourceOffset(
            region.dst_subresource.aspect_mask,
            region.dst_subresource.mip_level,
            region.dst_subresource.base_array_layer + @as(u32, @intCast(layer)),
        );

        for (0..src_interface.samples.toInt()) |sample| {
            for (0..region.extent.depth) |z| {
                for (0..copy_blocks_y) |row| {
                    const src_offset = src_subresource_offset +
                        sample * src_sample_pitch +
                        (src_z + z) * src_slice_pitch +
                        (src_block_y + row) * src_row_pitch +
                        src_block_x * bytes_per_block;
                    const dst_offset = dst_subresource_offset +
                        sample * dst_sample_pitch +
                        (dst_z + z) * dst_slice_pitch +
                        (dst_block_y + row) * dst_row_pitch +
                        dst_block_x * bytes_per_block;
                    try emitLinearCopy(
                        cmd,
                        try MemoryRange.fromImage(src_interface, src_offset, copy_row_size),
                        try MemoryRange.fromImage(dst_interface, dst_offset, copy_row_size),
                    );
                }
            }
        }
    }
}

fn resolveLayerCount(image: *const base.Image, subresource: vk.ImageSubresourceLayers) VkError!u32 {
    if (subresource.base_array_layer >= image.array_layers)
        return VkError.ValidationFailed;
    const layer_count = if (subresource.layer_count == vk.REMAINING_ARRAY_LAYERS)
        image.array_layers - subresource.base_array_layer
    else
        subresource.layer_count;
    if (layer_count == 0 or layer_count > image.array_layers - subresource.base_array_layer)
        return VkError.ValidationFailed;
    return layer_count;
}

pub fn copyRangeFromRegion(buffer: *base.Buffer, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!MemoryRange {
    return MemoryRange.fromBuffer(buffer, offset, size);
}

pub fn fillRange(buffer: *base.Buffer, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!MemoryRange {
    const resolved_size = if (size == vk.WHOLE_SIZE) blk: {
        if (offset > buffer.size) return VkError.ValidationFailed;
        break :blk std.mem.alignBackward(vk.DeviceSize, buffer.size - offset, @sizeOf(u32));
    } else blk: {
        if (size % @sizeOf(u32) != 0) return VkError.ValidationFailed;
        break :blk size;
    };

    return MemoryRange.fromBuffer(buffer, offset, resolved_size);
}
