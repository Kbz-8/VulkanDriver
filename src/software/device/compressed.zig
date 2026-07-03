const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;

pub const F32x4 = zm.F32x4;

pub fn isBc1(format: vk.Format) bool {
    return switch (format) {
        .bc1_rgb_unorm_block,
        .bc1_rgb_srgb_block,
        .bc1_rgba_unorm_block,
        .bc1_rgba_srgb_block,
        => true,
        else => false,
    };
}

pub fn readFloat4(block: []const u8, format: vk.Format, x_in_block: usize, y_in_block: usize) F32x4 {
    return switch (format) {
        .bc1_rgb_unorm_block,
        .bc1_rgb_srgb_block,
        .bc1_rgba_unorm_block,
        .bc1_rgba_srgb_block,
        => readBc1(block, format, x_in_block, y_in_block),
        .bc4_unorm_block,
        .bc4_snorm_block,
        => .{ readBc4(block, format, x_in_block, y_in_block), 0.0, 0.0, 1.0 },
        .bc5_unorm_block,
        .bc5_snorm_block,
        => readBc5(block, format, x_in_block, y_in_block),
        else => blk: {
            base.unsupported("Compressed read from format {any}", .{format});
            break :blk .{ 0.0, 0.0, 0.0, 1.0 };
        },
    };
}

pub fn writeFloat4(block: []u8, format: vk.Format, x_in_block: usize, y_in_block: usize, color: F32x4) void {
    switch (format) {
        .bc1_rgb_unorm_block,
        .bc1_rgb_srgb_block,
        .bc1_rgba_unorm_block,
        .bc1_rgba_srgb_block,
        => writeBc1Texel(block, format, x_in_block, y_in_block, color),
        else => base.unsupported("Compressed write to format {any}", .{format}),
    }
}

fn readBc1(block: []const u8, format: vk.Format, x_in_block: usize, y_in_block: usize) F32x4 {
    std.debug.assert(block.len >= 8);
    std.debug.assert(x_in_block < 4);
    std.debug.assert(y_in_block < 4);

    const color_0 = std.mem.bytesToValue(u16, block[0..2]);
    const color_1 = std.mem.bytesToValue(u16, block[2..4]);
    const selectors = std.mem.bytesToValue(u32, block[4..8]);
    const selector_shift: u5 = @intCast(2 * (y_in_block * 4 + x_in_block));
    const selector = (selectors >> selector_shift) & 0x3;
    const has_alpha = format == .bc1_rgba_unorm_block or format == .bc1_rgba_srgb_block;

    var palette: [4]F32x4 = undefined;
    palette[0] = decodeRgb565(color_0);
    palette[1] = decodeRgb565(color_1);

    if (color_0 > color_1 or !has_alpha) {
        palette[2] = mix(palette[0], palette[1], 2.0 / 3.0, 1.0 / 3.0, 1.0);
        palette[3] = mix(palette[0], palette[1], 1.0 / 3.0, 2.0 / 3.0, 1.0);
    } else {
        palette[2] = mix(palette[0], palette[1], 0.5, 0.5, 1.0);
        palette[3] = .{ 0.0, 0.0, 0.0, 0.0 };
    }

    return palette[@intCast(selector)];
}

fn readBc4(block: []const u8, format: vk.Format, x_in_block: usize, y_in_block: usize) f32 {
    std.debug.assert(block.len >= 8);
    std.debug.assert(x_in_block < 4);
    std.debug.assert(y_in_block < 4);

    const selector_shift: u6 = @intCast(3 * (y_in_block * 4 + x_in_block));
    const selectors = std.mem.bytesToValue(u64, block[0..8]) >> 16;
    const selector: usize = @intCast((selectors >> selector_shift) & 0x7);

    return switch (format) {
        .bc4_unorm_block,
        .bc5_unorm_block,
        => readBc4Unorm(block, selector),
        .bc4_snorm_block,
        .bc5_snorm_block,
        => readBc4Snorm(block, selector),
        else => unreachable,
    };
}

