const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("lib.zig");
const proto = lib.proto;

const VkError = base.VkError;
const PhiCommandBuffer = @import("PhiCommandBuffer.zig");
const PhiDeviceMemory = @import("PhiDeviceMemory.zig");

const CopyAddress = struct {
    offset: vk.DeviceSize,
    row_pitch: vk.DeviceSize,
    slice_pitch: vk.DeviceSize,
    layer_pitch: vk.DeviceSize,
};

const CopyShape = struct {
    row_size: vk.DeviceSize,
    row_count: u32,
    slice_count: u32,
    layer_count: u32,
};

fn remoteMemory(buffer: *base.Buffer) VkError!*PhiDeviceMemory {
    const memory = buffer.memory orelse return VkError.ValidationFailed;
    const phi_memory: *PhiDeviceMemory = @alignCast(@fieldParentPtr("interface", memory));
    return phi_memory;
}

fn remoteImageMemory(image: *base.Image) VkError!*PhiDeviceMemory {
    const memory = image.memory orelse return VkError.ValidationFailed;
    const phi_memory: *PhiDeviceMemory = @alignCast(@fieldParentPtr("interface", memory));
    return phi_memory;
}

fn checkedAdd(a: vk.DeviceSize, b: vk.DeviceSize) VkError!vk.DeviceSize {
    const result, const overflow = @addWithOverflow(a, b);
    if (overflow != 0)
        return VkError.ValidationFailed;
    return result;
}

fn checkedMul(a: vk.DeviceSize, b: vk.DeviceSize) VkError!vk.DeviceSize {
    const result, const overflow = @mulWithOverflow(a, b);
    if (overflow != 0)
        return VkError.ValidationFailed;
    return result;
}

fn validateSingleAspect(image: *const base.Image, aspect_mask: vk.ImageAspectFlags) VkError!void {
    const valid_aspects = base.format.toAspect(image.format);
    if (aspect_mask.toInt() == 0 or @popCount(aspect_mask.toInt()) != 1 or aspect_mask.subtract(valid_aspects).toInt() != 0)
        return VkError.ValidationFailed;
}

fn getMipExtent(image: *const base.Image, mip_level: u32) VkError!vk.Extent3D {
    if (mip_level >= image.mip_levels)
        return VkError.ValidationFailed;
    return .{
        .width = @max(1, image.extent.width >> @intCast(mip_level)),
        .height = @max(1, image.extent.height >> @intCast(mip_level)),
        .depth = @max(1, image.extent.depth >> @intCast(mip_level)),
    };
}

fn validateImageRegion(image: *const base.Image, subresource: vk.ImageSubresourceLayers, offset: vk.Offset3D, extent: vk.Extent3D, allow_2d_depth_as_layers: bool) VkError!void {
    try validateSingleAspect(image, subresource.aspect_mask);

    if (offset.x < 0 or offset.y < 0 or offset.z < 0 or extent.width == 0 or extent.height == 0 or extent.depth == 0)
        return VkError.ValidationFailed;

    if (subresource.mip_level >= image.mip_levels)
        return VkError.ValidationFailed;

    const mip_extent = try getMipExtent(image, subresource.mip_level);
    const x: u64 = @intCast(offset.x);
    const y: u64 = @intCast(offset.y);
    const z: u64 = @intCast(offset.z);

    if (x > mip_extent.width or extent.width > mip_extent.width - x or y > mip_extent.height or extent.height > mip_extent.height - y)
        return VkError.ValidationFailed;

    if (image.image_type == .@"3d") {
        if (subresource.base_array_layer != 0 or subresource.layer_count != 1 or z > mip_extent.depth or extent.depth > mip_extent.depth - z)
            return VkError.ValidationFailed;
    } else {
        if (offset.z != 0 or subresource.layer_count == 0 or
            subresource.base_array_layer >= image.array_layers or
            subresource.layer_count > image.array_layers - subresource.base_array_layer)
            return VkError.ValidationFailed;

        if (allow_2d_depth_as_layers) {
            if (extent.depth != subresource.layer_count)
                return VkError.ValidationFailed;
        } else if (extent.depth != 1) {
            return VkError.ValidationFailed;
        }
    }
}

