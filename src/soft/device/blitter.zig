//! This software blitter is highly inspired by SwiftShaders one

const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;

const VkError = base.VkError;

pub const SoftImage = @import("../SoftImage.zig");
pub const SoftImageView = @import("../SoftImageView.zig");

const F32x4 = zm.F32x4;
const U32x4 = @Vector(4, u32);

const State = struct {
    src_format: vk.Format,
    dst_format: vk.Format,
    filter: vk.Filter,
    allow_srgb_conversion: bool,
    clamp_to_edge: bool,
    src_samples: usize,
    dst_samples: usize,
    filter_3D: bool,
    clear: bool,
};

const BlitData = struct {
    src_map: []const u8,
    dst_map: []u8,

    src_slice_pitch_bytes: usize,
    src_row_pitch_bytes: usize,
    dst_slice_pitch_bytes: usize,
    dst_row_pitch_bytes: usize,

    pos: F32x4,
    dim: F32x4,

    dst_offset_0: vk.Offset3D,
    dst_offset_1: vk.Offset3D,

    depth_ratio: f32,
    height_ratio: f32,
    width_ratio: f32,
};

fn computeOffset2D(x: usize, y: usize, pitch_bytes: usize, texel_bytes: usize) usize {
    return y * pitch_bytes + x * texel_bytes;
}

fn computeOffset3D(x: usize, y: usize, z: usize, slice_bytes: usize, pitch_bytes: usize, texel_bytes: usize) usize {
    return z * slice_bytes + y * pitch_bytes + x * texel_bytes;
}

pub fn clear(pixel: vk.ClearValue, format: vk.Format, dst: *SoftImage, view_format: vk.Format, range: vk.ImageSubresourceRange, render_area: ?vk.Rect2D) VkError!void {
    const dst_format = base.format.fromAspect(view_format, range.aspect_mask);
    if (dst_format == .undefined) {
        return;
    }

    var clamped_pixel: vk.ClearValue = pixel;
    if (base.format.isSint(view_format) or base.format.isUint(view_format)) {
        const min_value: f32 = if (base.format.isSnorm(view_format)) -1.0 else 0.0;

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

    if (try fastClear(clamped_pixel, format, dst, dst_format, range, render_area)) {
        return;
    }

    const state: State = .{
        .src_format = format,
        .dst_format = dst_format,
        .filter = .nearest,
        .allow_srgb_conversion = true,
        .clamp_to_edge = false,
        .src_samples = 1,
        .dst_samples = dst.interface.samples.toInt(),
        .filter_3D = false,
        .clear = true,
    };

    var subresource = vk.ImageSubresource{
        .aspect_mask = range.aspect_mask,
        .mip_level = range.base_mip_level,
        .array_layer = range.base_array_layer,
    };

    const dst_slice_pitch_bytes = dst.getSliceMemSizeForMipLevel(subresource.aspect_mask, subresource.mip_level);
    const dst_row_pitch_bytes = dst.getRowPitchMemSizeForMipLevel(subresource.aspect_mask, subresource.mip_level);

    const last_mip_level = dst.interface.getLastMipLevel(range);
    const last_layer = dst.interface.getLastLayerIndex(range);

    var area: vk.Rect2D = if (render_area) |ra| ra else .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = 0, .height = 0 },
    };

    const dst_memory = if (dst.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;

    while (subresource.mip_level <= last_mip_level) : (subresource.mip_level += 1) {
        const extent = dst.getMipLevelExtent(subresource.mip_level);

        if (render_area == null) {
            area.extent.width = extent.width;
            area.extent.height = extent.height;
        }

        subresource.array_layer = range.base_array_layer;
        while (subresource.array_layer <= last_layer) : (subresource.array_layer += 1) {
            for (0..@intCast(extent.depth)) |depth| {
                const dst_texel_offset = try dst.getTexelMemoryOffset(.{ .x = 0, .y = 0, .z = @intCast(depth) }, subresource);
                const dst_size = try dst.interface.getTotalSizeForAspect(subresource.aspect_mask) - dst_texel_offset;
                const dst_map: []u8 = @as([*]u8, @ptrCast(try dst_memory.map(dst.interface.memory_offset + dst_texel_offset, dst_size)))[0..dst_size];

                blit(state, .{
                    .src_map = std.mem.asBytes(&pixel),
                    .dst_map = dst_map,

                    .src_slice_pitch_bytes = base.format.texelSize(format),
                    .src_row_pitch_bytes = 0,
                    .dst_slice_pitch_bytes = dst_slice_pitch_bytes,
                    .dst_row_pitch_bytes = dst_row_pitch_bytes,

                    .pos = zm.f32x4s(0.5),
                    .dim = zm.f32x4s(0.0),

                    .dst_offset_0 = .{ .x = area.offset.x, .y = area.offset.y, .z = 0 },
                    .dst_offset_1 = .{ .x = area.offset.x + @as(i32, @intCast(area.extent.width)), .y = area.offset.y + @as(i32, @intCast(area.extent.height)), .z = 1 },

                    .depth_ratio = 0,
                    .height_ratio = 0,
                    .width_ratio = 0,
                });
            }
        }
    }
}

