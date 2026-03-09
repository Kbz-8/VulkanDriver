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

pub fn getMemoryRequirements(interface: *Interface, requirements: *vk.MemoryRequirements) void {
    _ = interface;
    requirements.alignment = lib.MEMORY_REQUIREMENTS_IMAGE_ALIGNMENT;
}

inline fn clear(self: *Self, pixel: vk.ClearValue, format: vk.Format, view_format: vk.Format, range: vk.ImageSubresourceRange, area: ?vk.Rect2D) void {
    const soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", self.interface.owner));
    soft_device.blitter.clear(pixel, format, self, view_format, range, area);
}

pub fn clearRange(self: *Self, color: vk.ClearColorValue, range: vk.ImageSubresourceRange) void {
    std.debug.assert(range.aspect_mask == vk.ImageAspectFlags{ .color_bit = true });

    const clear_format: vk.Format = if (base.vku.vkuFormatIsSINT(@intCast(@intFromEnum(self.interface.format))))
        .r32g32b32a32_sint
    else if (base.vku.vkuFormatIsUINT(@intCast(@intFromEnum(self.interface.format))))
        .r32g32b32a32_uint
    else
        .r32g32b32a32_sfloat;
    self.clear(.{ .color = color }, clear_format, self.interface.format, range, null);
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
    const dst_memory = if (dst.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    const dst_map: []u8 = @as([*]u8, @ptrCast(try dst_memory.map(region.buffer_offset, dst_size)))[0..dst_size];
    try self.copy(
        null,
        dst_map,
        @intCast(region.buffer_row_length),
        @intCast(region.buffer_image_height),
        region.image_subresource,
        region.image_offset,
        region.image_extent,
    );
}

pub fn copyFromBuffer(self: *const Self, src: *SoftBuffer, region: vk.BufferImageCopy) VkError!void {
    const src_size = src.interface.size - region.buffer_offset;
    const src_memory = if (src.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    const src_map: []u8 = @as([*]u8, @ptrCast(try src_memory.map(region.buffer_offset, src_size)))[0..src_size];
    try self.copy(
        src_map,
        null,
        @intCast(region.buffer_row_length),
        @intCast(region.buffer_image_height),
        region.image_subresource,
        region.image_offset,
        region.image_extent,
    );
}

pub fn copy(
    self: *Self,
    src_memory: ?[]const u8,
    dst_memory: ?[]u8,
    row_len: usize,
    image_height: usize,
    image_subresource: vk.ImageSubresourceLayers,
    image_copy_offset: vk.Offset3D,
    image_copy_extent: vk.Extent3D,
) VkError!void {
    _ = self;
    _ = src_memory;
    _ = dst_memory;
    _ = row_len;
    _ = image_height;
    _ = image_subresource;
    _ = image_copy_offset;
    _ = image_copy_extent;
}