fn getImageCopyAddress(image: *base.Image, subresource: vk.ImageSubresourceLayers, image_offset: vk.Offset3D) VkError!CopyAddress {
    const layout = try image.getSubresourceLayout(.{
        .aspect_mask = subresource.aspect_mask,
        .mip_level = subresource.mip_level,
        .array_layer = subresource.base_array_layer,
    });

    const format = image.formatFromAspect(subresource.aspect_mask);
    const block_width = base.format.blockWidth(format);
    const block_height = base.format.blockHeight(format);
    const bytes_per_block = base.format.texelSize(format);

    const x: usize = @intCast(image_offset.x);
    const y: usize = @intCast(image_offset.y);
    const z: vk.DeviceSize = @intCast(image_offset.z);

    if (@mod(x, block_width) != 0 or @mod(y, block_height) != 0)
        return VkError.ValidationFailed;

    const block_x = @divFloor(x, block_width);
    const block_y = @divFloor(y, block_height);

    const x_offset = try checkedMul(@intCast(block_x), @intCast(bytes_per_block));
    const y_offset = try checkedMul(@intCast(block_y), layout.row_pitch);
    const z_offset = try checkedMul(z, layout.depth_pitch);

    var offset = try checkedAdd(image.memory_offset, layout.offset);
    offset = try checkedAdd(offset, z_offset);
    offset = try checkedAdd(offset, y_offset);
    offset = try checkedAdd(offset, x_offset);

    return .{
        .offset = offset,
        .row_pitch = layout.row_pitch,
        .slice_pitch = layout.depth_pitch,
        .layer_pitch = layout.array_pitch,
    };
}

fn getBufferImageAddress(buffer: *const base.Buffer, format: vk.Format, region: vk.BufferImageCopy) VkError!CopyAddress {
    const row_length: usize = if (region.buffer_row_length == 0)
        region.image_extent.width
    else
        region.buffer_row_length;
    const image_height: usize = if (region.buffer_image_height == 0)
        region.image_extent.height
    else
        region.buffer_image_height;

    if (row_length < region.image_extent.width or image_height < region.image_extent.height)
        return VkError.ValidationFailed;

    const block_width = base.format.blockWidth(format);
    const block_height = base.format.blockHeight(format);

    if (region.buffer_row_length != 0 and @mod(row_length, block_width) != 0)
        return VkError.ValidationFailed;
    if (region.buffer_image_height != 0 and @mod(image_height, block_height) != 0)
        return VkError.ValidationFailed;

    const row_pitch: vk.DeviceSize = @intCast(base.format.pitchMemSize(format, row_length));
    const slice_pitch: vk.DeviceSize = @intCast(base.format.sliceMemSize(format, row_length, image_height));

    return .{
        .offset = try checkedAdd(buffer.offset, region.buffer_offset),
        .row_pitch = row_pitch,
        .slice_pitch = slice_pitch,
        .layer_pitch = slice_pitch,
    };
}

fn getCopyShape(format: vk.Format, extent: vk.Extent3D, slice_count: u32, layer_count: u32) VkError!CopyShape {
    if (extent.width == 0 or extent.height == 0 or slice_count == 0 or layer_count == 0)
        return VkError.ValidationFailed;

    const block_count_x = base.format.blockCountX(format, extent.width);
    const row_size, const overflow = @mulWithOverflow(block_count_x, base.format.texelSize(format));
    if (overflow != 0)
        return VkError.ValidationFailed;

    return .{
        .row_size = @intCast(row_size),
        .row_count = @intCast(base.format.blockCountY(format, extent.height)),
        .slice_count = slice_count,
        .layer_count = layer_count,
    };
}

fn getCopySpan(address: CopyAddress, shape: CopyShape) VkError!vk.DeviceSize {
    var span = shape.row_size;

    if (shape.row_count > 1)
        span = try checkedAdd(span, try checkedMul(shape.row_count - 1, address.row_pitch));
    if (shape.slice_count > 1)
        span = try checkedAdd(span, try checkedMul(shape.slice_count - 1, address.slice_pitch));
    if (shape.layer_count > 1)
        span = try checkedAdd(span, try checkedMul(shape.layer_count - 1, address.layer_pitch));

    return span;
}

fn validateBufferRange(buffer: *const base.Buffer, region_offset: vk.DeviceSize, address: CopyAddress, shape: CopyShape) VkError!void {
    const span = try getCopySpan(address, shape);
    if (region_offset > buffer.size or span > buffer.size - region_offset)
        return VkError.ValidationFailed;
}