fn readBc5(block: []const u8, format: vk.Format, x_in_block: usize, y_in_block: usize) F32x4 {
    std.debug.assert(block.len >= 16);
    return .{
        readBc4(block[0..8], format, x_in_block, y_in_block),
        readBc4(block[8..16], format, x_in_block, y_in_block),
        0.0,
        1.0,
    };
}

fn readBc4Unorm(block: []const u8, selector: usize) f32 {
    const endpoint_0 = @as(f32, @floatFromInt(block[0])) / 255.0;
    const endpoint_1 = @as(f32, @floatFromInt(block[1])) / 255.0;

    var palette: [8]f32 = undefined;
    palette[0] = endpoint_0;
    palette[1] = endpoint_1;

    if (block[0] > block[1]) {
        palette[2] = (6.0 * endpoint_0 + 1.0 * endpoint_1) / 7.0;
        palette[3] = (5.0 * endpoint_0 + 2.0 * endpoint_1) / 7.0;
        palette[4] = (4.0 * endpoint_0 + 3.0 * endpoint_1) / 7.0;
        palette[5] = (3.0 * endpoint_0 + 4.0 * endpoint_1) / 7.0;
        palette[6] = (2.0 * endpoint_0 + 5.0 * endpoint_1) / 7.0;
        palette[7] = (1.0 * endpoint_0 + 6.0 * endpoint_1) / 7.0;
    } else {
        palette[2] = (4.0 * endpoint_0 + 1.0 * endpoint_1) / 5.0;
        palette[3] = (3.0 * endpoint_0 + 2.0 * endpoint_1) / 5.0;
        palette[4] = (2.0 * endpoint_0 + 3.0 * endpoint_1) / 5.0;
        palette[5] = (1.0 * endpoint_0 + 4.0 * endpoint_1) / 5.0;
        palette[6] = 0.0;
        palette[7] = 1.0;
    }

    return palette[selector];
}

fn readBc4Snorm(block: []const u8, selector: usize) f32 {
    const raw_0: i8 = @bitCast(block[0]);
    const raw_1: i8 = @bitCast(block[1]);
    const endpoint_0 = decodeBcSnorm(raw_0);
    const endpoint_1 = decodeBcSnorm(raw_1);

    var palette: [8]f32 = undefined;
    palette[0] = endpoint_0;
    palette[1] = endpoint_1;

    if (raw_0 > raw_1) {
        palette[2] = (6.0 * endpoint_0 + 1.0 * endpoint_1) / 7.0;
        palette[3] = (5.0 * endpoint_0 + 2.0 * endpoint_1) / 7.0;
        palette[4] = (4.0 * endpoint_0 + 3.0 * endpoint_1) / 7.0;
        palette[5] = (3.0 * endpoint_0 + 4.0 * endpoint_1) / 7.0;
        palette[6] = (2.0 * endpoint_0 + 5.0 * endpoint_1) / 7.0;
        palette[7] = (1.0 * endpoint_0 + 6.0 * endpoint_1) / 7.0;
    } else {
        palette[2] = (4.0 * endpoint_0 + 1.0 * endpoint_1) / 5.0;
        palette[3] = (3.0 * endpoint_0 + 2.0 * endpoint_1) / 5.0;
        palette[4] = (2.0 * endpoint_0 + 3.0 * endpoint_1) / 5.0;
        palette[5] = (1.0 * endpoint_0 + 4.0 * endpoint_1) / 5.0;
        palette[6] = -1.0;
        palette[7] = 1.0;
    }

    return palette[selector];
}

fn decodeBcSnorm(value: i8) f32 {
    return @max(@as(f32, @floatFromInt(value)) / 127.0, -1.0);
}

fn writeBc1Texel(block: []u8, format: vk.Format, x_in_block: usize, y_in_block: usize, color: F32x4) void {
    var pixels: [16]F32x4 = undefined;
    for (&pixels, 0..) |*pixel, i| {
        pixel.* = readBc1(block, format, i & 3, i >> 2);
    }
    pixels[y_in_block * 4 + x_in_block] = color;
    encodeBc1(block, format, pixels);
}