fn fastClear(clear_value: vk.ClearValue, clear_format: vk.Format, dst: *SoftImage, view_format: vk.Format, range: vk.ImageSubresourceRange, render_area: ?vk.Rect2D) VkError!bool {
    if (clear_format != .r32g32b32a32_sfloat and clear_format != .d32_sfloat and clear_format != .s8_uint) {
        return false;
    }

    const r, const g, const b, const a = clear_value.color.float_32;
    const d = clear_value.depth_stencil.depth;
    const s = clear_value.depth_stencil.stencil;

    var pack: u32 = 0;
    switch (view_format) {
        .r5g6b5_unorm_pack16 => pack = @as(u16, @intFromFloat(31.0 * b + 0.5)) |
            (@as(u16, @intFromFloat(63.0 * g + 0.5)) << 5) |
            (@as(u16, @intFromFloat(31.0 * r + 0.5)) << 11),
        .b5g6r5_unorm_pack16 => pack = @as(u16, @intFromFloat(31.0 * r + 0.5)) |
            (@as(u16, @intFromFloat(63.0 * g + 0.5)) << 5) |
            (@as(u16, @intFromFloat(31.0 * b + 0.5)) << 11),

        .a8b8g8r8_uint_pack32,
        .a8b8g8r8_unorm_pack32,
        .r8g8b8a8_unorm,
        => pack = (@as(u32, @intFromFloat(255.0 * a + 0.5)) << 24) |
            (@as(u32, @intFromFloat(255.0 * b + 0.5)) << 16) |
            (@as(u32, @intFromFloat(255.0 * g + 0.5)) << 8) |
            (@as(u32, @intFromFloat(255.0 * r + 0.5))),

        .b8g8r8a8_unorm => pack = (@as(u32, @intFromFloat(255.0 * a + 0.5)) << 24) |
            (@as(u32, @intFromFloat(255.0 * r + 0.5)) << 16) |
            (@as(u32, @intFromFloat(255.0 * g + 0.5)) << 8) |
            (@as(u32, @intFromFloat(255.0 * b + 0.5))),
        .d32_sfloat => {
            std.debug.assert(clear_format == .d32_sfloat);
            pack = @bitCast(d); // float reinterpreted as uint32
        },
        .s8_uint => {
            std.debug.assert(clear_format == .s8_uint);
            pack = @as(u8, @intCast(s));
        },
        else => return false,
    }

    var subresource: vk.ImageSubresource = .{
        .aspect_mask = range.aspect_mask,
        .mip_level = range.base_mip_level,
        .array_layer = range.base_array_layer,
    };
    const last_mip_level = dst.interface.getLastMipLevel(range);
    const last_layer = dst.interface.getLastLayerIndex(range);

    var area: vk.Rect2D = if (render_area) |ra| ra else .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = 0, .height = 0 },
    };

    const dst_memory = if (dst.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;

    while (subresource.mip_level <= last_mip_level) : (subresource.mip_level += 1) {
        const dst_slice_pitch_bytes = dst.getSliceMemSizeForMipLevel(subresource.aspect_mask, subresource.mip_level);
        const dst_row_pitch_bytes = dst.getRowPitchMemSizeForMipLevel(subresource.aspect_mask, subresource.mip_level);
        const extent = dst.getMipLevelExtent(subresource.mip_level);

        if (render_area == null) {
            area.extent.width = extent.width;
            area.extent.height = extent.height;
        }

        subresource.array_layer = range.base_array_layer;
        while (subresource.array_layer <= last_layer) : (subresource.array_layer += 1) {
            for (0..@intCast(extent.depth)) |depth| {
                const dst_texel_offset = try dst.getTexelMemoryOffset(.{ .x = area.offset.x, .y = area.offset.y, .z = @intCast(depth) }, subresource);
                const dst_size = try dst.interface.getTotalSizeForAspect(subresource.aspect_mask) - dst_texel_offset;
                var dst_map: []u8 = @as([*]u8, @ptrCast(try dst_memory.map(dst.interface.memory_offset + dst_texel_offset, dst_size)))[0..dst_size];

                for (0..dst.interface.samples.toInt()) |_| {
                    var dst_pixel = dst_map[0..];
                    switch (base.format.texelSize(view_format)) {
                        4 => for (0..@intCast(area.extent.height)) |_| {
                            var dst_pixel_4bytes = std.mem.bytesAsSlice(u32, dst_pixel);
                            @memset(dst_pixel_4bytes[0..area.extent.width], pack);
                            dst_pixel = if (dst_pixel.len < dst_row_pitch_bytes) break else dst_pixel[dst_row_pitch_bytes..];
                        },
                        2 => for (0..@intCast(area.extent.height)) |_| {
                            var dst_pixel_2bytes = std.mem.bytesAsSlice(u16, dst_pixel);
                            @memset(dst_pixel_2bytes[0..area.extent.width], @as(u16, @truncate(pack)));
                            dst_pixel = if (dst_pixel.len < dst_row_pitch_bytes) break else dst_pixel[dst_row_pitch_bytes..];
                        },
                        1 => for (0..@intCast(area.extent.height)) |_| {
                            @memset(dst_pixel[0..area.extent.width], @as(u8, @truncate(pack)));
                            dst_pixel = if (dst_pixel.len < dst_row_pitch_bytes) break else dst_pixel[dst_row_pitch_bytes..];
                        },
                        else => unreachable,
                    }

                    dst_map = if (dst_map.len < dst_slice_pitch_bytes) break else dst_map[dst_slice_pitch_bytes..];
                }
            }
        }
    }

    return true;
}