fn validateMemoryRange(memory: *const PhiDeviceMemory, address: CopyAddress, shape: CopyShape) VkError!void {
    const span = try getCopySpan(address, shape);
    if (address.offset > memory.interface.size or span > memory.interface.size - address.offset)
        return VkError.ValidationFailed;
}

fn appendImageCopy(
    cmd: *PhiCommandBuffer,
    command_type: c_int,
    src_memory: *PhiDeviceMemory,
    src: CopyAddress,
    dst_memory: *PhiDeviceMemory,
    dst: CopyAddress,
    shape: CopyShape,
) VkError!void {
    try validateMemoryRange(src_memory, src, shape);
    try validateMemoryRange(dst_memory, dst, shape);

    try cmd.appendCommand(proto.PhiCmdCopyImage, command_type, .{
        .src_memory = @intCast(src_memory.remote_handle),
        .src_offset = src.offset,
        .src_row_pitch = src.row_pitch,
        .src_slice_pitch = src.slice_pitch,
        .src_layer_pitch = src.layer_pitch,
        .dst_memory = @intCast(dst_memory.remote_handle),
        .dst_offset = dst.offset,
        .dst_row_pitch = dst.row_pitch,
        .dst_slice_pitch = dst.slice_pitch,
        .dst_layer_pitch = dst.layer_pitch,
        .row_size = shape.row_size,
        .row_count = shape.row_count,
        .slice_count = shape.slice_count,
        .layer_count = shape.layer_count,
    });
}

pub fn copyBuffer(cmd: *PhiCommandBuffer, src: *base.Buffer, dst: *base.Buffer, regions: []const vk.BufferCopy) VkError!void {
    const src_memory = try remoteMemory(src);
    const dst_memory = try remoteMemory(dst);

    for (regions) |region| {
        const src_offset, const src_overflow = @addWithOverflow(src.offset, region.src_offset);
        const dst_offset, const dst_overflow = @addWithOverflow(dst.offset, region.dst_offset);
        if (src_overflow != 0 or dst_overflow != 0)
            return VkError.ValidationFailed;

        try cmd.appendCommand(proto.PhiCmdCopyBuffer, proto.PHI_CMD_COPY_BUFFER, .{
            .size = region.size,
            .src_memory = @intCast(src_memory.remote_handle),
            .dst_memory = @intCast(dst_memory.remote_handle),
            .src_offset = src_offset,
            .dst_offset = dst_offset,
        });
    }
}

pub fn copyBufferImage(cmd: *PhiCommandBuffer, buffer: *base.Buffer, image: *base.Image, region: vk.BufferImageCopy, image_is_dst: bool) VkError!void {
    if (image.samples.toInt() != 1)
        return VkError.ValidationFailed;

    try validateImageRegion(image, region.image_subresource, region.image_offset, region.image_extent, false);

    const format = image.formatFromAspect(region.image_subresource.aspect_mask);
    const buffer_address = try getBufferImageAddress(buffer, format, region);
    const image_address = try getImageCopyAddress(image, region.image_subresource, region.image_offset);

    const shape = if (image.image_type == .@"3d")
        try getCopyShape(format, region.image_extent, region.image_extent.depth, 1)
    else
        try getCopyShape(format, region.image_extent, 1, region.image_subresource.layer_count);

    try validateBufferRange(buffer, region.buffer_offset, buffer_address, shape);

    const buffer_memory = try remoteMemory(buffer);
    const image_memory = try remoteImageMemory(image);

    if (image_is_dst) {
        try appendImageCopy(
            cmd,
            proto.PHI_CMD_COPY_BUFFER_TO_IMAGE,
            buffer_memory,
            buffer_address,
            image_memory,
            image_address,
            shape,
        );
    } else {
        try appendImageCopy(
            cmd,
            proto.PHI_CMD_COPY_IMAGE_TO_BUFFER,
            image_memory,
            image_address,
            buffer_memory,
            buffer_address,
            shape,
        );
    }
}

