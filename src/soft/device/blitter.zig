//! This software blitter is highly inspired by SwiftShaders one

const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;

const VkError = base.VkError;

pub const SoftImage = @import("../SoftImage.zig");
pub const SoftImageView = @import("../SoftImageView.zig");

const State = struct {
    src_format: vk.Format,
    dst_format: vk.Format,
    filter: vk.Filter,
    allow_srgb_conversion: bool,
    clamp_to_edge: bool,
};

fn computeOffset2D(x: usize, y: usize, pitch_bytes: usize, texel_bytes: usize) usize {
    return y * pitch_bytes + x * texel_bytes;
}

fn computeOffset3D(x: usize, y: usize, z: usize, slice_bytes: usize, pitch_bytes: usize, texel_bytes: usize) usize {
    return z * slice_bytes + y * pitch_bytes + x * texel_bytes;
}

pub fn clear(pixel: vk.ClearValue, format: vk.Format, dest: *SoftImage, view_format: vk.Format, range: vk.ImageSubresourceRange, area: ?vk.Rect2D) VkError!void {
    const dst_format = base.format.fromAspect(view_format, range.aspect_mask);
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

    if (try fastClear(clamped_pixel, format, dest, dst_format, range, area)) {
        return;
    }
    base.logger.fixme("implement slow clear", .{});
}

fn fastClear(clear_value: vk.ClearValue, clear_format: vk.Format, dest: *SoftImage, view_format: vk.Format, range: vk.ImageSubresourceRange, render_area: ?vk.Rect2D) VkError!bool {
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
        const image_size = try dest.interface.getTotalSize();
        const memory_map = memory.map(dest.interface.memory_offset, image_size) catch return false;
        defer memory.unmap();

        const memory_map_as_u32: []u32 = @as([*]u32, @ptrCast(@alignCast(memory_map)))[0..@divExact(image_size, 4)];

        @memset(memory_map_as_u32, pack);

        return true;
    }
    return false;
}

fn sample(src: []const u8, pos: zm.F32x4, dims: zm.F32x4, slice_bytes: usize, pitch_bytes: usize, state: State) zm.F32x4 {
    var color: zm.F32x4 = .{ 0.0, 0.0, 0.0, 1.0 };
    const src_texel_size = base.format.texelSize(state.src_format);

    if (state.filter != .linear or base.format.isUint(state.src_format)) {
        var x: usize = @intFromFloat(pos[0]);
        var y: usize = @intFromFloat(pos[1]);
        var z: usize = @intFromFloat(pos[2]);

        if (state.clamp_to_edge) {
            x = std.math.clamp(x, 0, @as(usize, @intFromFloat(dims[0])) - 1);
            y = std.math.clamp(y, 0, @as(usize, @intFromFloat(dims[1])) - 1);
            z = std.math.clamp(z, 0, @as(usize, @intFromFloat(dims[2])) - 1);
        }

        const src_map = src[computeOffset3D(x, y, z, slice_bytes, pitch_bytes, src_texel_size)..];

        color = readFloat4(src_map, state);
    }

    return applyScaleAndClamp(color, state);
}

