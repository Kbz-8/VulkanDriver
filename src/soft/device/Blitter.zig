//! This software blitter is highly inspired by SwiftShaders one

const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

pub const SoftImage = @import("../SoftImage.zig");
pub const SoftImageView = @import("../SoftImageView.zig");

const Self = @This();

blit_mutex: std.Thread.Mutex,

pub const init: Self = .{
    .blit_mutex = .{},
};

pub fn clear(self: *Self, pixel: vk.ClearValue, format: vk.Format, dest: *SoftImage, view_format: vk.Format, range: vk.ImageSubresourceRange, area: ?vk.Rect2D) void {
    const dst_format = base.Image.formatFromAspect(view_format, range.aspect_mask);
    if (dst_format == .undefined) {
        return;
    }

    const view_format_value: c_uint = @intCast(@intFromEnum(view_format));

    var clamped_pixel: vk.ClearValue = pixel;
    if (base.vku.vkuFormatIsSINT(view_format_value) or base.vku.vkuFormatIsUINT(view_format_value)) {
        const min_value: f32 = if (base.vku.vkuFormatIsSNORM(view_format_value)) -1.0 else 0.0;

        if (range.aspect_mask.color_bit) {
            clamped_pixel.color.float_32[0] = std.math.clamp(pixel.color.float_32[0], min_value, 1.0);
            clamped_pixel.color.float_32[1] = std.math.clamp(pixel.color.float_32[1], min_value, 1.0);
            clamped_pixel.color.float_32[2] = std.math.clamp(pixel.color.float_32[2], min_value, 1.0);
            clamped_pixel.color.float_32[3] = std.math.clamp(pixel.color.float_32[3], min_value, 1.0);
        }

        // Stencil never requires clamping, so we can check for Depth only
        if (range.aspect_mask.depth_bit) {
            clamped_pixel.depth_stencil.depth = std.math.clamp(pixel.depth_stencil.depth, min_value, 1.0);
        }
    }

    if (self.fastClear(clamped_pixel, format, dest, dst_format, range, area)) {
        return;
    }
    base.logger.fixme("implement slow clear", .{});
}

fn fastClear(self: *Self, clear_value: vk.ClearValue, clear_format: vk.Format, dest: *SoftImage, view_format: vk.Format, range: vk.ImageSubresourceRange, render_area: ?vk.Rect2D) bool {
    _ = self;
    _ = render_area;
    _ = range;

    if (clear_format != .r32g32b32a32_sfloat and clear_format != .d32_sfloat and clear_format != .s8_uint) {
        return false;
    }

    const ClearValue = union {
        rgba: struct { r: f32, g: f32, b: f32, a: f32 },
        rgb: [3]f32,
        d: f32,
        d_as_u32: u32,
        s: u32,
    };

    const c: *const ClearValue = @ptrCast(&clear_value);

    var pack: u32 = 0;
    switch (view_format) {
        .r5g6b5_unorm_pack16 => pack = @as(u16, @intFromFloat(31.0 * c.rgba.b + 0.5)) | (@as(u16, @intFromFloat(63.0 * c.rgba.g + 0.5)) << 5) | (@as(u16, @intFromFloat(31.0 * c.rgba.r + 0.5)) << 11),
        .b5g6r5_unorm_pack16 => pack = @as(u16, @intFromFloat(31.0 * c.rgba.r + 0.5)) | (@as(u16, @intFromFloat(63.0 * c.rgba.g + 0.5)) << 5) | (@as(u16, @intFromFloat(31.0 * c.rgba.b + 0.5)) << 11),

        .a8b8g8r8_uint_pack32,
        .a8b8g8r8_unorm_pack32,
        .r8g8b8a8_unorm,
        => pack = (@as(u32, @intFromFloat(255.0 * c.rgba.a + 0.5)) << 24) | (@as(u32, @intFromFloat(255.0 * c.rgba.b + 0.5)) << 16) | (@as(u32, @intFromFloat(255.0 * c.rgba.g + 0.5)) << 8) | @as(u32, @intFromFloat(255.0 * c.rgba.r + 0.5)),

        .b8g8r8a8_unorm => pack = (@as(u32, @intFromFloat(255.0 * c.rgba.a + 0.5)) << 24) | (@as(u32, @intFromFloat(255.0 * c.rgba.r + 0.5)) << 16) | (@as(u32, @intFromFloat(255.0 * c.rgba.g + 0.5)) << 8) | @as(u32, @intFromFloat(255.0 * c.rgba.b + 0.5)),
        //.b10g11r11_ufloat_pack32 => pack = R11G11B10F(c.rgb),
        //.e5b9g9r9_ufloat_pack32 => pack = RGB9E5(c.rgb),
        .d32_sfloat => {
            std.debug.assert(clear_format == .d32_sfloat);
            pack = c.d_as_u32; // float reinterpreted as uint32
        },
        .s8_uint => {
            std.debug.assert(clear_format == .s8_uint);
            pack = @as(u8, @intCast(c.s));
        },
        else => return false,
    }

    if (dest.interface.memory) |memory| {
        const image_size = dest.interface.getTotalSize();
        const memory_map = memory.map(dest.interface.memory_offset, image_size) catch return false;
        defer memory.unmap();

        const memory_map_as_u32: []u32 = @as([*]u32, @ptrCast(@alignCast(memory_map)))[0..@divExact(image_size, 4)];

        @memset(memory_map_as_u32, pack);

        return true;
    }
    return false;
}