fn copyImageSingleAspect(cmd: *PhiCommandBuffer, src: *base.Image, dst: *base.Image, src_memory: *PhiDeviceMemory, dst_memory: *PhiDeviceMemory, region: vk.ImageCopy) VkError!void {
    const src_is_3d = src.image_type == .@"3d";
    const dst_is_3d = dst.image_type == .@"3d";
    const one_is_3d = src_is_3d != dst_is_3d;

    try validateImageRegion(src, region.src_subresource, region.src_offset, region.extent, one_is_3d);
    try validateImageRegion(dst, region.dst_subresource, region.dst_offset, region.extent, one_is_3d);

    const src_format = src.formatFromAspect(region.src_subresource.aspect_mask);
    const dst_format = dst.formatFromAspect(region.dst_subresource.aspect_mask);

    if (base.format.texelSize(src_format) != base.format.texelSize(dst_format) or
        base.format.blockWidth(src_format) != base.format.blockWidth(dst_format) or
        base.format.blockHeight(src_format) != base.format.blockHeight(dst_format))
        return VkError.ValidationFailed;

    var src_address = try getImageCopyAddress(src, region.src_subresource, region.src_offset);
    var dst_address = try getImageCopyAddress(dst, region.dst_subresource, region.dst_offset);

    const shape: CopyShape = if (src_is_3d and dst_is_3d) blk: {
        break :blk try getCopyShape(src_format, region.extent, region.extent.depth, 1);
    } else if (!src_is_3d and !dst_is_3d) blk: {
        if (region.src_subresource.layer_count != region.dst_subresource.layer_count)
            return VkError.ValidationFailed;

        break :blk try getCopyShape(
            src_format,
            region.extent,
            @intCast(src.samples.toInt()),
            region.src_subresource.layer_count,
        );
    } else blk: {
        if (src.samples.toInt() != 1)
            return VkError.ValidationFailed;

        if (src_is_3d)
            src_address.layer_pitch = src_address.slice_pitch;
        if (dst_is_3d)
            dst_address.layer_pitch = dst_address.slice_pitch;

        break :blk try getCopyShape(src_format, region.extent, 1, region.extent.depth);
    };

    try appendImageCopy(
        cmd,
        proto.PHI_CMD_COPY_IMAGE,
        src_memory,
        src_address,
        dst_memory,
        dst_address,
        shape,
    );
}

pub fn copyImage(cmd: *PhiCommandBuffer, src: *base.Image, dst: *base.Image, region: vk.ImageCopy) VkError!void {
    if (src.samples.toInt() != dst.samples.toInt())
        return VkError.ValidationFailed;

    const src_memory = try remoteImageMemory(src);
    const dst_memory = try remoteImageMemory(dst);

    const depth_stencil: vk.ImageAspectFlags = .{
        .depth_bit = true,
        .stencil_bit = true,
    };

    if (region.src_subresource.aspect_mask == depth_stencil and
        region.dst_subresource.aspect_mask == depth_stencil)
    {
        var single_aspect_region = region;

        single_aspect_region.src_subresource.aspect_mask = .{
            .depth_bit = true,
        };
        single_aspect_region.dst_subresource.aspect_mask = .{
            .depth_bit = true,
        };
        try copyImageSingleAspect(
            cmd,
            src,
            dst,
            src_memory,
            dst_memory,
            single_aspect_region,
        );

        single_aspect_region.src_subresource.aspect_mask = .{
            .stencil_bit = true,
        };
        single_aspect_region.dst_subresource.aspect_mask = .{
            .stencil_bit = true,
        };
        try copyImageSingleAspect(
            cmd,
            src,
            dst,
            src_memory,
            dst_memory,
            single_aspect_region,
        );
        return;
    }

    try copyImageSingleAspect(
        cmd,
        src,
        dst,
        src_memory,
        dst_memory,
        region,
    );
}

