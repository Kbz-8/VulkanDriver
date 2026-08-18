const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const proto = @import("lib.zig").proto;

const PhiDeviceMemory = @import("PhiDeviceMemory.zig");

const VkError = base.VkError;

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
    requirements.alignment = proto.PHI_MEMORY_ALIGNMENT;
    requirements.size = std.mem.alignForward(vk.DeviceSize, requirements.size, proto.PHI_MEMORY_ALIGNMENT);
}

pub fn copyToMemory(interface: *const Interface, dst: []u8, subresource: vk.ImageSubresourceLayers) VkError!void {
    const self: *const Self = @alignCast(@fieldParentPtr("interface", interface));
    const memory_interface = interface.memory orelse return VkError.InvalidDeviceMemoryDrv;
    const memory: *PhiDeviceMemory = @alignCast(@fieldParentPtr("interface", memory_interface));
    const data = memory.data orelse return VkError.InvalidDeviceMemoryDrv;

    try validateSingleAspect(interface.format, subresource.aspect_mask);
    if (subresource.mip_level >= interface.mip_levels or
        subresource.base_array_layer >= interface.array_layers or
        subresource.layer_count == 0)
        return VkError.ValidationFailed;

    const layer_count = if (subresource.layer_count == vk.REMAINING_ARRAY_LAYERS)
        interface.array_layers - subresource.base_array_layer
    else
        subresource.layer_count;
    if (layer_count > interface.array_layers - subresource.base_array_layer)
        return VkError.ValidationFailed;

    const level_size = self.getMultiSampledLevelSize(subresource.aspect_mask, subresource.mip_level);
    const required_size, const size_overflow = @mulWithOverflow(level_size, @as(usize, layer_count));
    if (size_overflow != 0 or dst.len < required_size)
        return VkError.ValidationFailed;

    const first_offset = try self.getSubresourceOffset(
        subresource.aspect_mask,
        subresource.mip_level,
        subresource.base_array_layer,
    );
    const absolute_offset, const offset_overflow = @addWithOverflow(interface.memory_offset, first_offset);
    if (offset_overflow != 0)
        return VkError.ValidationFailed;

    var src_offset = std.math.cast(usize, absolute_offset) orelse return VkError.InvalidDeviceMemoryDrv;
    var dst_offset: usize = 0;
    const layer_pitch = self.getLayerSize(subresource.aspect_mask);

    for (0..layer_count) |_| {
        if (src_offset > data.len or level_size > data.len - src_offset)
            return VkError.InvalidDeviceMemoryDrv;
        @memcpy(dst[dst_offset..][0..level_size], data[src_offset..][0..level_size]);
        dst_offset += level_size;
        src_offset += layer_pitch;
    }
}

pub fn getSubresourceOffset(self: *const Self, aspect_mask: vk.ImageAspectFlags, mip_level: u32, layer: u32) VkError!usize {
    if (mip_level >= self.interface.mip_levels or layer >= self.interface.array_layers)
        return VkError.ValidationFailed;

    var offset = try self.getAspectOffset(aspect_mask);
    offset += layer * self.getLayerSize(aspect_mask);
    for (0..mip_level) |mip|
        offset += self.getMultiSampledLevelSize(aspect_mask, @intCast(mip));
    return offset;
}

fn getAspectOffset(self: *const Self, aspect_mask: vk.ImageAspectFlags) VkError!usize {
    try validateSingleAspect(self.interface.format, aspect_mask);
    return switch (self.interface.format) {
        .d16_unorm_s8_uint,
        .d24_unorm_s8_uint,
        .d32_sfloat_s8_uint,
        => if (aspect_mask.stencil_bit)
            self.interface.getTotalSizeForAspect(.{ .depth_bit = true })
        else
            0,
        else => 0,
    };
}

pub fn getTotalSizeForAspect(interface: *const Interface, aspect_mask: vk.ImageAspectFlags) VkError!usize {
    const self: *const Self = @alignCast(@fieldParentPtr("interface", interface));
    const valid_aspects = base.format.toAspect(interface.format);
    if (aspect_mask.toInt() == 0 or aspect_mask.subtract(valid_aspects).toInt() != 0)
        return VkError.ValidationFailed;

    var size: usize = 0;
    if (aspect_mask.color_bit)
        size += self.getLayerSize(.{ .color_bit = true });
    if (aspect_mask.depth_bit)
        size += self.getLayerSize(.{ .depth_bit = true });
    if (aspect_mask.stencil_bit)
        size += self.getLayerSize(.{ .stencil_bit = true });
    return size * interface.array_layers;
}

pub fn getSubresourceLayout(interface: *const Interface, subresource: vk.ImageSubresource) VkError!vk.SubresourceLayout {
    const self: *const Self = @alignCast(@fieldParentPtr("interface", interface));
    try validateSingleAspect(interface.format, subresource.aspect_mask);

    return .{
        .offset = try self.getSubresourceOffset(subresource.aspect_mask, subresource.mip_level, subresource.array_layer),
        .size = self.getMultiSampledLevelSize(subresource.aspect_mask, subresource.mip_level),
        .row_pitch = getRowPitchMemSizeForMipLevel(interface, subresource.aspect_mask, subresource.mip_level),
        .array_pitch = self.getLayerSize(subresource.aspect_mask),
        .depth_pitch = getSliceMemSizeForMipLevel(interface, subresource.aspect_mask, subresource.mip_level),
    };
}

pub fn getLayerSize(self: *const Self, aspect_mask: vk.ImageAspectFlags) usize {
    var size: usize = 0;
    for (0..self.interface.mip_levels) |mip_level|
        size += self.getMultiSampledLevelSize(aspect_mask, @intCast(mip_level));
    return size;
}

pub inline fn getMultiSampledLevelSize(self: *const Self, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    return self.getMipLevelSize(aspect_mask, mip_level) * self.interface.samples.toInt();
}

pub inline fn getMipLevelSize(self: *const Self, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    return getSliceMemSizeForMipLevel(&self.interface, aspect_mask, mip_level) * self.getMipLevelExtent(mip_level).depth;
}

pub fn getMipLevelExtent(self: *const Self, mip_level: u32) vk.Extent3D {
    return .{
        .width = @max(1, self.interface.extent.width >> @intCast(mip_level)),
        .height = @max(1, self.interface.extent.height >> @intCast(mip_level)),
        .depth = @max(1, self.interface.extent.depth >> @intCast(mip_level)),
    };
}

pub fn getSliceMemSizeForMipLevel(interface: *const Interface, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    const self: *const Self = @alignCast(@fieldParentPtr("interface", interface));
    const extent = self.getMipLevelExtent(mip_level);
    return base.format.sliceMemSize(base.format.fromAspect(interface.format, aspect_mask), extent.width, extent.height);
}

pub fn getRowPitchMemSizeForMipLevel(interface: *const Interface, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    const self: *const Self = @alignCast(@fieldParentPtr("interface", interface));
    const extent = self.getMipLevelExtent(mip_level);
    return base.format.pitchMemSize(base.format.fromAspect(interface.format, aspect_mask), extent.width);
}

fn validateSingleAspect(format: vk.Format, aspect_mask: vk.ImageAspectFlags) VkError!void {
    const valid_aspects = base.format.toAspect(format);
    if (aspect_mask.toInt() == 0 or @popCount(aspect_mask.toInt()) != 1 or aspect_mask.subtract(valid_aspects).toInt() != 0)
        return VkError.ValidationFailed;
}
