const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const lib = @import("lib.zig");

const VkError = base.VkError;
const Device = base.Device;

const SoftBuffer = @import("SoftBuffer.zig");
const SoftDevice = @import("SoftDevice.zig");

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
        .getTotalSizeForAspect = getTotalSizeForAspect,
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

inline fn clear(self: *Self, pixel: vk.ClearValue, format: vk.Format, view_format: vk.Format, range: vk.ImageSubresourceRange, area: ?vk.Rect2D) VkError!void {
    const soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", self.interface.owner));
    try soft_device.blitter.clear(pixel, format, self, view_format, range, area);
}

pub fn clearRange(self: *Self, color: vk.ClearColorValue, range: vk.ImageSubresourceRange) VkError!void {
    std.debug.assert(range.aspect_mask == vk.ImageAspectFlags{ .color_bit = true });

    const clear_format: vk.Format = if (base.vku.vkuFormatIsSINT(@intCast(@intFromEnum(self.interface.format))))
        .r32g32b32a32_sint
    else if (base.vku.vkuFormatIsUINT(@intCast(@intFromEnum(self.interface.format))))
        .r32g32b32a32_uint
    else
        .r32g32b32a32_sfloat;
    try self.clear(.{ .color = color }, clear_format, self.interface.format, range, null);
}

pub fn copyImage(self: *const Self, self_layout: vk.ImageLayout, dst: *Self, dst_layout: vk.ImageLayout, regions: []const vk.ImageCopy) VkError!void {
    _ = self;
    _ = self_layout;
    _ = dst;
    _ = dst_layout;
    _ = regions;
    std.log.scoped(.commandExecutor).warn("FIXME: implement image to image copy", .{});
}