pub fn blitRegion(src: *const SoftImage, dst: *SoftImage, region: vk.ImageBlit, filter: vk.Filter) VkError!void {
    var dst_offset_0 = region.dst_offsets[0];
    var dst_offset_1 = region.dst_offsets[1];
    var src_offset_0 = region.src_offsets[0];
    var src_offset_1 = region.src_offsets[1];

    if (dst_offset_0.x > dst_offset_1.x) {
        std.mem.swap(i32, &src_offset_0.x, &src_offset_1.x);
        std.mem.swap(i32, &dst_offset_0.x, &dst_offset_1.x);
    }

    if (dst_offset_0.y > dst_offset_1.y) {
        std.mem.swap(i32, &src_offset_0.y, &src_offset_1.y);
        std.mem.swap(i32, &dst_offset_0.y, &dst_offset_1.y);
    }

    if (dst_offset_0.z > dst_offset_1.z) {
        std.mem.swap(i32, &src_offset_0.z, &src_offset_1.z);
        std.mem.swap(i32, &dst_offset_0.z, &dst_offset_1.z);
    }

    const src_extent = src.getMipLevelExtent(region.src_subresource.mip_level);

    const width_ratio = @as(f32, @floatFromInt(src_offset_1.x - src_offset_0.x)) / @as(f32, @floatFromInt(dst_offset_1.x - dst_offset_0.x));
    const height_ratio = @as(f32, @floatFromInt(src_offset_1.y - src_offset_0.y)) / @as(f32, @floatFromInt(dst_offset_1.y - dst_offset_0.y));
    const depth_ratio = @as(f32, @floatFromInt(src_offset_1.z - src_offset_0.z)) / @as(f32, @floatFromInt(dst_offset_1.z - dst_offset_0.z));
    const x0 = @as(f32, @floatFromInt(src_offset_0.x)) + (0.5 - @as(f32, @floatFromInt(dst_offset_0.x))) * width_ratio;
    const y0 = @as(f32, @floatFromInt(src_offset_0.y)) + (0.5 - @as(f32, @floatFromInt(dst_offset_0.y))) * height_ratio;
    const z0 = @as(f32, @floatFromInt(src_offset_0.z)) + (0.5 - @as(f32, @floatFromInt(dst_offset_0.z))) * depth_ratio;

    const src_slice_pitch_bytes = src.getSliceMemSizeForMipLevel(region.src_subresource.aspect_mask, region.src_subresource.mip_level);
    const dst_slice_pitch_bytes = dst.getSliceMemSizeForMipLevel(region.dst_subresource.aspect_mask, region.dst_subresource.mip_level);
    const src_row_pitch_bytes = src.getRowPitchMemSizeForMipLevel(region.src_subresource.aspect_mask, region.src_subresource.mip_level);
    const dst_row_pitch_bytes = dst.getRowPitchMemSizeForMipLevel(region.dst_subresource.aspect_mask, region.dst_subresource.mip_level);

    const src_format = base.format.fromAspect(src.interface.format, region.src_subresource.aspect_mask);
    const dst_format = base.format.fromAspect(dst.interface.format, region.dst_subresource.aspect_mask);

    const apply_filter = (filter != .nearest);
    const allow_srgb_conversion = apply_filter or base.format.isSrgb(src_format) != base.format.isSrgb(dst_format);

    const is_src_int = base.format.isUint(src_format) or base.format.isSint(src_format);
    const is_dst_int = base.format.isUint(dst_format) or base.format.isSint(dst_format);
    const are_both_int = is_src_int and is_dst_int;

    if (are_both_int) {
        base.unsupported("Blit of only integer type images are not supported yet", .{});
        return;
    }

    var src_subresource = vk.ImageSubresource{
        .aspect_mask = region.src_subresource.aspect_mask,
        .mip_level = region.src_subresource.mip_level,
        .array_layer = region.src_subresource.base_array_layer,
    };

    var dst_subresource = vk.ImageSubresource{
        .aspect_mask = region.dst_subresource.aspect_mask,
        .mip_level = region.dst_subresource.mip_level,
        .array_layer = region.dst_subresource.base_array_layer,
    };

    const last_layer = src.interface.getLastLayerIndex(.{
        .aspect_mask = region.dst_subresource.aspect_mask,
        .base_mip_level = region.dst_subresource.mip_level,
        .level_count = 1,
        .base_array_layer = region.dst_subresource.base_array_layer,
        .layer_count = region.dst_subresource.layer_count,
    });

    const src_memory = if (src.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    const dst_memory = if (dst.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;

    const state: State = .{
        .src_format = src_format,
        .dst_format = dst_format,
        .filter = filter,
        .allow_srgb_conversion = allow_srgb_conversion,
        .clamp_to_edge = false,
    };

    while (dst_subresource.array_layer <= last_layer) : ({
        src_subresource.array_layer += 1;
        dst_subresource.array_layer += 1;
    }) {
        const src_texel_offset = try src.getTexelMemoryOffset(.{ .x = 0, .y = 0, .z = 0 }, src_subresource);
        const src_size = try src.interface.getTotalSizeForAspect(src_subresource.aspect_mask) - src_texel_offset;
        const src_map: []u8 = @as([*]u8, @ptrCast(try src_memory.map(src.interface.memory_offset + src_texel_offset, src_size)))[0..src_size];

        const dst_texel_offset = try dst.getTexelMemoryOffset(.{ .x = 0, .y = 0, .z = 0 }, dst_subresource);
        const dst_size = try dst.interface.getTotalSizeForAspect(dst_subresource.aspect_mask) - dst_texel_offset;
        var dst_map: []u8 = @as([*]u8, @ptrCast(try dst_memory.map(dst.interface.memory_offset + dst_texel_offset, dst_size)))[0..dst_size];

        _ = &src_map;
        _ = &dst_map;

        for (@intCast(dst_offset_0.z)..@intCast(dst_offset_1.z)) |k| {
            const z = z0 + @as(f32, @floatFromInt(k)) * depth_ratio;
            var dst_slice = dst_map[(k * dst_slice_pitch_bytes)..];

            for (@intCast(dst_offset_0.y)..@intCast(dst_offset_1.y)) |j| {
                const y = y0 + @as(f32, @floatFromInt(j)) * height_ratio;
                var dst_line = dst_slice[(j * dst_row_pitch_bytes)..];

                for (@intCast(dst_offset_0.x)..@intCast(dst_offset_1.x)) |i| {
                    const x = x0 + @as(f32, @floatFromInt(i)) * width_ratio;
                    var dst_pixel = dst_line[(i * base.format.texelSize(dst_format))..];

                    if (are_both_int) {
                        // TODO
                    } else {
                        const color = sample(
                            src_map,
                            .{ x, y, z, 0.0 },
                            .{
                                @floatFromInt(src_extent.width),
                                @floatFromInt(src_extent.height),
                                @floatFromInt(src_extent.depth),
                                0.0,
                            },
                            src_slice_pitch_bytes,
                            src_row_pitch_bytes,
                            state,
                        );
                        for (0..dst.interface.samples.toInt()) |_| {
                            writeFloat4(color, dst_pixel, state);
                            if (dst_pixel.len < dst_slice_pitch_bytes)
                                break;
                            dst_pixel = dst_pixel[dst_slice_pitch_bytes..];
                        }
                    }
                }
            }
        }
    }
}

fn applyScaleAndClamp(base_color: zm.F32x4, state: State) zm.F32x4 {
    var color: zm.F32x4 = base_color;

    const unscale = base.format.getScale(state.src_format);
    const scale = base.format.getScale(state.dst_format);

    if (std.simd.firstTrue(unscale != scale) != null) {
        color *= zm.f32x4(scale[0] / unscale[0], scale[1] / unscale[1], scale[2] / unscale[2], scale[3] / unscale[3]);
    }

    return color;
}

fn readFloat4(map: []const u8, state: State) zm.F32x4 {
    var c: zm.F32x4 = .{ 0.0, 0.0, 0.0, 1.0 };

    switch (state.src_format) {
        .r8g8b8a8_sint,
        .r8g8b8a8_snorm,
        .r8g8b8a8_unorm,
        .r8g8b8a8_uint,
        .r8g8b8a8_srgb,
        => {
            c[0] = @as(f32, @floatFromInt(map[0])) / 255.0;
            c[1] = @as(f32, @floatFromInt(map[1])) / 255.0;
            c[2] = @as(f32, @floatFromInt(map[2])) / 255.0;
            c[3] = @as(f32, @floatFromInt(map[3])) / 255.0;
        },

        else => base.unsupported("Blitter source format {any}", .{state.src_format}),
    }

    return c;
}

fn writeFloat4(color: zm.F32x4, map: []u8, state: State) void {
    switch (state.dst_format) {
        .b8g8r8a8_srgb,
        .b8g8r8a8_unorm,
        => {
            map[0] = @intFromFloat(color[1] * 255.0);
            map[1] = @intFromFloat(color[2] * 255.0);
            map[2] = @intFromFloat(color[0] * 255.0);
            map[3] = @intFromFloat(color[3] * 255.0);
        },
        else => base.unsupported("Blitter destination format {any}", .{state.src_format}),
    }
}
