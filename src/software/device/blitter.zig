const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;

const VkError = base.VkError;

pub const SoftImage = @import("../SoftImage.zig");
pub const SoftImageView = @import("../SoftImageView.zig");

pub const F32x4 = zm.F32x4;
pub const F32x3 = @Vector(3, f32);
pub const U32x4 = @Vector(4, u32);
pub const I32x4 = @Vector(4, i32);

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

fn computeOffset3D(x: usize, y: usize, z: usize, slice_bytes: usize, pitch_bytes: usize, texel_bytes: usize) usize {
    return z * slice_bytes + y * pitch_bytes + x * texel_bytes;
}

pub fn clear(pixel: vk.ClearValue, format: vk.Format, dst: *SoftImage, view_format: vk.Format, range: vk.ImageSubresourceRange, render_area: ?vk.Rect2D) VkError!void {
    if (range.aspect_mask.depth_bit and range.aspect_mask.stencil_bit) {
        var depth_range = range;
        depth_range.aspect_mask = .{ .depth_bit = true };
        try clear(pixel, format, dst, view_format, depth_range, render_area);

        var stencil_range = range;
        stencil_range.aspect_mask = .{ .stencil_bit = true };
        try clear(pixel, format, dst, view_format, stencil_range, render_area);

        return;
    }

    const dst_format = base.format.fromAspect(view_format, range.aspect_mask);
    if (dst_format == .undefined) {
        return;
    }

    const io = dst.interface.owner.io();
    const timer = std.Io.Timestamp.now(io, .real);
    defer if (comptime base.config.logs != .none) {
        const duration = timer.untilNow(io, .real);
        const ms: f32 = @floatFromInt(duration.toMicroseconds());
        std.log.scoped(.SoftwareBlitter).debug("Image clear took {}ms", .{ms / 1000});
    };

    var clamped_pixel: vk.ClearValue = pixel;
    if (range.aspect_mask.color_bit and (base.format.isSnorm(view_format) or base.format.isUnorm(view_format))) {
        const min_value: f32 = if (base.format.isSnorm(view_format)) -1.0 else 0.0;

        clamped_pixel.color.float_32[0] = std.math.clamp(pixel.color.float_32[0], min_value, 1.0);
        clamped_pixel.color.float_32[1] = std.math.clamp(pixel.color.float_32[1], min_value, 1.0);
        clamped_pixel.color.float_32[2] = std.math.clamp(pixel.color.float_32[2], min_value, 1.0);
        clamped_pixel.color.float_32[3] = std.math.clamp(pixel.color.float_32[3], min_value, 1.0);
    }

    if (range.aspect_mask.depth_bit) {
        clamped_pixel.depth_stencil.depth = std.math.clamp(pixel.depth_stencil.depth, 0.0, 1.0);
    }

    const depth_clear: F32x4 = @splat(clamped_pixel.depth_stencil.depth);
    const stencil_clear: U32x4 = @splat(clamped_pixel.depth_stencil.stencil);

    const src_format: vk.Format = if (range.aspect_mask.stencil_bit)
        .r32g32b32a32_uint
    else if (range.aspect_mask.depth_bit)
        .r32g32b32a32_sfloat
    else
        format;

    const src_map: []const u8 = if (range.aspect_mask.stencil_bit)
        std.mem.asBytes(&stencil_clear)
    else if (range.aspect_mask.depth_bit)
        std.mem.asBytes(&depth_clear)
    else
        std.mem.asBytes(&clamped_pixel);

    const state: State = .{
        .src_format = src_format,
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

    const last_mip_level = dst.interface.getLastMipLevel(range);
    const last_layer = dst.interface.getLastLayerIndex(range);

    var area: vk.Rect2D = if (render_area) |ra| ra else .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = 0, .height = 0 },
    };

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
                const dst_map = try dst.mapAsSliceWithAddedOffset(u8, dst_texel_offset, vk.WHOLE_SIZE);

                blit(state, .{
                    .src_map = src_map,
                    .dst_map = dst_map,

                    .src_slice_pitch_bytes = base.format.texelSize(src_format),
                    .src_row_pitch_bytes = 0,
                    .dst_slice_pitch_bytes = dst.interface.getSliceMemSizeForMipLevel(subresource.aspect_mask, subresource.mip_level),
                    .dst_row_pitch_bytes = dst.interface.getRowPitchMemSizeForMipLevel(subresource.aspect_mask, subresource.mip_level),

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

fn sample(src: []const u8, pos: F32x4, dim: F32x4, slice_bytes: usize, pitch_bytes: usize, state: State) F32x4 {
    var color: F32x4 = .{ 0.0, 0.0, 0.0, 1.0 };
    const src_texel_size = base.format.texelSize(state.src_format);
    var apply_srgb_convertion = true;

    if (state.filter == .nearest or base.format.isUnnormalizedInteger(state.src_format)) {
        var x: usize = @intFromFloat(pos[0]);
        var y: usize = @intFromFloat(pos[1]);
        var z: usize = @intFromFloat(pos[2]);

        if (state.clamp_to_edge) {
            x = std.math.clamp(x, 0, @as(usize, @intFromFloat(dim[0])) - 1);
            y = std.math.clamp(y, 0, @as(usize, @intFromFloat(dim[1])) - 1);
            z = std.math.clamp(z, 0, @as(usize, @intFromFloat(dim[2])) - 1);
        }

        const offset = computeOffset3D(x, y, z, slice_bytes, pitch_bytes, src_texel_size);
        const src_map = src[offset..];

        if (state.src_samples > 1 and state.dst_samples == 1 and !base.format.isUnnormalizedInteger(state.src_format)) {
            const sample_stride = slice_bytes * @as(usize, @intFromFloat(dim[2]));
            color = zm.f32x4s(0.0);
            for (0..state.src_samples) |sample_index| {
                var sample_color = readFloat4(src_map[sample_index * sample_stride ..], state.src_format);
                if (state.allow_srgb_conversion and base.format.isSrgb(state.src_format)) {
                    sample_color = applyScaleAndClamp(sample_color, state, true);
                    apply_srgb_convertion = false;
                }
                color += sample_color;
            }
            color /= zm.f32x4s(@floatFromInt(state.src_samples));
        } else {
            color = readFloat4(src_map, state.src_format);
        }
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

            var pixel_0_0_0 = readFloat4(sample_0_0_0, state.src_format);
            var pixel_0_1_0 = readFloat4(sample_0_1_0, state.src_format);
            var pixel_1_0_0 = readFloat4(sample_1_0_0, state.src_format);
            var pixel_1_1_0 = readFloat4(sample_1_1_0, state.src_format);
            var pixel_0_0_1 = readFloat4(sample_0_0_1, state.src_format);
            var pixel_0_1_1 = readFloat4(sample_0_1_1, state.src_format);
            var pixel_1_0_1 = readFloat4(sample_1_0_1, state.src_format);
            var pixel_1_1_1 = readFloat4(sample_1_1_1, state.src_format);

            if (state.allow_srgb_conversion and base.format.isSrgb(state.src_format)) {
                pixel_0_0_0 = applyScaleAndClamp(pixel_0_0_0, state, true);
                pixel_0_1_0 = applyScaleAndClamp(pixel_0_1_0, state, true);
                pixel_1_0_0 = applyScaleAndClamp(pixel_1_0_0, state, true);
                pixel_1_1_0 = applyScaleAndClamp(pixel_1_1_0, state, true);
                pixel_0_0_1 = applyScaleAndClamp(pixel_0_0_1, state, true);
                pixel_0_1_1 = applyScaleAndClamp(pixel_0_1_1, state, true);
                pixel_1_0_1 = applyScaleAndClamp(pixel_1_0_1, state, true);
                pixel_1_1_1 = applyScaleAndClamp(pixel_1_1_1, state, true);
                apply_srgb_convertion = false;
            }

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

            var pixel_0_0 = readFloat4(sample_0_0, state.src_format);
            var pixel_0_1 = readFloat4(sample_0_1, state.src_format);
            var pixel_1_0 = readFloat4(sample_1_0, state.src_format);
            var pixel_1_1 = readFloat4(sample_1_1, state.src_format);

            if (state.allow_srgb_conversion and base.format.isSrgb(state.src_format)) {
                pixel_0_0 = applyScaleAndClamp(pixel_0_0, state, true);
                pixel_0_1 = applyScaleAndClamp(pixel_0_1, state, true);
                pixel_1_0 = applyScaleAndClamp(pixel_1_0, state, true);
                pixel_1_1 = applyScaleAndClamp(pixel_1_1, state, true);
                apply_srgb_convertion = false;
            }

            const fx = zm.f32x4s(fx0 - @as(f32, @floatFromInt(ix0)));
            const fy = zm.f32x4s(fy0 - @as(f32, @floatFromInt(iy0)));
            const ix = zm.f32x4s(1.0) - fx;
            const iy = zm.f32x4s(1.0) - fy;

            color = (pixel_0_0 * ix + pixel_0_1 * fx) * iy +
                (pixel_1_0 * ix + pixel_1_1 * fx) * fy;
        }
    }

    return applyScaleAndClamp(color, state, apply_srgb_convertion);
}

pub fn blitRegion(src: *const SoftImage, dst: *SoftImage, region: vk.ImageBlit, filter: vk.Filter) VkError!void {
    try blitRegionWithFormats(
        src,
        dst,
        region,
        filter,
        base.format.fromAspect(src.interface.format, region.src_subresource.aspect_mask),
        base.format.fromAspect(dst.interface.format, region.dst_subresource.aspect_mask),
    );
}

pub fn blitRegionWithFormats(src: *const SoftImage, dst: *SoftImage, region: vk.ImageBlit, filter: vk.Filter, src_format: vk.Format, dst_format: vk.Format) VkError!void {
    const io = dst.interface.owner.io();
    const timer = std.Io.Timestamp.now(io, .real);
    defer if (comptime base.config.logs != .none) {
        const duration = timer.untilNow(io, .real);
        const ms: f32 = @floatFromInt(duration.toMicroseconds());
        std.log.scoped(.SoftwareBlitter).debug("Image blit took {}ms", .{ms / 1000});
    };

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

    const src_slice_pitch_bytes = src.getSliceMemSizeForMipLevelWithFormat(region.src_subresource.aspect_mask, region.src_subresource.mip_level, src_format);
    const src_row_pitch_bytes = src.getRowPitchMemSizeForMipLevelWithFormat(region.src_subresource.aspect_mask, region.src_subresource.mip_level, src_format);
    const dst_slice_pitch_bytes = dst.getSliceMemSizeForMipLevelWithFormat(region.dst_subresource.aspect_mask, region.dst_subresource.mip_level, dst_format);
    const dst_row_pitch_bytes = dst.getRowPitchMemSizeForMipLevelWithFormat(region.dst_subresource.aspect_mask, region.dst_subresource.mip_level, dst_format);

    const apply_filter = (filter != .nearest);
    const resolve_srgb = src.interface.samples.toInt() > 1 and dst.interface.samples.toInt() == 1 and
        base.format.isSrgb(src_format) and base.format.isSrgb(dst_format);
    const allow_srgb_conversion = apply_filter or resolve_srgb or base.format.isSrgb(src_format) != base.format.isSrgb(dst_format);

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
        const src_map: []u8 = try src_memory.map(src.interface.memory_offset + src_texel_offset, src_size);

        const dst_texel_offset = try dst.getTexelMemoryOffset(.{ .x = 0, .y = 0, .z = 0 }, dst_subresource);
        const dst_size = try dst.interface.getTotalSizeForAspect(dst_subresource.aspect_mask) - dst_texel_offset;
        const dst_map: []u8 = try dst_memory.map(dst.interface.memory_offset + dst_texel_offset, dst_size);

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
            clear_color_f = applyScaleAndClamp(readFloat4(data.src_map, state.src_format), state, true);
        }
    }

    for (@intCast(data.dst_offset_0.z)..@intCast(data.dst_offset_1.z)) |k| {
        const z = if (state.clear) data.pos[2] else data.pos[2] + @as(f32, @floatFromInt(k)) * data.depth_ratio;
        const z_offset = k * data.dst_slice_pitch_bytes;
        if (z_offset > data.dst_map.len)
            break;
        var dst_slice = data.dst_map[z_offset..];

        for (@intCast(data.dst_offset_0.y)..@intCast(data.dst_offset_1.y)) |j| {
            const y = if (state.clear) data.pos[1] else data.pos[1] + @as(f32, @floatFromInt(j)) * data.height_ratio;
            const y_offset = j * data.dst_row_pitch_bytes;
            if (y_offset > dst_slice.len)
                break;
            var dst_line = dst_slice[y_offset..];

            for (@intCast(data.dst_offset_0.x)..@intCast(data.dst_offset_1.x)) |i| {
                const x = if (state.clear) data.pos[0] else data.pos[0] + @as(f32, @floatFromInt(i)) * data.width_ratio;
                const x_offset = i * base.format.texelSize(state.dst_format);
                if (x_offset > dst_line.len)
                    break;
                var dst_pixel = dst_line[x_offset..];

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

/// Using image blitting to resolve
pub inline fn resolve(src: *const SoftImage, dst: *SoftImage, region: vk.ImageResolve) VkError!void {
    try resolveWithFormats(
        src,
        dst,
        region,
        base.format.fromAspect(src.interface.format, region.src_subresource.aspect_mask),
        base.format.fromAspect(dst.interface.format, region.dst_subresource.aspect_mask),
    );
}

pub inline fn resolveWithFormats(src: *const SoftImage, dst: *SoftImage, region: vk.ImageResolve, src_format: vk.Format, dst_format: vk.Format) VkError!void {
    var blit_region: vk.ImageBlit = .{
        .src_offsets = .{ region.src_offset, region.src_offset },
        .src_subresource = region.src_subresource,
        .dst_offsets = .{ region.dst_offset, region.dst_offset },
        .dst_subresource = region.dst_subresource,
    };

    blit_region.src_offsets[1].x += @intCast(region.extent.width);
    blit_region.src_offsets[1].y += @intCast(region.extent.height);
    blit_region.src_offsets[1].z += @intCast(region.extent.depth);

    blit_region.dst_offsets[1].x += @intCast(region.extent.width);
    blit_region.dst_offsets[1].y += @intCast(region.extent.height);
    blit_region.dst_offsets[1].z += @intCast(region.extent.depth);

    try blitRegionWithFormats(src, dst, blit_region, .nearest, src_format, dst_format);
}

fn applyScaleAndClamp(base_color: F32x4, state: State, apply_srgb_convertion: bool) F32x4 {
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

    const is_src_srgb = base.format.isSrgb(state.src_format);
    const is_dst_srgb = base.format.isSrgb(state.dst_format);

    if (state.allow_srgb_conversion and ((is_src_srgb and apply_srgb_convertion) or is_dst_srgb)) {
        color = if (is_src_srgb and apply_srgb_convertion) zm.srgbToRgb(color) else zm.rgbToSrgb(color);
    }

    if (!base.format.isUnsigned(state.src_format) and base.format.isUnsigned(state.dst_format)) {
        color = @max(color, zm.f32x4s(0.0));
    }

    return color;
}

inline fn normalizedI8(value: u8) f32 {
    const signed: i8 = @bitCast(value);
    return @max(@as(f32, @floatFromInt(signed)) / @as(f32, @floatFromInt(std.math.maxInt(i8))), -1.0);
}

inline fn normalizedI16(value: u16) f32 {
    const signed: i16 = @bitCast(value);
    return @max(@as(f32, @floatFromInt(signed)) / @as(f32, @floatFromInt(std.math.maxInt(i16))), -1.0);
}

inline fn signedBits(value: u32, comptime bits: u5) i32 {
    const shift: u5 = @intCast(32 - @as(u32, bits));
    return @as(i32, @bitCast(value << shift)) >> shift;
}

inline fn normalizedSignedBits(value: u32, comptime bits: u5) f32 {
    const max = (1 << (bits - 1)) - 1;
    return @max(@as(f32, @floatFromInt(signedBits(value, bits))) / @as(f32, @floatFromInt(max)), -1.0);
}

pub fn readFloat4(map: []const u8, src_format: vk.Format) F32x4 {
    var c: F32x4 = .{ 0.0, 0.0, 0.0, 1.0 };

    switch (src_format) {
        .r8_uscaled => c[0] = @floatFromInt(map[0]),

        .r8_uint,
        .r8_unorm,
        .r8_srgb,
        => c[0] = @as(f32, @floatFromInt(map[0])) / std.math.maxInt(u8),

        .r8_sscaled => c[0] = @floatFromInt(@as(i8, @bitCast(map[0]))),

        .r8_sint,
        .r8_snorm,
        => c[0] = normalizedI8(map[0]),

        .r16_uscaled => c[0] = @floatFromInt(std.mem.bytesToValue(u16, map)),

        .r16_sscaled => c[0] = @floatFromInt(@as(i16, @bitCast(std.mem.bytesToValue(u16, map)))),

        .r16_snorm => c[0] = normalizedI16(std.mem.bytesToValue(u16, map)),
        .r16_unorm,
        .d16_unorm,
        => c[0] = @as(f32, @floatFromInt(std.mem.bytesToValue(u16, map))) / std.math.maxInt(u16),
        .x8_d24_unorm_pack32,
        .d24_unorm_s8_uint,
        => c[0] = @as(f32, @floatFromInt(std.mem.bytesToValue(u32, map) & 0x00ff_ffff)) / @as(f32, @floatFromInt(0x00ff_ffff)),

        .r8g8b8a8_sint,
        .r8g8b8a8_uint,
        .r8g8b8a8_srgb,
        .r8g8b8a8_unorm,
        => {
            c[0] = @as(f32, @floatFromInt(map[0])) / std.math.maxInt(u8);
            c[1] = @as(f32, @floatFromInt(map[1])) / std.math.maxInt(u8);
            c[2] = @as(f32, @floatFromInt(map[2])) / std.math.maxInt(u8);
            c[3] = @as(f32, @floatFromInt(map[3])) / std.math.maxInt(u8);
        },

        .r8g8_uscaled => {
            c[0] = @floatFromInt(map[0]);
            c[1] = @floatFromInt(map[1]);
        },

        .r8g8_uint,
        .r8g8_unorm,
        .r8g8_srgb,
        => {
            c[0] = @as(f32, @floatFromInt(map[0])) / std.math.maxInt(u8);
            c[1] = @as(f32, @floatFromInt(map[1])) / std.math.maxInt(u8);
        },

        .r8g8_sscaled => {
            c[0] = @floatFromInt(@as(i8, @bitCast(map[0])));
            c[1] = @floatFromInt(@as(i8, @bitCast(map[1])));
        },

        .r8g8_sint,
        .r8g8_snorm,
        => {
            c[0] = normalizedI8(map[0]);
            c[1] = normalizedI8(map[1]);
        },

        .r8g8b8a8_uscaled => {
            c[0] = @floatFromInt(map[0]);
            c[1] = @floatFromInt(map[1]);
            c[2] = @floatFromInt(map[2]);
            c[3] = @floatFromInt(map[3]);
        },

        .r8g8b8a8_sscaled => {
            c[0] = @floatFromInt(@as(i8, @bitCast(map[0])));
            c[1] = @floatFromInt(@as(i8, @bitCast(map[1])));
            c[2] = @floatFromInt(@as(i8, @bitCast(map[2])));
            c[3] = @floatFromInt(@as(i8, @bitCast(map[3])));
        },

        .r8g8b8a8_snorm => {
            c[0] = normalizedI8(map[0]);
            c[1] = normalizedI8(map[1]);
            c[2] = normalizedI8(map[2]);
            c[3] = normalizedI8(map[3]);
        },

        .r4g4b4a4_unorm_pack16 => {
            const pack = std.mem.bytesToValue(u16, map);
            c[0] = @as(f32, @floatFromInt((pack & 0xF000) >> 12)) / std.math.maxInt(u4);
            c[1] = @as(f32, @floatFromInt((pack & 0x0F00) >> 8)) / std.math.maxInt(u4);
            c[2] = @as(f32, @floatFromInt((pack & 0x00F0) >> 4)) / std.math.maxInt(u4);
            c[3] = @as(f32, @floatFromInt((pack & 0x000F) >> 0)) / std.math.maxInt(u4);
        },

        .b4g4r4a4_unorm_pack16 => {
            const pack = std.mem.bytesToValue(u16, map);
            c[2] = @as(f32, @floatFromInt((pack & 0xF000) >> 12)) / std.math.maxInt(u4);
            c[1] = @as(f32, @floatFromInt((pack & 0x0F00) >> 8)) / std.math.maxInt(u4);
            c[0] = @as(f32, @floatFromInt((pack & 0x00F0) >> 4)) / std.math.maxInt(u4);
            c[3] = @as(f32, @floatFromInt((pack & 0x000F) >> 0)) / std.math.maxInt(u4);
        },

        .a4r4g4b4_unorm_pack16 => {
            const pack = std.mem.bytesToValue(u16, map);
            c[3] = @as(f32, @floatFromInt((pack & 0xF000) >> 12)) / std.math.maxInt(u4);
            c[0] = @as(f32, @floatFromInt((pack & 0x0F00) >> 8)) / std.math.maxInt(u4);
            c[1] = @as(f32, @floatFromInt((pack & 0x00F0) >> 4)) / std.math.maxInt(u4);
            c[2] = @as(f32, @floatFromInt((pack & 0x000F) >> 0)) / std.math.maxInt(u4);
        },

        .a4b4g4r4_unorm_pack16 => {
            const pack = std.mem.bytesToValue(u16, map);
            c[3] = @as(f32, @floatFromInt((pack & 0xF000) >> 12)) / std.math.maxInt(u4);
            c[2] = @as(f32, @floatFromInt((pack & 0x0F00) >> 8)) / std.math.maxInt(u4);
            c[1] = @as(f32, @floatFromInt((pack & 0x00F0) >> 4)) / std.math.maxInt(u4);
            c[0] = @as(f32, @floatFromInt((pack & 0x000F) >> 0)) / std.math.maxInt(u4);
        },

        .r16_sint,
        .r16_uint,
        => c[0] = @floatFromInt(std.mem.bytesToValue(u16, map)),

        .r16_sfloat => c[0] = std.mem.bytesToValue(f16, map),

        .r16g16_uscaled => {
            c[0] = @floatFromInt(std.mem.bytesToValue(u16, map[0..]));
            c[1] = @floatFromInt(std.mem.bytesToValue(u16, map[2..]));
        },

        .r16g16_sint,
        .r16g16_uint,
        => {
            c[0] = @floatFromInt(std.mem.bytesToValue(u16, map[0..]));
            c[1] = @floatFromInt(std.mem.bytesToValue(u16, map[2..]));
        },

        .r16g16_sscaled => {
            c[0] = @floatFromInt(@as(i16, @bitCast(std.mem.bytesToValue(u16, map[0..]))));
            c[1] = @floatFromInt(@as(i16, @bitCast(std.mem.bytesToValue(u16, map[2..]))));
        },

        .r16g16_snorm => {
            c[0] = normalizedI16(std.mem.bytesToValue(u16, map[0..]));
            c[1] = normalizedI16(std.mem.bytesToValue(u16, map[2..]));
        },

        .r16g16_unorm => {
            c[0] = @as(f32, @floatFromInt(std.mem.bytesToValue(u16, map[0..]))) / std.math.maxInt(u16);
            c[1] = @as(f32, @floatFromInt(std.mem.bytesToValue(u16, map[2..]))) / std.math.maxInt(u16);
        },

        .r16g16_sfloat => {
            c[0] = std.mem.bytesToValue(f16, map[0..]);
            c[1] = std.mem.bytesToValue(f16, map[2..]);
        },

        .r32_sint,
        .r32_uint,
        => c[0] = @floatFromInt(std.mem.bytesToValue(u32, map)),

        .r32g32_sfloat => {
            c[0] = std.mem.bytesToValue(f32, map[0..]);
            c[1] = std.mem.bytesToValue(f32, map[4..]);
        },

        .r32g32b32_sfloat => {
            c[0] = std.mem.bytesToValue(f32, map[0..]);
            c[1] = std.mem.bytesToValue(f32, map[4..]);
            c[2] = std.mem.bytesToValue(f32, map[8..]);
        },

        .d32_sfloat,
        .r32_sfloat,
        => c[0] = std.mem.bytesToValue(f32, map),

        .r16g16b16a16_uint,
        .r16g16b16a16_unorm,
        => {
            c[0] = @as(f32, @floatFromInt(std.mem.bytesToValue(u16, map[0..]))) / std.math.maxInt(u16);
            c[1] = @as(f32, @floatFromInt(std.mem.bytesToValue(u16, map[2..]))) / std.math.maxInt(u16);
            c[2] = @as(f32, @floatFromInt(std.mem.bytesToValue(u16, map[4..]))) / std.math.maxInt(u16);
            c[3] = @as(f32, @floatFromInt(std.mem.bytesToValue(u16, map[6..]))) / std.math.maxInt(u16);
        },

        .r16g16b16a16_uscaled => {
            c[0] = @floatFromInt(std.mem.bytesToValue(u16, map[0..]));
            c[1] = @floatFromInt(std.mem.bytesToValue(u16, map[2..]));
            c[2] = @floatFromInt(std.mem.bytesToValue(u16, map[4..]));
            c[3] = @floatFromInt(std.mem.bytesToValue(u16, map[6..]));
        },

        .r16g16b16a16_sscaled => {
            c[0] = @floatFromInt(@as(i16, @bitCast(std.mem.bytesToValue(u16, map[0..]))));
            c[1] = @floatFromInt(@as(i16, @bitCast(std.mem.bytesToValue(u16, map[2..]))));
            c[2] = @floatFromInt(@as(i16, @bitCast(std.mem.bytesToValue(u16, map[4..]))));
            c[3] = @floatFromInt(@as(i16, @bitCast(std.mem.bytesToValue(u16, map[6..]))));
        },

        .r16g16b16a16_sint,
        .r16g16b16a16_snorm,
        => {
            c[0] = normalizedI16(std.mem.bytesToValue(u16, map[0..]));
            c[1] = normalizedI16(std.mem.bytesToValue(u16, map[2..]));
            c[2] = normalizedI16(std.mem.bytesToValue(u16, map[4..]));
            c[3] = normalizedI16(std.mem.bytesToValue(u16, map[6..]));
        },

        .r16g16b16a16_sfloat => c = std.mem.bytesToValue(@Vector(4, f16), map),

        .r32g32b32a32_sfloat => c = std.mem.bytesToValue(F32x4, map),

        .r32g32b32a32_uint => c = @floatFromInt(std.mem.bytesToValue(U32x4, map)),

        .s8_uint => c[0] = @floatFromInt(map[0]),

        .b8g8r8a8_srgb,
        .b8g8r8a8_unorm,
        => {
            c[0] = @as(f32, @floatFromInt(map[2])) / std.math.maxInt(u8);
            c[1] = @as(f32, @floatFromInt(map[1])) / std.math.maxInt(u8);
            c[2] = @as(f32, @floatFromInt(map[0])) / std.math.maxInt(u8);
            c[3] = @as(f32, @floatFromInt(map[3])) / std.math.maxInt(u8);
        },

        .a8b8g8r8_uint_pack32,
        .a8b8g8r8_unorm_pack32,
        .a8b8g8r8_srgb_pack32,
        => {
            const pack = std.mem.bytesToValue(@Vector(4, u8), map);
            c[0] = @as(f32, @floatFromInt(pack[0])) / std.math.maxInt(u8);
            c[1] = @as(f32, @floatFromInt(pack[1])) / std.math.maxInt(u8);
            c[2] = @as(f32, @floatFromInt(pack[2])) / std.math.maxInt(u8);
            c[3] = @as(f32, @floatFromInt(pack[3])) / std.math.maxInt(u8);
        },

        .a8b8g8r8_sint_pack32,
        .a8b8g8r8_snorm_pack32,
        => {
            const pack = std.mem.bytesToValue(@Vector(4, u8), map);
            c[0] = normalizedI8(pack[0]);
            c[1] = normalizedI8(pack[1]);
            c[2] = normalizedI8(pack[2]);
            c[3] = normalizedI8(pack[3]);
        },

        .a8b8g8r8_uscaled_pack32 => {
            const pack = std.mem.bytesToValue(@Vector(4, u8), map);
            c[0] = @floatFromInt(pack[0]);
            c[1] = @floatFromInt(pack[1]);
            c[2] = @floatFromInt(pack[2]);
            c[3] = @floatFromInt(pack[3]);
        },

        .a8b8g8r8_sscaled_pack32 => {
            const pack = std.mem.bytesToValue(@Vector(4, u8), map);
            c[0] = @floatFromInt(@as(i8, @bitCast(pack[0])));
            c[1] = @floatFromInt(@as(i8, @bitCast(pack[1])));
            c[2] = @floatFromInt(@as(i8, @bitCast(pack[2])));
            c[3] = @floatFromInt(@as(i8, @bitCast(pack[3])));
        },

        .a2b10g10r10_uint_pack32,
        .a2b10g10r10_unorm_pack32,
        => {
            const pack = std.mem.bytesToValue(u32, map);
            c[0] = @as(f32, @floatFromInt(pack & 0x000003FF)) / std.math.maxInt(u10);
            c[1] = @as(f32, @floatFromInt((pack & 0x000FFC00) >> 10)) / std.math.maxInt(u10);
            c[2] = @as(f32, @floatFromInt((pack & 0x3FF00000) >> 20)) / std.math.maxInt(u10);
            c[3] = @as(f32, @floatFromInt((pack & 0xC0000000) >> 30)) / std.math.maxInt(u2);
        },

        .a2b10g10r10_uscaled_pack32 => {
            const pack = std.mem.bytesToValue(u32, map);
            c[0] = @floatFromInt(pack & 0x000003FF);
            c[1] = @floatFromInt((pack & 0x000FFC00) >> 10);
            c[2] = @floatFromInt((pack & 0x3FF00000) >> 20);
            c[3] = @floatFromInt((pack & 0xC0000000) >> 30);
        },

        .a2b10g10r10_sscaled_pack32 => {
            const pack = std.mem.bytesToValue(u32, map);
            c[0] = @floatFromInt(signedBits(pack & 0x000003FF, 10));
            c[1] = @floatFromInt(signedBits((pack & 0x000FFC00) >> 10, 10));
            c[2] = @floatFromInt(signedBits((pack & 0x3FF00000) >> 20, 10));
            c[3] = @floatFromInt(signedBits((pack & 0xC0000000) >> 30, 2));
        },

        .a2b10g10r10_snorm_pack32 => {
            const pack = std.mem.bytesToValue(u32, map);
            c[0] = normalizedSignedBits(pack & 0x000003FF, 10);
            c[1] = normalizedSignedBits((pack & 0x000FFC00) >> 10, 10);
            c[2] = normalizedSignedBits((pack & 0x3FF00000) >> 20, 10);
            c[3] = normalizedSignedBits((pack & 0xC0000000) >> 30, 2);
        },

        .a2r10g10b10_uint_pack32,
        .a2r10g10b10_unorm_pack32,
        => {
            const pack = std.mem.bytesToValue(u32, map);
            c[2] = @as(f32, @floatFromInt(pack & 0x000003FF)) / std.math.maxInt(u10);
            c[1] = @as(f32, @floatFromInt((pack & 0x000FFC00) >> 10)) / std.math.maxInt(u10);
            c[0] = @as(f32, @floatFromInt((pack & 0x3FF00000) >> 20)) / std.math.maxInt(u10);
            c[3] = @as(f32, @floatFromInt((pack & 0xC0000000) >> 30)) / std.math.maxInt(u2);
        },

        .a2r10g10b10_uscaled_pack32 => {
            const pack = std.mem.bytesToValue(u32, map);
            c[2] = @floatFromInt(pack & 0x000003FF);
            c[1] = @floatFromInt((pack & 0x000FFC00) >> 10);
            c[0] = @floatFromInt((pack & 0x3FF00000) >> 20);
            c[3] = @floatFromInt((pack & 0xC0000000) >> 30);
        },

        .a2r10g10b10_sscaled_pack32 => {
            const pack = std.mem.bytesToValue(u32, map);
            c[2] = @floatFromInt(signedBits(pack & 0x000003FF, 10));
            c[1] = @floatFromInt(signedBits((pack & 0x000FFC00) >> 10, 10));
            c[0] = @floatFromInt(signedBits((pack & 0x3FF00000) >> 20, 10));
            c[3] = @floatFromInt(signedBits((pack & 0xC0000000) >> 30, 2));
        },

        .a2r10g10b10_snorm_pack32 => {
            const pack = std.mem.bytesToValue(u32, map);
            c[2] = normalizedSignedBits(pack & 0x000003FF, 10);
            c[1] = normalizedSignedBits((pack & 0x000FFC00) >> 10, 10);
            c[0] = normalizedSignedBits((pack & 0x3FF00000) >> 20, 10);
            c[3] = normalizedSignedBits((pack & 0xC0000000) >> 30, 2);
        },

        .r5g6b5_unorm_pack16 => {
            const pack = std.mem.bytesToValue(u16, map);
            c[0] = @as(f32, @floatFromInt((pack & 0xF800) >> 11)) / std.math.maxInt(u5);
            c[1] = @as(f32, @floatFromInt((pack & 0x07E0) >> 5)) / std.math.maxInt(u6);
            c[2] = @as(f32, @floatFromInt((pack & 0x001F) >> 0)) / std.math.maxInt(u5);
        },

        .b5g6r5_unorm_pack16 => {
            const pack = std.mem.bytesToValue(u16, map);
            c[0] = @as(f32, @floatFromInt((pack & 0x001F) >> 0)) / std.math.maxInt(u5);
            c[1] = @as(f32, @floatFromInt((pack & 0x07E0) >> 5)) / std.math.maxInt(u6);
            c[2] = @as(f32, @floatFromInt((pack & 0xF800) >> 11)) / std.math.maxInt(u5);
        },

        .r5g5b5a1_unorm_pack16 => {
            const pack = std.mem.bytesToValue(u16, map);
            c[0] = @as(f32, @floatFromInt((pack & 0xF800) >> 11)) / std.math.maxInt(u5);
            c[1] = @as(f32, @floatFromInt((pack & 0x07C0) >> 6)) / std.math.maxInt(u5);
            c[2] = @as(f32, @floatFromInt((pack & 0x003E) >> 1)) / std.math.maxInt(u5);
            c[3] = @as(f32, @floatFromInt((pack & 0x0001) >> 0));
        },

        .b5g5r5a1_unorm_pack16 => {
            const pack = std.mem.bytesToValue(u16, map);
            c[2] = @as(f32, @floatFromInt((pack & 0xF800) >> 11)) / std.math.maxInt(u5);
            c[1] = @as(f32, @floatFromInt((pack & 0x07C0) >> 6)) / std.math.maxInt(u5);
            c[0] = @as(f32, @floatFromInt((pack & 0x003E) >> 1)) / std.math.maxInt(u5);
            c[3] = @as(f32, @floatFromInt((pack & 0x0001) >> 0));
        },

        .a1r5g5b5_unorm_pack16 => {
            const pack = std.mem.bytesToValue(u16, map);
            c[0] = @as(f32, @floatFromInt((pack & 0x7C00) >> 10)) / std.math.maxInt(u5);
            c[1] = @as(f32, @floatFromInt((pack & 0x03E0) >> 5)) / std.math.maxInt(u5);
            c[2] = @as(f32, @floatFromInt((pack & 0x001F) >> 0)) / std.math.maxInt(u5);
            c[3] = @as(f32, @floatFromInt((pack & 0x8000) >> 15));
        },

        .b10g11r11_ufloat_pack32 => {
            const pack = std.mem.bytesToValue(u32, map);

            const r_bits = (pack >> 0) & 0x7FF;
            const g_bits = (pack >> 11) & 0x7FF;
            const b_bits = (pack >> 22) & 0x3FF;

            c[0] = decodeUFloat(r_bits, 6);
            c[1] = decodeUFloat(g_bits, 6);
            c[2] = decodeUFloat(b_bits, 5);
            c[3] = 1.0;
        },

        .e5b9g9r9_ufloat_pack32 => {
            const pack = std.mem.bytesToValue(u32, map);

            const r_mantissa: u32 = (pack >> 0) & 0x1FF;
            const g_mantissa: u32 = (pack >> 9) & 0x1FF;
            const b_mantissa: u32 = (pack >> 18) & 0x1FF;
            const exponent: u32 = (pack >> 27) & 0x1F;

            if (exponent == 0 and r_mantissa == 0 and g_mantissa == 0 and b_mantissa == 0) {
                c = .{ 0.0, 0.0, 0.0, 1.0 };
            } else {
                const scale = std.math.pow(f32, 2.0, @as(f32, @floatFromInt(@as(i32, @intCast(exponent)) - 24)));

                c[0] = @as(f32, @floatFromInt(r_mantissa)) * scale;
                c[1] = @as(f32, @floatFromInt(g_mantissa)) * scale;
                c[2] = @as(f32, @floatFromInt(b_mantissa)) * scale;
                c[3] = 1.0;
            }
        },

        else => base.unsupported("Blitter: read float from source format {any}", .{src_format}),
    }

    return c;
}

pub fn writeFloat4(c: F32x4, map: []u8, dst_format: vk.Format) void {
    const color = std.math.clamp(c, zm.f32x4s(base.format.minElementValue(dst_format)), zm.f32x4s(base.format.maxElementValue(dst_format)));

    switch (dst_format) {
        .r8_unorm,
        .r8_srgb,
        .s8_uint,
        => map[0] = @intFromFloat(@round(color[0] * std.math.maxInt(u8))),

        .r8_snorm => map[0] = @bitCast(@as(i8, @intFromFloat(@round(color[0] * std.math.maxInt(i8))))),

        .r16_sint,
        .r16_uint,
        => std.mem.bytesAsValue(u16, map).* = @intFromFloat(@round(color[0])),

        .r16_snorm => std.mem.bytesAsValue(u16, map).* = @bitCast(@as(i16, @intFromFloat(@round(color[0] * std.math.maxInt(i16))))),

        .r16_unorm,
        .d16_unorm,
        => std.mem.bytesAsValue(u16, map).* = @intFromFloat(@round(color[0] * std.math.maxInt(u16))),

        .x8_d24_unorm_pack32,
        .d24_unorm_s8_uint,
        => {
            const depth: u32 = @intFromFloat(@round(color[0] * @as(f32, @floatFromInt(0x00ff_ffff))));
            const preserved: u32 = std.mem.bytesToValue(u32, map) & 0xff00_0000;
            std.mem.bytesAsValue(u32, map).* = preserved | depth;
        },

        .r16_sfloat => std.mem.bytesAsValue(f16, map).* = @floatCast(color[0]),

        .r32_sint,
        .r32_uint,
        => std.mem.bytesAsValue(u32, map).* = @intFromFloat(@round(color[0])),

        .r32_sfloat,
        .d32_sfloat,
        => std.mem.bytesAsValue(f32, map).* = color[0],

        .r8g8_snorm => {
            map[0] = @bitCast(@as(i8, @intFromFloat(@round(color[0] * std.math.maxInt(i8)))));
            map[1] = @bitCast(@as(i8, @intFromFloat(@round(color[1] * std.math.maxInt(i8)))));
        },

        .r8g8_unorm,
        .r8g8_srgb,
        => {
            map[0] = @intFromFloat(@round(color[0] * std.math.maxInt(u8)));
            map[1] = @intFromFloat(@round(color[1] * std.math.maxInt(u8)));
        },

        .r16g16_snorm => {
            std.mem.bytesAsValue(u16, map[0..]).* = @bitCast(@as(i16, @intFromFloat(@round(color[0] * std.math.maxInt(i16)))));
            std.mem.bytesAsValue(u16, map[2..]).* = @bitCast(@as(i16, @intFromFloat(@round(color[1] * std.math.maxInt(i16)))));
        },

        .r16g16_unorm => {
            std.mem.bytesAsValue(u16, map[0..]).* = @intFromFloat(@round(color[0] * std.math.maxInt(u16)));
            std.mem.bytesAsValue(u16, map[2..]).* = @intFromFloat(@round(color[1] * std.math.maxInt(u16)));
        },

        .r16g16_uint => {
            std.mem.bytesAsValue(u16, map[0..]).* = @intFromFloat(@round(color[0]));
            std.mem.bytesAsValue(u16, map[2..]).* = @intFromFloat(@round(color[1]));
        },

        .r16g16_sfloat => {
            std.mem.bytesAsValue(f16, map[0..]).* = @floatCast(color[0]);
            std.mem.bytesAsValue(f16, map[2..]).* = @floatCast(color[1]);
        },

        .r32g32_sfloat => {
            std.mem.bytesAsValue(f32, map[0..]).* = color[0];
            std.mem.bytesAsValue(f32, map[4..]).* = color[1];
        },

        .r16g16b16a16_uint,
        .r16g16b16a16_unorm,
        => {
            std.mem.bytesAsValue(u16, map[0..]).* = @intFromFloat(@round(color[0] * std.math.maxInt(u16)));
            std.mem.bytesAsValue(u16, map[2..]).* = @intFromFloat(@round(color[1] * std.math.maxInt(u16)));
            std.mem.bytesAsValue(u16, map[4..]).* = @intFromFloat(@round(color[2] * std.math.maxInt(u16)));
            std.mem.bytesAsValue(u16, map[6..]).* = @intFromFloat(@round(color[3] * std.math.maxInt(u16)));
        },

        .r16g16b16a16_sint,
        .r16g16b16a16_snorm,
        => {
            std.mem.bytesAsValue(u16, map[0..]).* = @bitCast(@as(i16, @intFromFloat(@round(color[0] * std.math.maxInt(i16)))));
            std.mem.bytesAsValue(u16, map[2..]).* = @bitCast(@as(i16, @intFromFloat(@round(color[1] * std.math.maxInt(i16)))));
            std.mem.bytesAsValue(u16, map[4..]).* = @bitCast(@as(i16, @intFromFloat(@round(color[2] * std.math.maxInt(i16)))));
            std.mem.bytesAsValue(u16, map[6..]).* = @bitCast(@as(i16, @intFromFloat(@round(color[3] * std.math.maxInt(i16)))));
        },

        .r16g16b16a16_sfloat => {
            std.mem.bytesAsValue(f16, map[0..]).* = @floatCast(color[0]);
            std.mem.bytesAsValue(f16, map[2..]).* = @floatCast(color[1]);
            std.mem.bytesAsValue(f16, map[4..]).* = @floatCast(color[2]);
            std.mem.bytesAsValue(f16, map[6..]).* = @floatCast(color[3]);
        },

        .b8g8r8a8_srgb,
        .b8g8r8a8_unorm,
        => {
            map[0] = @intFromFloat(@round(color[2] * std.math.maxInt(u8)));
            map[1] = @intFromFloat(@round(color[1] * std.math.maxInt(u8)));
            map[2] = @intFromFloat(@round(color[0] * std.math.maxInt(u8)));
            map[3] = @intFromFloat(@round(color[3] * std.math.maxInt(u8)));
        },

        .r4g4b4a4_unorm_pack16 => {
            const r: u4 = @intFromFloat(@round(color[0] * std.math.maxInt(u4)));
            const g: u4 = @intFromFloat(@round(color[1] * std.math.maxInt(u4)));
            const b: u4 = @intFromFloat(@round(color[2] * std.math.maxInt(u4)));
            const a: u4 = @intFromFloat(@round(color[3] * std.math.maxInt(u4)));
            std.mem.bytesAsValue(u16, map[0..]).* =
                (@as(u16, r) << 12) |
                (@as(u16, g) << 8) |
                (@as(u16, b) << 4) |
                (@as(u16, a) << 0);
        },

        .b4g4r4a4_unorm_pack16 => {
            const r: u4 = @intFromFloat(@round(color[0] * std.math.maxInt(u4)));
            const g: u4 = @intFromFloat(@round(color[1] * std.math.maxInt(u4)));
            const b: u4 = @intFromFloat(@round(color[2] * std.math.maxInt(u4)));
            const a: u4 = @intFromFloat(@round(color[3] * std.math.maxInt(u4)));
            std.mem.bytesAsValue(u16, map[0..]).* =
                (@as(u16, b) << 12) |
                (@as(u16, g) << 8) |
                (@as(u16, r) << 4) |
                (@as(u16, a) << 0);
        },

        .a4r4g4b4_unorm_pack16 => {
            const r: u4 = @intFromFloat(@round(color[0] * std.math.maxInt(u4)));
            const g: u4 = @intFromFloat(@round(color[1] * std.math.maxInt(u4)));
            const b: u4 = @intFromFloat(@round(color[2] * std.math.maxInt(u4)));
            const a: u4 = @intFromFloat(@round(color[3] * std.math.maxInt(u4)));
            std.mem.bytesAsValue(u16, map[0..]).* =
                (@as(u16, a) << 12) |
                (@as(u16, r) << 8) |
                (@as(u16, g) << 4) |
                (@as(u16, b) << 0);
        },

        .a4b4g4r4_unorm_pack16 => {
            const r: u4 = @intFromFloat(@round(color[0] * std.math.maxInt(u4)));
            const g: u4 = @intFromFloat(@round(color[1] * std.math.maxInt(u4)));
            const b: u4 = @intFromFloat(@round(color[2] * std.math.maxInt(u4)));
            const a: u4 = @intFromFloat(@round(color[3] * std.math.maxInt(u4)));
            std.mem.bytesAsValue(u16, map[0..]).* =
                (@as(u16, a) << 12) |
                (@as(u16, b) << 8) |
                (@as(u16, g) << 4) |
                (@as(u16, r) << 0);
        },

        .r8g8b8a8_unorm,
        .r8g8b8a8_srgb,
        .r8g8b8a8_uint,
        .r8g8b8a8_uscaled,
        .a8b8g8r8_unorm_pack32,
        .a8b8g8r8_srgb_pack32,
        .a8b8g8r8_uint_pack32,
        .a8b8g8r8_uscaled_pack32,
        => {
            map[0] = @intFromFloat(@round(color[0] * std.math.maxInt(u8)));
            map[1] = @intFromFloat(@round(color[1] * std.math.maxInt(u8)));
            map[2] = @intFromFloat(@round(color[2] * std.math.maxInt(u8)));
            map[3] = @intFromFloat(@round(color[3] * std.math.maxInt(u8)));
        },

        .a8b8g8r8_sint_pack32,
        .a8b8g8r8_snorm_pack32,
        => {
            map[0] = @bitCast(@as(i8, @intFromFloat(@round(color[0] * std.math.maxInt(i8)))));
            map[1] = @bitCast(@as(i8, @intFromFloat(@round(color[1] * std.math.maxInt(i8)))));
            map[2] = @bitCast(@as(i8, @intFromFloat(@round(color[2] * std.math.maxInt(i8)))));
            map[3] = @bitCast(@as(i8, @intFromFloat(@round(color[3] * std.math.maxInt(i8)))));
        },

        .r8g8b8a8_snorm => {
            map[0] = @bitCast(@as(i8, @intFromFloat(@round(color[0] * std.math.maxInt(i8)))));
            map[1] = @bitCast(@as(i8, @intFromFloat(@round(color[1] * std.math.maxInt(i8)))));
            map[2] = @bitCast(@as(i8, @intFromFloat(@round(color[2] * std.math.maxInt(i8)))));
            map[3] = @bitCast(@as(i8, @intFromFloat(@round(color[3] * std.math.maxInt(i8)))));
        },

        .a2r10g10b10_uint_pack32,
        .a2r10g10b10_unorm_pack32,
        => {
            const r: u10 = @intFromFloat(@round(color[0] * std.math.maxInt(u10)));
            const g: u10 = @intFromFloat(@round(color[1] * std.math.maxInt(u10)));
            const b: u10 = @intFromFloat(@round(color[2] * std.math.maxInt(u10)));
            const a: u2 = @intFromFloat(@round(color[3] * std.math.maxInt(u2)));
            std.mem.bytesAsValue(u32, map).* =
                (@as(u32, b) << 0) |
                (@as(u32, g) << 10) |
                (@as(u32, r) << 20) |
                (@as(u32, a) << 30);
        },

        .a2b10g10r10_uint_pack32,
        .a2b10g10r10_unorm_pack32,
        => {
            const r: u10 = @intFromFloat(@round(color[0] * std.math.maxInt(u10)));
            const g: u10 = @intFromFloat(@round(color[1] * std.math.maxInt(u10)));
            const b: u10 = @intFromFloat(@round(color[2] * std.math.maxInt(u10)));
            const a: u2 = @intFromFloat(@round(color[3] * std.math.maxInt(u2)));
            std.mem.bytesAsValue(u32, map).* =
                (@as(u32, r) << 0) |
                (@as(u32, g) << 10) |
                (@as(u32, b) << 20) |
                (@as(u32, a) << 30);
        },

        .r32g32b32a32_uint => std.mem.bytesAsValue(U32x4, map).* = @intFromFloat(@round(@as(@Vector(4, f64), color))),

        .r32g32b32a32_sfloat => std.mem.bytesAsValue(F32x4, map).* = color,

        .r5g6b5_unorm_pack16 => {
            const r: u5 = @intFromFloat(@round(color[0] * std.math.maxInt(u5)));
            const g: u6 = @intFromFloat(@round(color[1] * std.math.maxInt(u6)));
            const b: u5 = @intFromFloat(@round(color[2] * std.math.maxInt(u5)));
            std.mem.bytesAsValue(u16, map[0..]).* =
                (@as(u16, r) << 11) |
                (@as(u16, g) << 5) |
                (@as(u16, b) << 0);
        },

        .b5g6r5_unorm_pack16 => {
            const r: u5 = @intFromFloat(@round(color[0] * std.math.maxInt(u5)));
            const g: u6 = @intFromFloat(@round(color[1] * std.math.maxInt(u6)));
            const b: u5 = @intFromFloat(@round(color[2] * std.math.maxInt(u5)));
            std.mem.bytesAsValue(u16, map[0..]).* =
                (@as(u16, b) << 11) |
                (@as(u16, g) << 5) |
                (@as(u16, r) << 0);
        },

        .r5g5b5a1_unorm_pack16 => {
            const r: u5 = @intFromFloat(@round(color[0] * std.math.maxInt(u5)));
            const g: u5 = @intFromFloat(@round(color[1] * std.math.maxInt(u5)));
            const b: u5 = @intFromFloat(@round(color[2] * std.math.maxInt(u5)));
            const a: u1 = @intFromFloat(@round(color[3]));
            std.mem.bytesAsValue(u16, map).* =
                (@as(u16, r) << 11) |
                (@as(u16, g) << 6) |
                (@as(u16, b) << 1) |
                (@as(u16, a) << 0);
        },

        .b5g5r5a1_unorm_pack16 => {
            const r: u5 = @intFromFloat(@round(color[0] * std.math.maxInt(u5)));
            const g: u5 = @intFromFloat(@round(color[1] * std.math.maxInt(u5)));
            const b: u5 = @intFromFloat(@round(color[2] * std.math.maxInt(u5)));
            const a: u1 = @intFromFloat(@round(color[3]));
            std.mem.bytesAsValue(u16, map).* =
                (@as(u16, b) << 11) |
                (@as(u16, g) << 6) |
                (@as(u16, r) << 1) |
                (@as(u16, a) << 0);
        },

        .a1r5g5b5_unorm_pack16 => {
            const r: u5 = @intFromFloat(@round(color[0] * std.math.maxInt(u5)));
            const g: u5 = @intFromFloat(@round(color[1] * std.math.maxInt(u5)));
            const b: u5 = @intFromFloat(@round(color[2] * std.math.maxInt(u5)));
            const a: u1 = @intFromFloat(@round(color[3]));
            std.mem.bytesAsValue(u16, map).* =
                (@as(u16, b) << 0) |
                (@as(u16, g) << 5) |
                (@as(u16, r) << 10) |
                (@as(u16, a) << 15);
        },

        .b10g11r11_ufloat_pack32 => {
            const r = encodeUFloat(color[0], 6);
            const g = encodeUFloat(color[1], 6);
            const b = encodeUFloat(color[2], 5);

            std.mem.bytesAsValue(u32, map).* =
                (r << 0) |
                (g << 11) |
                (b << 22);
        },

        .e5b9g9r9_ufloat_pack32 => std.mem.bytesAsValue(u32, map).* = encodeE5B9G9R9(color),

        else => base.unsupported("Blitter: write float to destination format {any}", .{dst_format}),
    }
}

inline fn signExtendI8(value: u8) u32 {
    return @bitCast(@as(i32, @as(i8, @bitCast(value))));
}

inline fn signExtendI16(value: u16) u32 {
    return @bitCast(@as(i32, @as(i16, @bitCast(value))));
}

pub fn readInt4(map: []const u8, src_format: vk.Format) U32x4 {
    var c: U32x4 = .{ 0, 0, 0, 1 };

    switch (src_format) {
        .r8_uint,
        .s8_uint,
        => c[0] = map[0],

        .r8_sint => c[0] = signExtendI8(map[0]),

        .r16_uint,
        => c[0] = std.mem.bytesToValue(u16, map),

        .r16_sint => c[0] = signExtendI16(std.mem.bytesToValue(u16, map)),

        .r32_sint,
        .r32_uint,
        => c[0] = std.mem.bytesToValue(u32, map),

        .r8g8_uint,
        => {
            c[0] = map[0];
            c[1] = map[1];
        },

        .r8g8_sint => {
            c[0] = signExtendI8(map[0]);
            c[1] = signExtendI8(map[1]);
        },

        .r16g16_uint,
        => {
            c[0] = std.mem.bytesToValue(u16, map[0..]);
            c[1] = std.mem.bytesToValue(u16, map[2..]);
        },

        .r16g16_sint => {
            c[0] = signExtendI16(std.mem.bytesToValue(u16, map[0..]));
            c[1] = signExtendI16(std.mem.bytesToValue(u16, map[2..]));
        },

        .r32g32_sint,
        .r32g32_uint,
        => {
            c[0] = std.mem.bytesToValue(u32, map[0..]);
            c[1] = std.mem.bytesToValue(u32, map[4..]);
        },

        .r32g32b32_sint,
        .r32g32b32_uint,
        => {
            c[0] = std.mem.bytesToValue(u32, map[0..]);
            c[1] = std.mem.bytesToValue(u32, map[4..]);
            c[2] = std.mem.bytesToValue(u32, map[8..]);
        },

        .r8g8b8a8_uint,
        => {
            c[0] = map[0];
            c[1] = map[1];
            c[2] = map[2];
            c[3] = map[3];
        },

        .r8g8b8a8_sint => {
            c[0] = signExtendI8(map[0]);
            c[1] = signExtendI8(map[1]);
            c[2] = signExtendI8(map[2]);
            c[3] = signExtendI8(map[3]);
        },

        .r16g16b16a16_uint,
        => {
            c[0] = std.mem.bytesToValue(u16, map[0..2]);
            c[1] = std.mem.bytesToValue(u16, map[2..4]);
            c[2] = std.mem.bytesToValue(u16, map[4..6]);
            c[3] = std.mem.bytesToValue(u16, map[6..8]);
        },

        .r16g16b16a16_sint => {
            c[0] = signExtendI16(std.mem.bytesToValue(u16, map[0..2]));
            c[1] = signExtendI16(std.mem.bytesToValue(u16, map[2..4]));
            c[2] = signExtendI16(std.mem.bytesToValue(u16, map[4..6]));
            c[3] = signExtendI16(std.mem.bytesToValue(u16, map[6..8]));
        },

        .r32g32b32a32_sint,
        .r32g32b32a32_uint,
        => c = std.mem.bytesToValue(U32x4, map),

        .a8b8g8r8_uint_pack32,
        .a8b8g8r8_unorm_pack32,
        .a8b8g8r8_snorm_pack32,
        => {
            const pack = std.mem.bytesToValue(@Vector(4, u8), map);
            c[0] = pack[0];
            c[1] = pack[1];
            c[2] = pack[2];
            c[3] = pack[3];
        },

        .a8b8g8r8_sint_pack32 => {
            const pack = std.mem.bytesToValue(@Vector(4, u8), map);
            c[0] = signExtendI8(pack[0]);
            c[1] = signExtendI8(pack[1]);
            c[2] = signExtendI8(pack[2]);
            c[3] = signExtendI8(pack[3]);
        },

        .a2b10g10r10_unorm_pack32,
        .a2b10g10r10_uint_pack32,
        => {
            const pack = std.mem.bytesToValue(u32, map);
            c[0] = (pack & 0x000003FF);
            c[1] = (pack & 0x000FFC00) >> 10;
            c[2] = (pack & 0x3FF00000) >> 20;
            c[3] = (pack & 0xC0000000) >> 30;
        },

        .a2b10g10r10_sint_pack32 => {
            const pack = std.mem.bytesToValue(u32, map);
            c[0] = @bitCast(signedBits(pack & 0x000003FF, 10));
            c[1] = @bitCast(signedBits((pack & 0x000FFC00) >> 10, 10));
            c[2] = @bitCast(signedBits((pack & 0x3FF00000) >> 20, 10));
            c[3] = @bitCast(signedBits((pack & 0xC0000000) >> 30, 2));
        },

        .a2r10g10b10_unorm_pack32,
        .a2r10g10b10_uint_pack32,
        => {
            const pack = std.mem.bytesToValue(u32, map);
            c[2] = (pack & 0x000003FF);
            c[1] = (pack & 0x000FFC00) >> 10;
            c[0] = (pack & 0x3FF00000) >> 20;
            c[3] = (pack & 0xC0000000) >> 30;
        },

        .a2r10g10b10_sint_pack32 => {
            const pack = std.mem.bytesToValue(u32, map);
            c[2] = @bitCast(signedBits(pack & 0x000003FF, 10));
            c[1] = @bitCast(signedBits((pack & 0x000FFC00) >> 10, 10));
            c[0] = @bitCast(signedBits((pack & 0x3FF00000) >> 20, 10));
            c[3] = @bitCast(signedBits((pack & 0xC0000000) >> 30, 2));
        },

        else => base.unsupported("Blitter: read int from source format {any}", .{src_format}),
    }

    return c;
}

pub fn writeInt4(c: U32x4, map: []u8, dst_format: vk.Format) void {
    var color = c;

    // Sanitization prepass
    switch (dst_format) {
        .a2r10g10b10_uint_pack32,
        .a2b10g10r10_uint_pack32,
        => color = @min(color, U32x4{ 0x03FF, 0x03FF, 0x03FF, 0x003 }),

        .a8b8g8r8_uint_pack32,
        .r8g8b8a8_uint,
        .r8g8b8_uint,
        .r8g8_uint,
        .r8_uint,
        .r8g8b8a8_uscaled,
        .r8g8b8_uscaled,
        .r8g8_uscaled,
        .r8_uscaled,
        => color = @min(color, U32x4{ 0xFF, 0xFF, 0xFF, 0xFF }),

        .r16g16b16a16_uint,
        .r16g16b16_uint,
        .r16g16_uint,
        .r16_uint,
        .r16g16b16a16_uscaled,
        .r16g16b16_uscaled,
        .r16g16_uscaled,
        .r16_uscaled,
        => color = @min(color, U32x4{ 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF }),

        .a8b8g8r8_sint_pack32,
        .r8g8b8a8_sint,
        .r8g8_sint,
        .r8_sint,
        .r8g8b8a8_sscaled,
        .r8g8b8_sscaled,
        .r8g8_sscaled,
        .r8_sscaled,
        => color = @bitCast(std.math.clamp(@as(I32x4, @bitCast(color)), I32x4{ -0x80, -0x80, -0x80, -0x80 }, I32x4{ 0x7F, 0x7F, 0x7F, 0x7F })),

        .r16g16b16a16_sint,
        .r16g16b16_sint,
        .r16g16_sint,
        .r16_sint,
        .r16g16b16a16_sscaled,
        .r16g16b16_sscaled,
        .r16g16_sscaled,
        .r16_sscaled,
        => color = @bitCast(std.math.clamp(@as(I32x4, @bitCast(color)), I32x4{ -0x8000, -0x8000, -0x8000, -0x8000 }, I32x4{ 0x7FFF, 0x7FFF, 0x7FFF, 0x7FFF })),

        else => {},
    }

    switch (dst_format) {
        .r8_sint,
        .r8_uint,
        .s8_uint,
        => map[0] = @truncate(color[0]),

        .r8g8_sint,
        .r8g8_uint,
        => {
            map[0] = @truncate(color[0]);
            map[1] = @truncate(color[1]);
        },

        .r16_sint,
        .r16_uint,
        => std.mem.bytesAsValue(u16, map).* = @truncate(color[0]),

        .r16g16_sint,
        .r16g16_uint,
        => {
            std.mem.bytesAsValue(u16, map[0..]).* = @truncate(color[0]);
            std.mem.bytesAsValue(u16, map[2..]).* = @truncate(color[1]);
        },

        .r32_sint,
        .r32_uint,
        => std.mem.bytesAsValue(u32, map).* = color[0],

        .r32g32_sint,
        .r32g32_uint,
        => {
            std.mem.bytesAsValue(u32, map[0..]).* = color[0];
            std.mem.bytesAsValue(u32, map[4..]).* = color[1];
        },

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

        .a8b8g8r8_unorm_pack32,
        .a8b8g8r8_sint_pack32,
        .a8b8g8r8_srgb_pack32,
        .a8b8g8r8_uint_pack32,
        .a8b8g8r8_uscaled_pack32,
        => {
            map[0] = @truncate(color[0]);
            map[1] = @truncate(color[1]);
            map[2] = @truncate(color[2]);
            map[3] = @truncate(color[3]);
        },

        .a2r10g10b10_unorm_pack32,
        .a2r10g10b10_uint_pack32,
        .a2r10g10b10_uscaled_pack32,
        .a2r10g10b10_sscaled_pack32,
        => std.mem.bytesAsValue(u32, map).* =
            (color[0] << 20) |
            (color[2] << 0) |
            (color[1] << 10) |
            (color[3] << 30),

        .a2b10g10r10_unorm_pack32,
        .a2b10g10r10_uint_pack32,
        => std.mem.bytesAsValue(u32, map).* =
            (@as(u32, color[0] & 0x3FF) << 0) |
            (@as(u32, color[1] & 0x3FF) << 10) |
            (@as(u32, color[2] & 0x3FF) << 20) |
            (@as(u32, color[3] & 0x003) << 30),

        else => base.unsupported("Blitter: write int to destination format {any}", .{dst_format}),
    }
}

fn decodeUFloat(value: u32, mantissa_bits: comptime_int) f32 {
    const exponent_bits = 5;
    const exponent_bias = 15;

    const mantissa_mask = (1 << mantissa_bits) - 1;
    const exponent_mask = (1 << exponent_bits) - 1;

    const mantissa = value & mantissa_mask;
    const exponent = (value >> mantissa_bits) & exponent_mask;

    if (exponent == 0) {
        if (mantissa == 0)
            return 0.0;
        return std.math.ldexp(@as(f32, @floatFromInt(mantissa)) / @as(f32, @floatFromInt(1 << mantissa_bits)), 1 - exponent_bias);
    }

    if (exponent == exponent_mask) {
        if (mantissa == 0)
            return std.math.inf(f32);

        return std.math.nan(f32);
    }

    return std.math.ldexp(1.0 + (@as(f32, @floatFromInt(mantissa)) / @as(f32, @floatFromInt(1 << mantissa_bits))), @as(i32, @intCast(exponent)) - exponent_bias);
}

fn encodeUFloat(value: f32, mantissa_bits: comptime_int) u32 {
    const exponent_bits = 5;
    const exponent_bias = 15;
    const max_exponent = (1 << exponent_bits) - 1;

    if (std.math.isNan(value))
        return (max_exponent << mantissa_bits) | 1;

    if (std.math.isInf(value))
        return max_exponent << mantissa_bits;

    if (value <= 0.0)
        return 0;

    const parts = std.math.frexp(value);
    const normalized = parts.significand;
    const exponent = parts.exponent;

    const adjusted_exponent = exponent - 1 + exponent_bias;

    if (adjusted_exponent >= max_exponent)
        return max_exponent << mantissa_bits;

    if (adjusted_exponent <= 0) {
        const mantissa = @as(u32, @intFromFloat(@round(value * @as(f32, @floatFromInt(1 << (mantissa_bits + exponent_bias - 1))))));

        return mantissa;
    }

    const fraction = normalized * 2.0 - 1.0;

    var mantissa: u32 = @intFromFloat(@round(fraction * @as(f32, @floatFromInt(1 << mantissa_bits))));

    var exp_bits: u32 = @intCast(adjusted_exponent);

    if (mantissa == (1 << mantissa_bits)) {
        mantissa = 0;
        exp_bits += 1;

        if (exp_bits >= max_exponent)
            return max_exponent << mantissa_bits;
    }

    return (exp_bits << mantissa_bits) | mantissa;
}

fn clampE5B9G9R9Component(value: f32) f32 {
    const mantissa_bits = 9;
    const exponent_bits = 5;
    const exponent_bias = 15;
    const max_mantissa = (1 << mantissa_bits) - 1;
    const max_exponent = (1 << exponent_bits) - 1;

    const max_value = @as(f32, @floatFromInt(max_mantissa)) *
        std.math.ldexp(@as(f32, 1.0), max_exponent - exponent_bias - mantissa_bits);

    if (std.math.isNan(value) or value <= 0.0)
        return 0.0;

    if (std.math.isInf(value) or value >= max_value)
        return max_value;

    return value;
}

fn encodeE5B9G9R9Mantissa(value: f32, scale: f32) u32 {
    const max_mantissa = 0x1FF;
    return @min(@as(u32, @intFromFloat(@round(value / scale))), max_mantissa);
}

fn encodeE5B9G9R9(color: F32x4) u32 {
    const mantissa_bits = 9;
    const exponent_bits = 5;
    const exponent_bias = 15;
    const max_mantissa = (1 << mantissa_bits) - 1;
    const max_exponent = (1 << exponent_bits) - 1;

    const r = clampE5B9G9R9Component(color[0]);
    const g = clampE5B9G9R9Component(color[1]);
    const b = clampE5B9G9R9Component(color[2]);

    const max_component = @max(r, @max(g, b));
    if (max_component == 0.0)
        return 0;

    const parts = std.math.frexp(max_component);
    var exponent_i = std.math.clamp(parts.exponent + exponent_bias, 0, max_exponent);
    var exponent: u32 = @intCast(exponent_i);

    var scale = std.math.ldexp(@as(f32, 1.0), exponent_i - exponent_bias - mantissa_bits);

    const rounded_max: u32 = @intFromFloat(@round(max_component / scale));
    if (rounded_max > max_mantissa and exponent < max_exponent) {
        exponent += 1;
        exponent_i += 1;
        scale *= 2.0;
    }

    const r_mantissa = encodeE5B9G9R9Mantissa(r, scale);
    const g_mantissa = encodeE5B9G9R9Mantissa(g, scale);
    const b_mantissa = encodeE5B9G9R9Mantissa(b, scale);

    return (r_mantissa << 0) |
        (g_mantissa << 9) |
        (b_mantissa << 18) |
        (exponent << 27);
}
