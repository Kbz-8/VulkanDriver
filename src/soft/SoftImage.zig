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

pub fn copyImageToBuffer(self: *const Self, self_layout: vk.ImageLayout, dst: *SoftBuffer, regions: []const vk.BufferImageCopy) VkError!void {
    _ = self_layout;
    for (regions) |region| {
        const src_memory = if (self.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
        const dst_memory = if (dst.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;

        const pixel_size: u32 = @intCast(self.interface.getPixelSize());
        const image_row_pitch: u32 = self.interface.extent.width * pixel_size;
        const image_size: u32 = @intCast(self.interface.getTotalSize());

        const buffer_row_length: u32 = if (region.buffer_row_length != 0) region.buffer_row_length else region.image_extent.width;
        const buffer_row_pitch: u32 = buffer_row_length * pixel_size;
        const buffer_size: u32 = buffer_row_pitch * region.image_extent.height * region.image_extent.depth;

        const src_map: []u8 = @as([*]u8, @ptrCast(try src_memory.map(0, image_size)))[0..image_size];
        const dst_map: []u8 = @as([*]u8, @ptrCast(try dst_memory.map(region.buffer_offset, buffer_size)))[0..buffer_size];

        const row_size = region.image_extent.width * pixel_size;
        for (0..self.interface.extent.depth) |z| {
            for (0..self.interface.extent.height) |y| {
                const z_as_u32: u32 = @intCast(z);
                const y_as_u32: u32 = @intCast(y);

                const src_offset = ((@as(u32, @intCast(region.image_offset.z)) + z_as_u32) * self.interface.extent.height + @as(u32, @intCast(region.image_offset.y)) + y_as_u32) * image_row_pitch + @as(u32, @intCast(region.image_offset.x)) * pixel_size;
                const dst_offset = (z_as_u32 * buffer_row_length * region.image_extent.height + y_as_u32 * buffer_row_length) * pixel_size;

                const src_slice = src_map[src_offset..(src_offset + row_size)];
                const dst_slice = dst_map[dst_offset..(dst_offset + row_size)];
                @memcpy(dst_slice, src_slice);
            }
        }

        src_memory.unmap();
        dst_memory.unmap();
    }
}