pub fn blitImage(cmd: *PhiCommandBuffer, src: *base.Image, dst: *base.Image, region: vk.ImageBlit, filter: vk.Filter) VkError!void {
    const src_memory = try remoteImageMemory(src);
    const dst_memory = try remoteImageMemory(dst);

    var src_offset_0 = region.src_offsets[0];
    var src_offset_1 = region.src_offsets[1];

    var dst_offset_0 = region.dst_offsets[0];
    var dst_offset_1 = region.dst_offsets[1];

    if (dst_offset_0.x > dst_offset_1.x) {
        std.mem.swap(i32, &dst_offset_0.x, &dst_offset_1.x);
        std.mem.swap(i32, &src_offset_0.x, &src_offset_1.x);
    }

    if (dst_offset_0.y > dst_offset_1.y) {
        std.mem.swap(i32, &dst_offset_0.y, &dst_offset_1.y);
        std.mem.swap(i32, &src_offset_0.y, &src_offset_1.y);
    }

    if (dst_offset_0.z > dst_offset_1.z) {
        std.mem.swap(i32, &dst_offset_0.z, &dst_offset_1.z);
        std.mem.swap(i32, &src_offset_0.z, &src_offset_1.z);
    }

    const src_extent = try getMipExtent(src, region.src_subresource.mip_level);

    const step_x = @as(f32, @floatFromInt(src_offset_1.x - src_offset_0.x)) / @as(f32, @floatFromInt(dst_offset_1.x - dst_offset_0.x));
    const step_y = @as(f32, @floatFromInt(src_offset_1.y - src_offset_0.y)) / @as(f32, @floatFromInt(dst_offset_1.y - dst_offset_0.y));

    const step_z = @as(f32, @floatFromInt(src_offset_1.z - src_offset_0.z)) / @as(f32, @floatFromInt(dst_offset_1.z - dst_offset_0.z));
    const src_x0 = @as(f32, @floatFromInt(src_offset_0.x)) + (0.5 - @as(f32, @floatFromInt(dst_offset_0.x))) * step_x;

    const src_y0 = @as(f32, @floatFromInt(src_offset_0.y)) + (0.5 - @as(f32, @floatFromInt(dst_offset_0.y))) * step_y;
    const src_z0 = @as(f32, @floatFromInt(src_offset_0.z)) + (0.5 - @as(f32, @floatFromInt(dst_offset_0.z))) * step_z;

    const src_layout = try src.getSubresourceLayout(.{
        .aspect_mask = region.src_subresource.aspect_mask,
        .mip_level = region.src_subresource.mip_level,
        .array_layer = region.src_subresource.base_array_layer,
    });

    const dst_layout = try dst.getSubresourceLayout(.{
        .aspect_mask = region.dst_subresource.aspect_mask,
        .mip_level = region.dst_subresource.mip_level,
        .array_layer = region.dst_subresource.base_array_layer,
    });

    const src_format = src.formatFromAspect(region.src_subresource.aspect_mask);
    const dst_format = dst.formatFromAspect(region.dst_subresource.aspect_mask);

    const apply_filter = (filter != .nearest);
    const resolve_srgb = src.samples.toInt() > 1 and
        dst.samples.toInt() == 1 and
        base.format.isSrgb(src_format) and
        base.format.isSrgb(dst_format);
    const allow_srgb_conversion = apply_filter or resolve_srgb or base.format.isSrgb(src_format) != base.format.isSrgb(dst_format);

    const clamp_to_edge = src_offset_0.x < 0 or
        src_offset_0.y < 0 or
        @as(u32, @intCast(src_offset_1.x)) > src_extent.width or
        @as(u32, @intCast(src_offset_1.y)) > src_extent.height or
        (filter != .nearest and ((src_x0 < 0.5) or (src_y0 < 0.5)));

    try cmd.appendCommand(
        proto.PhiCmdBlitImage,
        proto.PHI_CMD_BLIT_IMAGE,
        .{
            .src_memory = @intCast(src_memory.remote_handle),
            .src_offset = src.memory_offset + src_layout.offset,
            .src_row_pitch = src_layout.row_pitch,
            .src_slice_pitch = src_layout.depth_pitch,
            .src_layer_pitch = src_layout.array_pitch,

            .dst_memory = @intCast(dst_memory.remote_handle),
            .dst_offset = dst.memory_offset + dst_layout.offset,
            .dst_row_pitch = dst_layout.row_pitch,
            .dst_slice_pitch = dst_layout.depth_pitch,
            .dst_layer_pitch = dst_layout.array_pitch,

            .dst_format = @intCast(@as(i32, @intFromEnum(dst_format))),
            .src_format = @intCast(@as(i32, @intFromEnum(src_format))),

            .src_width = src_extent.width,
            .src_height = src_extent.height,
            .src_depth = src_extent.depth,

            .dst_x0 = dst_offset_0.x,
            .dst_y0 = dst_offset_0.y,
            .dst_z0 = dst_offset_0.z,
            .dst_x1 = dst_offset_1.x,
            .dst_y1 = dst_offset_1.y,
            .dst_z1 = dst_offset_1.z,

            .src_x0 = src_x0,
            .src_y0 = src_y0,
            .src_z0 = src_z0,

            .step_x = step_x,
            .step_y = step_y,
            .step_z = step_z,

            .layer_count = region.dst_subresource.layer_count,

            .filter = @intCast(@intFromEnum(filter)),
            .clamp_to_edge = @intFromBool(clamp_to_edge),
            .allow_srgb_conversion = @intFromBool(allow_srgb_conversion),

            .reserved = 0,
        },
    );
}