pub fn copyToBuffer(self: *const Self, dst: *SoftBuffer, region: vk.BufferImageCopy) VkError!void {
    const dst_size = dst.interface.size - region.buffer_offset;
    const dst_offset = dst.interface.offset + region.buffer_offset;
    const dst_memory = if (dst.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    const dst_map: []u8 = @as([*]u8, @ptrCast(try dst_memory.map(dst_offset, dst_size)))[0..dst_size];
    try self.copy(
        null,
        dst_map,
        region.image_subresource,
        region.image_offset,
        region.image_extent,
    );
}

pub fn copyFromBuffer(self: *const Self, src: *const SoftBuffer, region: vk.BufferImageCopy) VkError!void {
    const src_size = src.interface.size - region.buffer_offset;
    const src_offset = src.interface.offset + region.buffer_offset;
    const src_memory = if (src.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    const src_map: []u8 = @as([*]u8, @ptrCast(try src_memory.map(src_offset, src_size)))[0..src_size];
    try self.copy(
        src_map,
        null,
        region.image_subresource,
        region.image_offset,
        region.image_extent,
    );
}

/// Based on SwiftShader vk::Image::copy
pub fn copy(
    self: *const Self,
    base_src_memory: ?[]const u8,
    base_dst_memory: ?[]u8,
    image_subresource: vk.ImageSubresourceLayers,
    image_offset: vk.Offset3D,
    image_extent: vk.Extent3D,
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

    // TODO: handle extent of compressed formats

    if (image_extent.width == 0 or image_extent.height == 0 or image_extent.depth == 0) {
        return;
    }

    const bytes_per_block = base.format.texelSize(format);
    const memory_row_pitch_bytes = image_extent.width * bytes_per_block;
    const memory_slice_pitch_bytes = image_extent.height * memory_row_pitch_bytes;

    const image_texel_offset = try self.getTexelMemoryOffset(image_offset, .{
        .aspect_mask = image_subresource.aspect_mask,
        .mip_level = image_subresource.mip_level,
        .array_layer = image_subresource.base_array_layer,
    });
    const image_size = self.getLayerSize(image_subresource.aspect_mask) - self.getTexelMemoryOffsetInSubresource(image_offset, .{
        .aspect_mask = image_subresource.aspect_mask,
        .mip_level = image_subresource.mip_level,
        .array_layer = image_subresource.base_array_layer,
    });
    const image_memory = if (self.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    const image_map: []u8 = @as([*]u8, @ptrCast(try image_memory.map(self.interface.memory_offset + image_texel_offset, image_size)))[0..image_size];

    var src_memory = if (is_source) base_src_memory orelse return VkError.InvalidDeviceMemoryDrv else image_map;
    var dst_memory = if (is_source) image_map else base_dst_memory orelse return VkError.InvalidDeviceMemoryDrv;

    const src_slice_pitch_bytes = if (is_source) memory_slice_pitch_bytes else self.getSliceMemSizeForMipLevel(image_subresource.aspect_mask, image_subresource.mip_level);
    const dst_slice_pitch_bytes = if (is_source) self.getSliceMemSizeForMipLevel(image_subresource.aspect_mask, image_subresource.mip_level) else memory_slice_pitch_bytes;
    const src_row_pitch_bytes = if (is_source) memory_row_pitch_bytes else self.getRowPitchMemSizeForMipLevel(image_subresource.aspect_mask, image_subresource.mip_level);
    const dst_row_pitch_bytes = if (is_source) self.getRowPitchMemSizeForMipLevel(image_subresource.aspect_mask, image_subresource.mip_level) else memory_row_pitch_bytes;

    const src_layer_size = if (is_source) memory_slice_pitch_bytes else self.getLayerSize(image_subresource.aspect_mask);
    const dst_layer_size = if (is_source) self.getLayerSize(image_subresource.aspect_mask) else memory_slice_pitch_bytes;

    const layer_count = if (image_subresource.layer_count == vk.REMAINING_ARRAY_LAYERS) self.interface.array_layers - image_subresource.base_array_layer else image_subresource.layer_count;

    const copy_size = image_extent.width * bytes_per_block;

    for (0..layer_count) |_| {
        var src_layer_memory = src_memory[0..];
        var dst_layer_memory = dst_memory[0..];

        for (0..image_extent.depth) |_| {
            var src_slice_memory = src_layer_memory[0..];
            var dst_slice_memory = dst_layer_memory[0..];

            for (0..image_extent.height) |_| {
                @memcpy(dst_slice_memory[0..copy_size], src_slice_memory[0..copy_size]);
                src_slice_memory = src_slice_memory[src_row_pitch_bytes..];
                dst_slice_memory = dst_slice_memory[dst_row_pitch_bytes..];
            }
            src_layer_memory = src_layer_memory[src_slice_pitch_bytes..];
            dst_layer_memory = dst_layer_memory[dst_slice_pitch_bytes..];
        }
        src_memory = src_memory[src_layer_size..];
        dst_memory = dst_memory[dst_layer_size..];
    }
}

fn getTexelMemoryOffsetInSubresource(self: *const Self, offset: vk.Offset3D, subresource: vk.ImageSubresource) usize {
    return @as(usize, @intCast(offset.z)) * self.getSliceMemSizeForMipLevel(subresource.aspect_mask, subresource.mip_level) +
        @as(usize, @intCast(offset.y)) * self.getRowPitchMemSizeForMipLevel(subresource.aspect_mask, subresource.mip_level) +
        @as(usize, @intCast(offset.x)) * base.format.texelSize(base.format.fromAspect(self.interface.format, subresource.aspect_mask));
}

fn getTexelMemoryOffset(self: *const Self, offset: vk.Offset3D, subresource: vk.ImageSubresource) VkError!usize {
    return self.getTexelMemoryOffsetInSubresource(offset, subresource) + try self.getSubresourceOffset(subresource.aspect_mask, subresource.mip_level, subresource.array_layer);
}

fn getSubresourceOffset(self: *const Self, aspect_mask: vk.ImageAspectFlags, mip_level: u32, layer: u32) VkError!usize {
    var offset = try self.getAspectOffset(aspect_mask);
    for (0..mip_level) |mip| {
        offset += self.getMultiSampledLevelSize(aspect_mask, @intCast(mip));
    }

    const is_3D = (self.interface.image_type == .@"3d") and self.interface.flags.@"2d_array_compatible_bit";
    const layer_offset = if (is_3D)
        self.getSliceMemSizeForMipLevel(aspect_mask, mip_level)
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

fn getLayerSize(self: *const Self, aspect_mask: vk.ImageAspectFlags) usize {
    var size: usize = 0;
    for (0..self.interface.mip_levels) |mip_level| {
        size += self.getMultiSampledLevelSize(aspect_mask, @intCast(mip_level));
    }
    return size;
}

inline fn getMultiSampledLevelSize(self: *const Self, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    return self.getMipLevelSize(aspect_mask, mip_level) * self.interface.samples.toInt();
}

inline fn getMipLevelSize(self: *const Self, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    return self.getSliceMemSizeForMipLevel(aspect_mask, mip_level) * self.getMipLevelExtent(mip_level).depth;
}

fn getMipLevelExtent(self: *const Self, mip_level: u32) vk.Extent3D {
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

fn getSliceMemSizeForMipLevel(self: *const Self, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    const mip_extent = self.getMipLevelExtent(mip_level);
    const format = self.interface.formatFromAspect(aspect_mask);
    return base.format.sliceMemSize(format, mip_extent.width, mip_extent.height);
}

fn getRowPitchMemSizeForMipLevel(self: *const Self, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    const mip_extent = self.getMipLevelExtent(mip_level);
    const format = self.interface.formatFromAspect(aspect_mask);
    return base.format.pitchMemSize(format, mip_extent.width);
}