fn sample(src: []const u8, pos: F32x4, dim: F32x4, slice_bytes: usize, pitch_bytes: usize, state: State) F32x4 {
    var color: F32x4 = .{ 0.0, 0.0, 0.0, 1.0 };
    const src_texel_size = base.format.texelSize(state.src_format);

    if (state.filter == .nearest or base.format.isUint(state.src_format)) {
        var x: usize = @intFromFloat(pos[0]);
        var y: usize = @intFromFloat(pos[1]);
        var z: usize = @intFromFloat(pos[2]);

        if (state.clamp_to_edge) {
            x = std.math.clamp(x, 0, @as(usize, @intFromFloat(dim[0])) - 1);
            y = std.math.clamp(y, 0, @as(usize, @intFromFloat(dim[1])) - 1);
            z = std.math.clamp(z, 0, @as(usize, @intFromFloat(dim[2])) - 1);
        }

        const src_map = src[computeOffset3D(x, y, z, slice_bytes, pitch_bytes, src_texel_size)..];

        color = readFloat4(src_map, state.src_format);
    } else {
        var x: f32 = pos[0];
        var y: f32 = pos[1];
        var z: f32 = pos[2];

        if (state.clamp_to_edge) {
            x = @min(@max(x, 0.5), dim[0] - 0.5);
            y = @min(@max(y, 0.5), dim[1] - 0.5);
            z = @min(@max(z, 0.5), dim[2] - 0.5);
        }

        const fx0 = x - 0.5;
        const fy0 = y - 0.5;
        const fz0 = z - 0.5;

        const ix0: usize = @intCast(@max(@as(i32, @intFromFloat(fx0)), 0));
        const iy0: usize = @intCast(@max(@as(i32, @intFromFloat(fy0)), 0));
        const iz0: usize = @intCast(@max(@as(i32, @intFromFloat(fz0)), 0));

        const ix1 = if (ix0 + 1 >= @as(usize, @intFromFloat(dim[0]))) ix0 else ix0 + 1;
        const iy1 = if (iy0 + 1 >= @as(usize, @intFromFloat(dim[1]))) iy0 else iy0 + 1;

        if (state.filter_3D) {
            const iz1 = if (iz0 + 1 >= @as(usize, @intFromFloat(dim[2]))) iz0 else iz0 + 1;

            const sample_0_0_0 = src[computeOffset3D(ix0, iy0, iz0, slice_bytes, pitch_bytes, src_texel_size)..];
            const sample_0_1_0 = src[computeOffset3D(ix1, iy0, iz0, slice_bytes, pitch_bytes, src_texel_size)..];
            const sample_1_0_0 = src[computeOffset3D(ix0, iy1, iz0, slice_bytes, pitch_bytes, src_texel_size)..];
            const sample_1_1_0 = src[computeOffset3D(ix1, iy1, iz0, slice_bytes, pitch_bytes, src_texel_size)..];
            const sample_0_0_1 = src[computeOffset3D(ix0, iy0, iz1, slice_bytes, pitch_bytes, src_texel_size)..];
            const sample_0_1_1 = src[computeOffset3D(ix1, iy0, iz1, slice_bytes, pitch_bytes, src_texel_size)..];
            const sample_1_0_1 = src[computeOffset3D(ix0, iy1, iz1, slice_bytes, pitch_bytes, src_texel_size)..];
            const sample_1_1_1 = src[computeOffset3D(ix1, iy1, iz1, slice_bytes, pitch_bytes, src_texel_size)..];

            const pixel_0_0_0 = readFloat4(sample_0_0_0, state.src_format);
            const pixel_0_1_0 = readFloat4(sample_0_1_0, state.src_format);
            const pixel_1_0_0 = readFloat4(sample_1_0_0, state.src_format);
            const pixel_1_1_0 = readFloat4(sample_1_1_0, state.src_format);
            const pixel_0_0_1 = readFloat4(sample_0_0_1, state.src_format);
            const pixel_0_1_1 = readFloat4(sample_0_1_1, state.src_format);
            const pixel_1_0_1 = readFloat4(sample_1_0_1, state.src_format);
            const pixel_1_1_1 = readFloat4(sample_1_1_1, state.src_format);

            const fx = zm.f32x4s(fx0 - @as(f32, @floatFromInt(ix0)));
            const fy = zm.f32x4s(fy0 - @as(f32, @floatFromInt(iy0)));
            const fz = zm.f32x4s(fz0 - @as(f32, @floatFromInt(iz0)));
            const ix = zm.f32x4s(1.0) - fx;
            const iy = zm.f32x4s(1.0) - fy;
            const iz = zm.f32x4s(1.0) - fz;

            color = ((pixel_0_0_0 * ix + pixel_0_1_0 * fx) * iy + (pixel_1_0_0 * ix + pixel_1_1_0 * fx) * fy) * iz +
                ((pixel_0_0_1 * ix + pixel_0_1_1 * fx) * iy + (pixel_1_0_1 * ix + pixel_1_1_1 * fx) * fy) * fz;
        } else {
            const sample_0_0 = src[computeOffset3D(ix0, iy0, iz0, slice_bytes, pitch_bytes, src_texel_size)..];
            const sample_0_1 = src[computeOffset3D(ix1, iy0, iz0, slice_bytes, pitch_bytes, src_texel_size)..];
            const sample_1_0 = src[computeOffset3D(ix0, iy1, iz0, slice_bytes, pitch_bytes, src_texel_size)..];
            const sample_1_1 = src[computeOffset3D(ix1, iy1, iz0, slice_bytes, pitch_bytes, src_texel_size)..];

            const pixel_0_0 = readFloat4(sample_0_0, state.src_format);
            const pixel_0_1 = readFloat4(sample_0_1, state.src_format);
            const pixel_1_0 = readFloat4(sample_1_0, state.src_format);
            const pixel_1_1 = readFloat4(sample_1_1, state.src_format);

            const fx = zm.f32x4s(fx0 - @as(f32, @floatFromInt(ix0)));
            const fy = zm.f32x4s(fy0 - @as(f32, @floatFromInt(iy0)));
            const ix = zm.f32x4s(1.0) - fx;
            const iy = zm.f32x4s(1.0) - fy;

            color = (pixel_0_0 * ix + pixel_0_1 * fx) * iy + (pixel_1_0 * ix + pixel_1_1 * fx) * fy;
        }
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
    const src_row_pitch_bytes = src.getRowPitchMemSizeForMipLevel(region.src_subresource.aspect_mask, region.src_subresource.mip_level);
    const dst_slice_pitch_bytes = dst.getSliceMemSizeForMipLevel(region.dst_subresource.aspect_mask, region.dst_subresource.mip_level);
    const dst_row_pitch_bytes = dst.getRowPitchMemSizeForMipLevel(region.dst_subresource.aspect_mask, region.dst_subresource.mip_level);

    const src_format = base.format.fromAspect(src.interface.format, region.src_subresource.aspect_mask);
    const dst_format = base.format.fromAspect(dst.interface.format, region.dst_subresource.aspect_mask);

    const apply_filter = (filter != .nearest);
    const allow_srgb_conversion = apply_filter or base.format.isSrgb(src_format) != base.format.isSrgb(dst_format);

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
        .clamp_to_edge = src_offset_0.x < 0 or
            src_offset_0.y < 0 or
            @as(u32, @intCast(src_offset_1.x)) > src_extent.width or
            @as(u32, @intCast(src_offset_1.y)) > src_extent.height or
            (filter != .nearest and ((x0 < 0.5) or (y0 < 0.5))),
        .src_samples = src.interface.samples.toInt(),
        .dst_samples = dst.interface.samples.toInt(),
        .filter_3D = (src_offset_1.z - src_offset_0.z) != (dst_offset_1.z - dst_offset_0.z),
        .clear = false,
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
        const dst_map: []u8 = @as([*]u8, @ptrCast(try dst_memory.map(dst.interface.memory_offset + dst_texel_offset, dst_size)))[0..dst_size];

        blit(state, .{
            .src_map = src_map,
            .dst_map = dst_map,

            .src_slice_pitch_bytes = src_slice_pitch_bytes,
            .src_row_pitch_bytes = src_row_pitch_bytes,
            .dst_slice_pitch_bytes = dst_slice_pitch_bytes,
            .dst_row_pitch_bytes = dst_row_pitch_bytes,

            .pos = zm.f32x4(x0, y0, z0, 0.0),
            .dim = zm.f32x4(@floatFromInt(src_extent.width), @floatFromInt(src_extent.height), @floatFromInt(src_extent.depth), 0.0),

            .dst_offset_0 = dst_offset_0,
            .dst_offset_1 = dst_offset_1,

            .depth_ratio = depth_ratio,
            .height_ratio = height_ratio,
            .width_ratio = width_ratio,
        });
    }
}

