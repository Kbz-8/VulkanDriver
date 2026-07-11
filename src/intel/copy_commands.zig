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
