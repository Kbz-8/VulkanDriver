//! Image layout representation in contiguous memory
//!
//! ```text
//! ┌──────────────────────────────────────────────────┐
//! │ Device memory at image offset                    │
//! │ ┌──────────────────────────────────────────────┐ │
//! │ │ Aspect 0, e.g. color/depth                   │ │
//! │ │                                              │ │
//! │ │  Layer 0                                     │ │
//! │ │  ┌────────────────────────────────────────┐  │ │
//! │ │  │ Mip 0                                  │  │ │
//! │ │  │ ┌──────────────────────────────────┐   │  │ │
//! │ │  │ │ z=0 slice                        │   │  │ │
//! │ │  │ │ row 0: [px][px][px][px]          │   │  │ │
//! │ │  │ │ row 1: [px][px][px][px]          │   │  │ │
//! │ │  │ │ row 2: [px][px][px][px]          │   │  │ │
//! │ │  │ └──────────────────────────────────┘   │  │ │
//! │ │  │                                        │  │ │
//! │ │  │ Mip 1                                  │  │ │
//! │ │  │ ┌──────────────────────────────────┐   │  │ │
//! │ │  │ │ row 0: [px][px]                  │   │  │ │
//! │ │  │ │ row 1: [px][px]                  │   │  │ │
//! │ │  │ └──────────────────────────────────┘   │  │ │
//! │ │  │                                        │  │ │
//! │ │  │ Mip 2                                  │  │ │
//! │ │  │ ┌──────────────────────────────────┐   │  │ │
//! │ │  │ │ row 0: [px]                      │   │  │ │
//! │ │  │ └──────────────────────────────────┘   │  │ │
//! │ │  └────────────────────────────────────────┘  │ │
//! │ │                                              │ │
//! │ │  Layer 1                                     │ │
//! │ │  ┌────────────────────────────────────────┐  │ │
//! │ │  │ Mip 0                                  │  │ │
//! │ │  │   row 0: [px][px][px][px]              │  │ │
//! │ │  │   row 1: [px][px][px][px]              │  │ │
//! │ │  │   row 2: [px][px][px][px]              │  │ │
//! │ │  │                                        │  │ │
//! │ │  │ Mip 1                                  │  │ │
//! │ │  │   row 0: [px][px]                      │  │ │
//! │ │  │   row 1: [px][px]                      │  │ │
//! │ │  │                                        │  │ │
//! │ │  │ Mip 2                                  │  │ │
//! │ │  │   row 0: [px]                          │  │ │
//! │ │  └────────────────────────────────────────┘  │ │
//! │ └──────────────────────────────────────────────┘ │
//! │ ┌──────────────────────────────────────────────┐ │
//! │ │ Aspect 1, e.g. stencil                       │ │
//! │ │ ...                                          │ │
//! │ └──────────────────────────────────────────────┘ │
//! └──────────────────────────────────────────────────┘
//! ```

const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("lib.zig");
const blitter = @import("device/blitter.zig");
const compressed = @import("device/compressed.zig");

const F32x4 = blitter.F32x4;
const U32x4 = blitter.U32x4;

const VkError = base.VkError;

const SoftBuffer = @import("SoftBuffer.zig");

const Self = @This();
pub const Interface = base.Image;