fn blit(state: State, data: BlitData) void {
    const is_src_int = base.format.isUint(state.src_format) or base.format.isSint(state.src_format);
    const is_dst_int = base.format.isUint(state.dst_format) or base.format.isSint(state.dst_format);
    const are_both_int = is_src_int and is_dst_int;

    var clear_color_i: ?U32x4 = null;
    var clear_color_f: ?F32x4 = null;
    if (state.clear) {
        if (are_both_int) {
            clear_color_i = readInt4(data.src_map, state.src_format);
        } else {
            clear_color_f = applyScaleAndClamp(readFloat4(data.src_map, state.src_format), state);
        }
    }

    for (@intCast(data.dst_offset_0.z)..@intCast(data.dst_offset_1.z)) |k| {
        const z = if (state.clear) data.pos[2] else data.pos[2] + @as(f32, @floatFromInt(k)) * data.depth_ratio;
        var dst_slice = data.dst_map[(k * data.dst_slice_pitch_bytes)..];

        for (@intCast(data.dst_offset_0.y)..@intCast(data.dst_offset_1.y)) |j| {
            const y = if (state.clear) data.pos[1] else data.pos[1] + @as(f32, @floatFromInt(j)) * data.height_ratio;
            var dst_line = dst_slice[(j * data.dst_row_pitch_bytes)..];

            for (@intCast(data.dst_offset_0.x)..@intCast(data.dst_offset_1.x)) |i| {
                const x = if (state.clear) data.pos[0] else data.pos[0] + @as(f32, @floatFromInt(i)) * data.width_ratio;
                var dst_pixel = dst_line[(i * base.format.texelSize(state.dst_format))..];

                if (clear_color_i) |color| {
                    for (0..state.dst_samples) |_| {
                        writeInt4(color, dst_pixel, state.dst_format);
                        dst_pixel = if (dst_pixel.len < data.dst_slice_pitch_bytes) break else dst_pixel[data.dst_slice_pitch_bytes..];
                    }
                } else if (clear_color_f) |color| {
                    for (0..state.dst_samples) |_| {
                        writeFloat4(color, dst_pixel, state.dst_format);
                        dst_pixel = if (dst_pixel.len < data.dst_slice_pitch_bytes) break else dst_pixel[data.dst_slice_pitch_bytes..];
                    }
                } else if (are_both_int) {
                    var ix: usize = @intFromFloat(x);
                    var iy: usize = @intFromFloat(y);
                    var iz: usize = @intFromFloat(z);

                    if (state.clamp_to_edge) {
                        ix = std.math.clamp(ix, 0, @as(usize, @intFromFloat(data.dim[0])) - 1);
                        iy = std.math.clamp(iy, 0, @as(usize, @intFromFloat(data.dim[1])) - 1);
                        iz = std.math.clamp(iz, 0, @as(usize, @intFromFloat(data.dim[2])) - 1);
                    }

                    const src_map = data.src_map[computeOffset3D(ix, iy, iz, data.src_slice_pitch_bytes, data.src_row_pitch_bytes, base.format.texelSize(state.src_format))..];

                    const color = readInt4(src_map, state.src_format);
                    for (0..state.dst_samples) |_| {
                        writeInt4(color, dst_pixel, state.dst_format);
                        dst_pixel = if (dst_pixel.len < data.dst_slice_pitch_bytes) break else dst_pixel[data.dst_slice_pitch_bytes..];
                    }
                } else {
                    const color = sample(data.src_map, .{ x, y, z, 0.0 }, data.dim, data.src_slice_pitch_bytes, data.src_row_pitch_bytes, state);
                    for (0..state.dst_samples) |_| {
                        writeFloat4(color, dst_pixel, state.dst_format);
                        dst_pixel = if (dst_pixel.len < data.dst_slice_pitch_bytes) break else dst_pixel[data.dst_slice_pitch_bytes..];
                    }
                }
            }
        }
    }
}