pub fn encodeBc1(block: []u8, format: vk.Format, pixels: [16]F32x4) void {
    std.debug.assert(block.len >= 8);

    var min_color: F32x4 = .{ 1.0, 1.0, 1.0, 1.0 };
    var max_color: F32x4 = .{ 0.0, 0.0, 0.0, 1.0 };
    var has_alpha = false;

    for (pixels) |pixel| {
        if (pixel[3] < 0.5) {
            has_alpha = true;
            continue;
        }
        min_color[0] = @min(min_color[0], pixel[0]);
        min_color[1] = @min(min_color[1], pixel[1]);
        min_color[2] = @min(min_color[2], pixel[2]);
        max_color[0] = @max(max_color[0], pixel[0]);
        max_color[1] = @max(max_color[1], pixel[1]);
        max_color[2] = @max(max_color[2], pixel[2]);
    }

    var color_0 = encodeRgb565(max_color);
    var color_1 = encodeRgb565(min_color);
    const supports_alpha = format == .bc1_rgba_unorm_block or format == .bc1_rgba_srgb_block;
    if (has_alpha and supports_alpha) {
        if (color_0 > color_1)
            std.mem.swap(u16, &color_0, &color_1);
    } else if (color_0 <= color_1) {
        std.mem.swap(u16, &color_0, &color_1);
    }

    std.mem.bytesAsValue(u16, block[0..2]).* = color_0;
    std.mem.bytesAsValue(u16, block[2..4]).* = color_1;

    var selectors: u32 = 0;
    for (pixels, 0..) |pixel, i| {
        const selector = nearestSelector(pixel, color_0, color_1, supports_alpha);
        selectors |= @as(u32, selector) << @intCast(2 * i);
    }
    std.mem.bytesAsValue(u32, block[4..8]).* = selectors;
}

fn nearestSelector(color: F32x4, color_0: u16, color_1: u16, supports_alpha: bool) u2 {
    if (supports_alpha and color[3] < 0.5 and color_0 <= color_1)
        return 3;

    var palette: [4]F32x4 = undefined;
    palette[0] = decodeRgb565(color_0);
    palette[1] = decodeRgb565(color_1);
    if (color_0 > color_1 or !supports_alpha) {
        palette[2] = mix(palette[0], palette[1], 2.0 / 3.0, 1.0 / 3.0, 1.0);
        palette[3] = mix(palette[0], palette[1], 1.0 / 3.0, 2.0 / 3.0, 1.0);
    } else {
        palette[2] = mix(palette[0], palette[1], 0.5, 0.5, 1.0);
        palette[3] = .{ 0.0, 0.0, 0.0, 0.0 };
    }

    var best_selector: u2 = 0;
    var best_distance = std.math.floatMax(f32);
    for (palette, 0..) |entry, i| {
        if (i == 3 and supports_alpha and color_0 <= color_1 and color[3] >= 0.5)
            continue;
        const dr = color[0] - entry[0];
        const dg = color[1] - entry[1];
        const db = color[2] - entry[2];
        const distance = dr * dr + dg * dg + db * db;
        if (distance < best_distance) {
            best_distance = distance;
            best_selector = @intCast(i);
        }
    }
    return best_selector;
}

fn decodeRgb565(value: u16) F32x4 {
    return .{
        @as(f32, @floatFromInt((value >> 11) & 0x1f)) / 31.0,
        @as(f32, @floatFromInt((value >> 5) & 0x3f)) / 63.0,
        @as(f32, @floatFromInt(value & 0x1f)) / 31.0,
        1.0,
    };
}

fn encodeRgb565(color: F32x4) u16 {
    const clamped = std.math.clamp(color, zm.f32x4s(0.0), zm.f32x4s(1.0));
    const r: u16 = @intFromFloat(@round(clamped[0] * 31.0));
    const g: u16 = @intFromFloat(@round(clamped[1] * 63.0));
    const b: u16 = @intFromFloat(@round(clamped[2] * 31.0));
    return (r << 11) | (g << 5) | b;
}

fn mix(a: F32x4, b: F32x4, a_weight: f32, b_weight: f32, alpha: f32) F32x4 {
    return .{
        a[0] * a_weight + b[0] * b_weight,
        a[1] * a_weight + b[1] * b_weight,
        a[2] * a_weight + b[2] * b_weight,
        alpha,
    };
}