interface: Interface,

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.ImageCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);

    interface.vtable = &.{
        .destroy = destroy,
        .getMemoryRequirements = getMemoryRequirements,
        .getSubresourceLayout = getSubresourceLayout,
        .getTotalSizeForAspect = getTotalSizeForAspect,
        .getSliceMemSizeForMipLevel = getSliceMemSizeForMipLevel,
        .getRowPitchMemSizeForMipLevel = getRowPitchMemSizeForMipLevel,
        .copyToMemory = copyToMemory,
    };

    self.* = .{
        .interface = interface,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn getMemoryRequirements(_: *Interface, requirements: *vk.MemoryRequirements) VkError!void {
    requirements.alignment = lib.MEMORY_REQUIREMENTS_IMAGE_ALIGNMENT;
}

pub fn getClearFormat(self: *Self) VkError!vk.Format {
    return getClearFormatFor(self.interface.format);
}

pub fn getClearFormatFor(format: vk.Format) VkError!vk.Format {
    return if (base.format.isSint(format))
        .r32g32b32a32_sint
    else if (base.format.isUint(format))
        .r32g32b32a32_uint
    else
        .r32g32b32a32_sfloat;
}

pub fn copyToImage(self: *const Self, dst: *Self, region: vk.ImageCopy) VkError!void {
    const combined_depth_stencil_aspect: vk.ImageAspectFlags = .{
        .depth_bit = true,
        .stencil_bit = true,
    };

    if (region.src_subresource.aspect_mask == combined_depth_stencil_aspect and
        region.dst_subresource.aspect_mask == combined_depth_stencil_aspect)
    {
        var single_aspect_region = region;

        single_aspect_region.src_subresource.aspect_mask = .{ .depth_bit = true };
        single_aspect_region.dst_subresource.aspect_mask = .{ .depth_bit = true };
        try self.copyToImageSingleAspect(dst, single_aspect_region);

        single_aspect_region.src_subresource.aspect_mask = .{ .stencil_bit = true };
        single_aspect_region.dst_subresource.aspect_mask = .{ .stencil_bit = true };
        try self.copyToImageSingleAspect(dst, single_aspect_region);
    } else {
        try self.copyToImageSingleAspect(dst, region);
    }
}

pub fn copyToImageSingleAspect(self: *const Self, dst: *Self, region: vk.ImageCopy) VkError!void {
    if (!(region.src_subresource.aspect_mask == vk.ImageAspectFlags{ .color_bit = true } or
        region.src_subresource.aspect_mask == vk.ImageAspectFlags{ .depth_bit = true } or
        region.src_subresource.aspect_mask == vk.ImageAspectFlags{ .stencil_bit = true }))
    {
        base.unsupported("src subresource aspectMask {f}", .{region.src_subresource.aspect_mask});
        return VkError.ValidationFailed;
    }

    if (!(region.dst_subresource.aspect_mask == vk.ImageAspectFlags{ .color_bit = true } or
        region.dst_subresource.aspect_mask == vk.ImageAspectFlags{ .depth_bit = true } or
        region.dst_subresource.aspect_mask == vk.ImageAspectFlags{ .stencil_bit = true }))
    {
        base.unsupported("dst subresource aspectMask {f}", .{region.dst_subresource.aspect_mask});
        return VkError.ValidationFailed;
    }

    const src_format = self.interface.formatFromAspect(region.src_subresource.aspect_mask);
    const bytes_per_block = base.format.texelSize(src_format);
    const block_width = base.format.blockWidth(src_format);
    const block_height = base.format.blockHeight(src_format);

    const src_extent = self.getMipLevelExtent(region.src_subresource.mip_level);
    const dst_extent = dst.getMipLevelExtent(region.dst_subresource.mip_level);
    const copy_block_width = base.format.blockCountX(src_format, region.extent.width);
    const copy_block_height = base.format.blockCountY(src_format, region.extent.height);

    const one_is_3D = (self.interface.image_type == .@"3d") != (dst.interface.image_type == .@"3d");
    const both_are_3D = (self.interface.image_type == .@"3d") and (dst.interface.image_type == .@"3d");

    const src_row_pitch_bytes = self.interface.getRowPitchMemSizeForMipLevel(region.src_subresource.aspect_mask, region.src_subresource.mip_level);
    const src_depth_pitch_bytes = self.interface.getSliceMemSizeForMipLevel(region.src_subresource.aspect_mask, region.src_subresource.mip_level);
    const dst_row_pitch_bytes = dst.interface.getRowPitchMemSizeForMipLevel(region.dst_subresource.aspect_mask, region.dst_subresource.mip_level);
    const dst_depth_pitch_bytes = dst.interface.getSliceMemSizeForMipLevel(region.dst_subresource.aspect_mask, region.dst_subresource.mip_level);

    const src_array_pitch = self.getLayerSize(region.src_subresource.aspect_mask);
    const dst_array_pitch = dst.getLayerSize(region.dst_subresource.aspect_mask);

    const src_layer_pitch = if (self.interface.image_type == .@"3d") src_depth_pitch_bytes else src_array_pitch;
    const dst_layer_pitch = if (dst.interface.image_type == .@"3d") dst_depth_pitch_bytes else dst_array_pitch;

    const layer_count = if (one_is_3D) region.extent.depth else region.src_subresource.layer_count;
    const slice_count = if (both_are_3D) region.extent.depth else self.interface.samples.toInt();

    const is_single_slice = (slice_count == 1);
    const is_single_row = (copy_block_height == 1) and is_single_slice;
    const is_entire_row = (region.extent.width == src_extent.width) and (region.extent.width == dst_extent.width) and
        (@mod(@as(usize, @intCast(region.src_offset.x)), block_width) == 0) and
        (@mod(@as(usize, @intCast(region.dst_offset.x)), block_width) == 0);

    const is_entire_slice = is_entire_row and
        (region.extent.height == src_extent.height) and
        (region.extent.height == dst_extent.height) and
        (@mod(@as(usize, @intCast(region.src_offset.y)), block_height) == 0) and
        (@mod(@as(usize, @intCast(region.dst_offset.y)), block_height) == 0) and
        (src_depth_pitch_bytes == dst_depth_pitch_bytes);

    const src_texel_offset = try self.getTexelMemoryOffset(region.src_offset, .{
        .aspect_mask = region.src_subresource.aspect_mask,
        .mip_level = region.src_subresource.mip_level,
        .array_layer = region.src_subresource.base_array_layer,
    });
    var src_map = try self.mapAsSliceWithAddedOffset(u8, src_texel_offset, vk.WHOLE_SIZE);

    const dst_texel_offset = try dst.getTexelMemoryOffset(region.dst_offset, .{
        .aspect_mask = region.dst_subresource.aspect_mask,
        .mip_level = region.dst_subresource.mip_level,
        .array_layer = region.dst_subresource.base_array_layer,
    });
    var dst_map = try dst.mapAsSliceWithAddedOffset(u8, dst_texel_offset, vk.WHOLE_SIZE);

    for (0..layer_count) |_| {
        if (is_single_row) {
            const copy_size = copy_block_width * bytes_per_block;
            if (dst_map.len < copy_size or src_map.len < copy_size)
                break;
            @memcpy(dst_map[0..copy_size], src_map[0..copy_size]);
        } else if (is_entire_row and is_single_slice) {
            const copy_size = copy_block_height * src_row_pitch_bytes;
            if (dst_map.len < copy_size or src_map.len < copy_size)
                break;
            @memcpy(dst_map[0..copy_size], src_map[0..copy_size]);
        } else if (is_entire_slice) {
            const copy_size = slice_count * src_depth_pitch_bytes;
            if (dst_map.len < copy_size or src_map.len < copy_size)
                break;
            @memcpy(dst_map[0..copy_size], src_map[0..copy_size]);
        } else if (is_entire_row) {
            const slice_size = copy_block_height * src_row_pitch_bytes;
            var src_slice_memory = src_map[0..];
            var dst_slice_memory = dst_map[0..];

            for (0..slice_count) |_| {
                if (dst_slice_memory.len < slice_size or src_slice_memory.len < slice_size)
                    break;
                @memcpy(dst_slice_memory[0..slice_size], src_slice_memory[0..slice_size]);
                src_slice_memory = if (src_slice_memory.len < src_depth_pitch_bytes) break else src_slice_memory[src_depth_pitch_bytes..];
                dst_slice_memory = if (dst_slice_memory.len < dst_depth_pitch_bytes) break else dst_slice_memory[dst_depth_pitch_bytes..];
            }
        } else {
            const row_size = copy_block_width * bytes_per_block;
            var src_slice_memory = src_map[0..];
            var dst_slice_memory = dst_map[0..];

            for (0..slice_count) |_| {
                var src_row_memory = src_slice_memory[0..];
                var dst_row_memory = dst_slice_memory[0..];

                for (0..copy_block_height) |_| {
                    if (dst_row_memory.len < row_size or src_row_memory.len < row_size)
                        break;
                    @memcpy(dst_row_memory[0..row_size], src_row_memory[0..row_size]);
                    src_row_memory = if (src_row_memory.len < src_row_pitch_bytes) break else src_row_memory[src_row_pitch_bytes..];
                    dst_row_memory = if (dst_row_memory.len < dst_row_pitch_bytes) break else dst_row_memory[dst_row_pitch_bytes..];
                }

                src_slice_memory = if (src_slice_memory.len < src_depth_pitch_bytes) break else src_slice_memory[src_depth_pitch_bytes..];
                dst_slice_memory = if (dst_slice_memory.len < dst_depth_pitch_bytes) break else dst_slice_memory[dst_depth_pitch_bytes..];
            }
        }

        src_map = if (src_map.len < src_layer_pitch) break else src_map[src_layer_pitch..];
        dst_map = if (dst_map.len < dst_layer_pitch) break else dst_map[dst_layer_pitch..];
    }
}

pub fn copyToBuffer(self: *const Self, dst: *SoftBuffer, region: vk.BufferImageCopy) VkError!void {
    const dst_offset = dst.interface.offset + region.buffer_offset;
    const dst_map = try dst.mapAsSliceWithOffset(u8, dst_offset, vk.WHOLE_SIZE);
    try self.copy(
        null,
        dst_map,
        region.image_subresource,
        region.image_offset,
        region.image_extent,
        region.buffer_row_length,
        region.buffer_image_height,
    );
}

pub fn copyFromBuffer(self: *const Self, src: *const SoftBuffer, region: vk.BufferImageCopy) VkError!void {
    const src_offset = src.interface.offset + region.buffer_offset;
    const src_map = try src.mapAsSliceWithOffset(u8, src_offset, vk.WHOLE_SIZE);
    try self.copy(
        src_map,
        null,
        region.image_subresource,
        region.image_offset,
        region.image_extent,
        region.buffer_row_length,
        region.buffer_image_height,
    );
}

pub fn copyToMemory(interface: *const Interface, memory: []u8, subresource: vk.ImageSubresourceLayers) VkError!void {
    const self: *const Self = @alignCast(@fieldParentPtr("interface", interface));
    try self.copy(null, memory, subresource, .{ .x = 0, .y = 0, .z = 0 }, interface.extent, 0, 0);
}

pub fn copy(
    self: *const Self,
    base_src_memory: ?[]const u8,
    base_dst_memory: ?[]u8,
    image_subresource: vk.ImageSubresourceLayers,
    image_offset: vk.Offset3D,
    image_extent: vk.Extent3D,
    row_length: u32,
    image_height: u32,
) VkError!void {
    std.debug.assert((base_src_memory == null) != (base_dst_memory == null));

    const is_source: bool = base_src_memory != null;

    if (image_subresource.aspect_mask.subtract(.{
        .color_bit = true,
        .depth_bit = true,
        .stencil_bit = true,
    }).toInt() != 0) {
        base.unsupported("aspectMask {f}", .{image_subresource.aspect_mask});
        return VkError.ValidationFailed;
    }

    const format = self.interface.formatFromAspect(image_subresource.aspect_mask);

    if (image_extent.width == 0 or image_extent.height == 0 or image_extent.depth == 0) {
        return;
    }

    const extent: vk.Extent2D = .{
        .width = if (row_length == 0) image_extent.width else row_length,
        .height = if (image_height == 0) image_extent.height else image_height,
    };

    const bytes_per_block = base.format.texelSize(format);
    const copy_block_width = base.format.blockCountX(format, image_extent.width);
    const copy_block_height = base.format.blockCountY(format, image_extent.height);
    const memory_block_width = base.format.blockCountX(format, extent.width);
    const memory_block_height = base.format.blockCountY(format, extent.height);
    const memory_row_pitch_bytes = memory_block_width * bytes_per_block;
    const memory_slice_pitch_bytes = memory_block_height * memory_row_pitch_bytes;

    const image_texel_offset = try self.getTexelMemoryOffset(image_offset, .{
        .aspect_mask = image_subresource.aspect_mask,
        .mip_level = image_subresource.mip_level,
        .array_layer = image_subresource.base_array_layer,
    });
    const image_map = try self.mapAsSliceWithAddedOffset(u8, image_texel_offset, vk.WHOLE_SIZE);

    var src_memory = if (is_source) base_src_memory orelse return VkError.InvalidDeviceMemoryDrv else image_map;
    var dst_memory = if (is_source) image_map else base_dst_memory orelse return VkError.InvalidDeviceMemoryDrv;

    const src_slice_pitch_bytes = if (is_source) memory_slice_pitch_bytes else self.interface.getSliceMemSizeForMipLevel(image_subresource.aspect_mask, image_subresource.mip_level);
    const dst_slice_pitch_bytes = if (is_source) self.interface.getSliceMemSizeForMipLevel(image_subresource.aspect_mask, image_subresource.mip_level) else memory_slice_pitch_bytes;
    const src_row_pitch_bytes = if (is_source) memory_row_pitch_bytes else self.interface.getRowPitchMemSizeForMipLevel(image_subresource.aspect_mask, image_subresource.mip_level);
    const dst_row_pitch_bytes = if (is_source) self.interface.getRowPitchMemSizeForMipLevel(image_subresource.aspect_mask, image_subresource.mip_level) else memory_row_pitch_bytes;

    const src_layer_size = if (is_source) memory_slice_pitch_bytes else self.getLayerSize(image_subresource.aspect_mask);
    const dst_layer_size = if (is_source) self.getLayerSize(image_subresource.aspect_mask) else memory_slice_pitch_bytes;

    const layer_count = if (image_subresource.layer_count == vk.REMAINING_ARRAY_LAYERS) self.interface.array_layers - image_subresource.base_array_layer else image_subresource.layer_count;

    const copy_size = copy_block_width * bytes_per_block;

    for (0..layer_count) |_| {
        var src_layer_memory = src_memory[0..];
        var dst_layer_memory = dst_memory[0..];

        for (0..image_extent.depth) |_| {
            var src_slice_memory = src_layer_memory[0..];
            var dst_slice_memory = dst_layer_memory[0..];

            for (0..copy_block_height) |_| {
                if (dst_slice_memory.len < copy_size or src_slice_memory.len < copy_size)
                    break;
                @memcpy(dst_slice_memory[0..copy_size], src_slice_memory[0..copy_size]);
                src_slice_memory = if (src_slice_memory.len < src_row_pitch_bytes) break else src_slice_memory[src_row_pitch_bytes..];
                dst_slice_memory = if (dst_slice_memory.len < dst_row_pitch_bytes) break else dst_slice_memory[dst_row_pitch_bytes..];
            }
            src_layer_memory = if (src_layer_memory.len < src_slice_pitch_bytes) break else src_layer_memory[src_slice_pitch_bytes..];
            dst_layer_memory = if (dst_layer_memory.len < dst_slice_pitch_bytes) break else dst_layer_memory[dst_slice_pitch_bytes..];
        }
        src_memory = if (src_memory.len < src_layer_size) break else src_memory[src_layer_size..];
        dst_memory = if (dst_memory.len < dst_layer_size) break else dst_memory[dst_layer_size..];
    }
}

pub fn readFloat4(self: *Self, offset: vk.Offset3D, subresource: vk.ImageSubresource, format: vk.Format) VkError!F32x4 {
    const texel_size = base.format.texelSize(format);
    const texel_offset = try self.getTexelMemoryOffset(offset, subresource);
    const map = try self.mapAsSliceWithAddedOffset(u8, texel_offset, texel_size);
    if (base.format.isCompressed(format)) {
        return compressed.readFloat4(
            map,
            format,
            @mod(@as(usize, @intCast(offset.x)), base.format.blockWidth(format)),
            @mod(@as(usize, @intCast(offset.y)), base.format.blockHeight(format)),
        );
    }
    return blitter.readFloat4(map, format);
}

pub fn readInt4(self: *Self, offset: vk.Offset3D, subresource: vk.ImageSubresource, format: vk.Format) VkError!U32x4 {
    const texel_size = base.format.texelSize(format);
    const texel_offset = try self.getTexelMemoryOffset(offset, subresource);
    const map = try self.mapAsSliceWithAddedOffset(u8, texel_offset, texel_size);
    return blitter.readInt4(map, format);
}

pub fn writeFloat4(self: *Self, offset: vk.Offset3D, subresource: vk.ImageSubresource, format: vk.Format, pixel: F32x4) VkError!void {
    const texel_size = base.format.texelSize(format);
    const texel_offset = try self.getTexelMemoryOffset(offset, subresource);
    const map = try self.mapAsSliceWithAddedOffset(u8, texel_offset, texel_size);
    if (base.format.isCompressed(format)) {
        compressed.writeFloat4(
            map,
            format,
            @mod(@as(usize, @intCast(offset.x)), base.format.blockWidth(format)),
            @mod(@as(usize, @intCast(offset.y)), base.format.blockHeight(format)),
            pixel,
        );
        return;
    }
    blitter.writeFloat4(pixel, map, format);
}

pub fn writeInt4(self: *Self, offset: vk.Offset3D, subresource: vk.ImageSubresource, format: vk.Format, pixel: U32x4) VkError!void {
    const texel_size = base.format.texelSize(format);
    const texel_offset = try self.getTexelMemoryOffset(offset, subresource);
    const map = try self.mapAsSliceWithAddedOffset(u8, texel_offset, texel_size);
    blitter.writeInt4(pixel, map, format);
}

pub fn getTexelMemoryOffsetInSubresource(self: *const Self, offset: vk.Offset3D, subresource: vk.ImageSubresource) usize {
    const format = base.format.fromAspect(self.interface.format, subresource.aspect_mask);
    return @as(usize, @intCast(offset.z)) * self.interface.getSliceMemSizeForMipLevel(subresource.aspect_mask, subresource.mip_level) +
        @divFloor(@as(usize, @intCast(offset.y)), base.format.blockHeight(format)) * self.interface.getRowPitchMemSizeForMipLevel(subresource.aspect_mask, subresource.mip_level) +
        @divFloor(@as(usize, @intCast(offset.x)), base.format.blockWidth(format)) * base.format.texelSize(format);
}

pub fn getTexelMemoryOffset(self: *const Self, offset: vk.Offset3D, subresource: vk.ImageSubresource) VkError!usize {
    return try self.getSubresourceOffset(subresource.aspect_mask, subresource.mip_level, subresource.array_layer) + self.getTexelMemoryOffsetInSubresource(offset, subresource);
}

pub fn getSubresourceOffset(self: *const Self, aspect_mask: vk.ImageAspectFlags, mip_level: u32, layer: u32) VkError!usize {
    var offset = try self.getAspectOffset(aspect_mask);
    for (0..mip_level) |mip| {
        offset += self.getMultiSampledLevelSize(aspect_mask, @intCast(mip));
    }

    const is_3D = (self.interface.image_type == .@"3d") and self.interface.flags.@"2d_array_compatible_bit";
    const layer_offset = if (is_3D)
        self.interface.getSliceMemSizeForMipLevel(aspect_mask, mip_level)
    else
        self.getLayerSize(aspect_mask);
    return offset + layer * layer_offset;
}

fn getAspectOffset(self: *const Self, aspect_mask: vk.ImageAspectFlags) VkError!usize {
    return switch (self.interface.format) {
        .d16_unorm_s8_uint,
        .d24_unorm_s8_uint,
        .d32_sfloat_s8_uint,
        => if (aspect_mask.stencil_bit)
            try self.interface.getTotalSizeForAspect(.{ .depth_bit = true })
        else
            0,
        else => 0,
    };
}

fn getTotalSizeForAspect(interface: *const Interface, aspect_mask: vk.ImageAspectFlags) VkError!usize {
    const self: *const Self = @alignCast(@fieldParentPtr("interface", interface));

    if (aspect_mask.subtract(.{
        .color_bit = true,
        .depth_bit = true,
        .stencil_bit = true,
    }).toInt() != 0) {
        base.unsupported("aspectMask {f}", .{aspect_mask});
        return VkError.ValidationFailed;
    }

    var size: usize = 0;

    if (aspect_mask.color_bit)
        size += self.getLayerSize(.{ .color_bit = true });
    if (aspect_mask.depth_bit)
        size += self.getLayerSize(.{ .depth_bit = true });
    if (aspect_mask.stencil_bit)
        size += self.getLayerSize(.{ .stencil_bit = true });

    return size * self.interface.array_layers;
}

fn getSubresourceLayout(interface: *const Interface, subresource: vk.ImageSubresource) VkError!vk.SubresourceLayout {
    const self: *const Self = @alignCast(@fieldParentPtr("interface", interface));

    if (subresource.aspect_mask.subtract(.{
        .color_bit = true,
        .depth_bit = true,
        .stencil_bit = true,
    }).toInt() != 0) {
        base.unsupported("aspectMask {f}", .{subresource.aspect_mask});
        return VkError.ValidationFailed;
    }

    return .{
        .offset = try self.getSubresourceOffset(subresource.aspect_mask, subresource.mip_level, subresource.array_layer),
        .size = self.getMultiSampledLevelSize(subresource.aspect_mask, subresource.mip_level),
        .row_pitch = self.interface.getRowPitchMemSizeForMipLevel(subresource.aspect_mask, subresource.mip_level),
        .array_pitch = self.getLayerSize(subresource.aspect_mask),
        .depth_pitch = self.interface.getSliceMemSizeForMipLevel(subresource.aspect_mask, subresource.mip_level),
    };
}

pub fn getLayerSize(self: *const Self, aspect_mask: vk.ImageAspectFlags) usize {
    var size: usize = 0;
    for (0..self.interface.mip_levels) |mip_level| {
        size += self.getMultiSampledLevelSize(aspect_mask, @intCast(mip_level));
    }
    return size;
}

pub inline fn getMultiSampledLevelSize(self: *const Self, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    return self.getMipLevelSize(aspect_mask, mip_level) * self.interface.samples.toInt();
}

pub inline fn getMipLevelSize(self: *const Self, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    return self.interface.getSliceMemSizeForMipLevel(aspect_mask, mip_level) * self.getMipLevelExtent(mip_level).depth;
}

pub fn getMipLevelExtent(self: *const Self, mip_level: u32) vk.Extent3D {
    var extent: vk.Extent3D = .{
        .width = self.interface.extent.width >> @intCast(mip_level),
        .height = self.interface.extent.height >> @intCast(mip_level),
        .depth = self.interface.extent.depth >> @intCast(mip_level),
    };

    if (extent.width == 0) extent.width = 1;
    if (extent.height == 0) extent.height = 1;
    if (extent.depth == 0) extent.depth = 1;

    return extent;
}

pub fn getSliceMemSizeForMipLevel(interface: *const Interface, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    const self: *const Self = @alignCast(@fieldParentPtr("interface", interface));
    return self.getSliceMemSizeForMipLevelWithFormat(aspect_mask, mip_level, interface.format);
}

pub fn getRowPitchMemSizeForMipLevel(interface: *const Interface, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    const self: *const Self = @alignCast(@fieldParentPtr("interface", interface));
    return self.getRowPitchMemSizeForMipLevelWithFormat(aspect_mask, mip_level, interface.format);
}

pub fn getSliceMemSizeForMipLevelWithFormat(self: *const Self, aspect_mask: vk.ImageAspectFlags, mip_level: u32, format: vk.Format) usize {
    const mip_extent = self.getMipLevelExtent(mip_level);
    return base.format.sliceMemSize(base.format.fromAspect(format, aspect_mask), mip_extent.width, mip_extent.height);
}

pub fn getRowPitchMemSizeForMipLevelWithFormat(self: *const Self, aspect_mask: vk.ImageAspectFlags, mip_level: u32, format: vk.Format) usize {
    const mip_extent = self.getMipLevelExtent(mip_level);
    return base.format.pitchMemSize(base.format.fromAspect(format, aspect_mask), mip_extent.width);
}

pub inline fn mapAs(self: *const Self, comptime T: type) VkError!*T {
    return self.mapAsWithAddedOffset(T, 0);
}

pub inline fn mapTo(self: *const Self, comptime T: type) VkError!T {
    return self.mapToWithAddedOffset(T, 0);
}

pub inline fn mapAsSlice(self: *const Self, comptime T: type, size: usize) VkError![]T {
    return self.mapAsSliceWithAddedOffset(T, 0, size);
}

pub inline fn mapAsWithAddedOffset(self: *const Self, comptime T: type, offset: usize) VkError!*T {
    return self.mapAsWithOffset(T, self.interface.memory_offset + offset);
}

pub inline fn mapToWithAddedOffset(self: *const Self, comptime T: type, offset: usize) VkError!T {
    return self.mapToWithOffset(T, self.interface.memory_offset + offset);
}

pub inline fn mapAsSliceWithAddedOffset(self: *const Self, comptime T: type, offset: usize, size: usize) VkError![]T {
    return self.mapAsSliceWithOffset(T, self.interface.memory_offset + offset, size);
}

pub fn mapAsWithOffset(self: *const Self, comptime T: type, offset: usize) VkError!*T {
    const memory = if (self.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    const map = try memory.map(offset, @sizeOf(T));
    return @alignCast(std.mem.bytesAsValue(T, map));
}

pub fn mapToWithOffset(self: *const Self, comptime T: type, offset: usize) VkError!T {
    const memory = if (self.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    const map = try memory.map(offset, @sizeOf(T));
    return std.mem.bytesToValue(T, map);
}

pub fn mapAsSliceWithOffset(self: *const Self, comptime T: type, offset: usize, size: usize) VkError![]T {
    const memory = if (self.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    const map = try memory.map(offset, size);
    return @alignCast(std.mem.bytesAsSlice(T, map));
}