fn applyScaleAndClamp(base_color: F32x4, state: State) F32x4 {
    var color: F32x4 = base_color;

    const scale = base.format.getScale(state.dst_format);

    if (base.format.isFloat(state.src_format) and !base.format.isFloat(state.dst_format)) {
        color = @min(color, scale);
        color = @max(color, zm.f32x4(
            if (base.format.isUnsignedComponent(state.dst_format, 0)) 0.0 else -scale[0],
            if (base.format.isUnsignedComponent(state.dst_format, 1)) 0.0 else -scale[1],
            if (base.format.isUnsignedComponent(state.dst_format, 2)) 0.0 else -scale[2],
            if (base.format.isUnsignedComponent(state.dst_format, 3)) 0.0 else -scale[3],
        ));
    }

    if (!base.format.isUnsigned(state.src_format) and base.format.isUnsigned(state.dst_format)) {
        color = @max(color, zm.f32x4s(0.0));
    }

    return color;
}

pub fn readFloat4(map: []const u8, src_format: vk.Format) F32x4 {
    var c: F32x4 = .{ 0.0, 0.0, 0.0, 1.0 };

    switch (src_format) {
        .r8_snorm,
        .r8_unorm,
        => c[0] = @as(f32, @floatFromInt(map[0])) / 255.0,

        .r16_snorm,
        .r16_unorm,
        => c[0] = @as(f32, @floatFromInt(std.mem.bytesToValue(u16, map))) / 255.0,

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

        .r16_sint,
        .r16_uint,
        => c[0] = @floatFromInt(std.mem.bytesToValue(u16, map)),

        .r32_sint,
        .r32_uint,
        => c[0] = @floatFromInt(std.mem.bytesToValue(u32, map)),

        .r32_sfloat => c[0] = std.mem.bytesToValue(f32, map),

        .r32g32b32a32_sfloat => c = std.mem.bytesToValue(F32x4, map),

        else => base.unsupported("Blitter: read float from source format {any}", .{src_format}),
    }

    return c;
}

pub fn writeFloat4(color: F32x4, map: []u8, dst_format: vk.Format) void {
    switch (dst_format) {
        .r8_snorm,
        .r8_unorm,
        => map[0] = @intFromFloat(@round(color[0] * 255.0)),

        .r16_sint,
        .r16_uint,
        => std.mem.bytesAsValue(u16, map).* = @intFromFloat(@round(color[0])),

        .r16_sfloat => std.mem.bytesAsValue(f16, map).* = @floatCast(color[0]),

        .r32_sint,
        .r32_uint,
        => std.mem.bytesAsValue(u32, map).* = @intFromFloat(@round(color[0])),

        .r32_sfloat => std.mem.bytesAsValue(f32, map).* = color[0],

        .b8g8r8a8_srgb,
        .b8g8r8a8_unorm,
        => {
            map[0] = @intFromFloat(@round(color[2] * 255.0));
            map[1] = @intFromFloat(@round(color[1] * 255.0));
            map[2] = @intFromFloat(@round(color[0] * 255.0));
            map[3] = @intFromFloat(@round(color[3] * 255.0));
        },

        .a8b8g8r8_unorm_pack32,
        .r8g8b8a8_unorm,
        .a8b8g8r8_srgb_pack32,
        .r8g8b8a8_srgb,
        .a8b8g8r8_uint_pack32,
        .r8g8b8a8_uint,
        .r8g8b8a8_uscaled,
        .a8b8g8r8_uscaled_pack32,
        => {
            map[0] = @intFromFloat(@round(color[0] * 255.0));
            map[1] = @intFromFloat(@round(color[1] * 255.0));
            map[2] = @intFromFloat(@round(color[2] * 255.0));
            map[3] = @intFromFloat(@round(color[3] * 255.0));
        },

        .r32g32b32a32_sfloat => std.mem.bytesAsValue(F32x4, map).* = color,

        else => base.unsupported("Blitter: write float to destination format {any}", .{dst_format}),
    }
}

pub fn readInt4(map: []const u8, src_format: vk.Format) U32x4 {
    var c: U32x4 = .{ 0.0, 0.0, 0.0, 1.0 };

    switch (src_format) {
        .r8_sint,
        .r8_uint,
        => c[0] = map[0],
        .r16_sint,
        .r16_uint,
        => c[0] = std.mem.bytesToValue(u16, map),
        .r32_sint,
        .r32_uint,
        => c[0] = std.mem.bytesToValue(u32, map),

        .r8g8b8a8_sint,
        .r8g8b8a8_uint,
        => {
            c[0] = map[0];
            c[1] = map[1];
            c[2] = map[2];
            c[3] = map[3];
        },

        .r16g16b16a16_sint,
        .r16g16b16a16_uint,
        => {
            c[0] = std.mem.bytesToValue(u16, map[0..2]);
            c[1] = std.mem.bytesToValue(u16, map[2..4]);
            c[2] = std.mem.bytesToValue(u16, map[4..6]);
            c[3] = std.mem.bytesToValue(u16, map[6..8]);
        },

        .r32g32b32a32_sint,
        .r32g32b32a32_uint,
        => c = std.mem.bytesToValue(U32x4, map),

        else => base.unsupported("Blitter: read int from source format {any}", .{src_format}),
    }

    return c;
}

pub fn writeInt4(color: U32x4, map: []u8, dst_format: vk.Format) void {
    switch (dst_format) {
        .r8_sint,
        .r8_uint,
        => map[0] = @truncate(color[0]),

        .r16_sint,
        .r16_uint,
        => std.mem.bytesAsValue(u16, map).* = @truncate(color[0]),

        .r32_sint,
        .r32_uint,
        => std.mem.bytesAsValue(u32, map).* = color[0],

        .r8g8b8a8_sint,
        .r8g8b8a8_uint,
        => {
            map[0] = @truncate(color[0]);
            map[1] = @truncate(color[1]);
            map[2] = @truncate(color[2]);
            map[3] = @truncate(color[3]);
        },

        .r16g16b16a16_sint,
        .r16g16b16a16_uint,
        => {
            std.mem.bytesAsValue(u16, map[0..2]).* = @truncate(color[0]);
            std.mem.bytesAsValue(u16, map[2..4]).* = @truncate(color[1]);
            std.mem.bytesAsValue(u16, map[4..6]).* = @truncate(color[2]);
            std.mem.bytesAsValue(u16, map[6..8]).* = @truncate(color[3]);
        },

        .r32g32b32a32_sint,
        .r32g32b32a32_uint,
        => std.mem.bytesAsValue(U32x4, map).* = color,

        else => base.unsupported("Blitter: write int to destination format {any}", .{dst_format}),
    }
}
