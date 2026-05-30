const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;
const spv = @import("spv");

const blitter = @import("../blitter.zig");
const Renderer = @import("../Renderer.zig");

const VkError = base.VkError;
const F32x4 = zm.F32x4;
const U32x4 = @Vector(4, u32);

pub const RenderTargetAccess = struct {
    mutex: std.Io.Mutex,
    base: []u8,
    row_pitch: usize,
    texel_size: usize,
    format: vk.Format,
};

pub const VertexInterpolation = struct {
    blob: []const u8,
    free_responsability: bool,
};

pub fn scissorContainsPixel(scissor: vk.Rect2D, x: i32, y: i32) bool {
    const min_x: i64 = @as(i64, scissor.offset.x);
    const min_y: i64 = @as(i64, scissor.offset.y);

    const max_x: i64 = min_x + @as(i64, @intCast(scissor.extent.width));
    const max_y: i64 = min_y + @as(i64, @intCast(scissor.extent.height));

    const pixel_x: i64 = @as(i64, x);
    const pixel_y: i64 = @as(i64, y);

    return pixel_x >= min_x and
        pixel_x < max_x and
        pixel_y >= min_y and
        pixel_y < max_y;
}

pub fn interpolateVertexOutputs(
    allocator: std.mem.Allocator,
    v0: *const Renderer.Vertex,
    v1: *const Renderer.Vertex,
    v2: *const Renderer.Vertex,
    b0: f32,
    b1: f32,
    b2: f32,
) VkError![spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolation {
    var inputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolation = undefined;

    for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
        const out0 = v0.outputs[location] orelse continue;
        const out1 = v1.outputs[location] orelse continue;
        const out2 = v2.outputs[location] orelse continue;

        if (out0.interpolation_type == .flat or out0.blob.len == 0) {
            inputs[location] = .{ .blob = out0.blob, .free_responsability = false };
            continue;
        }

        const len = @min(out0.blob.len, out1.blob.len, out2.blob.len);
        const input = allocator.alloc(u8, len) catch return VkError.OutOfDeviceMemory;

        var byte_index: usize = 0;
        while (byte_index + @sizeOf(F32x4) <= len) : (byte_index += @sizeOf(F32x4)) {
            const value0 = std.mem.bytesToValue(F32x4, out0.blob[byte_index..]);
            const value1 = std.mem.bytesToValue(F32x4, out1.blob[byte_index..]);
            const value2 = std.mem.bytesToValue(F32x4, out2.blob[byte_index..]);
            base.utils.writePacked(F32x4, input[byte_index..], interpolateF32x4(value0, value1, value2, b0, b1, b2));
        }

        while (byte_index + @sizeOf(f32) <= len) : (byte_index += @sizeOf(f32)) {
            const value0 = std.mem.bytesToValue(f32, out0.blob[byte_index..]);
            const value1 = std.mem.bytesToValue(f32, out1.blob[byte_index..]);
            const value2 = std.mem.bytesToValue(f32, out2.blob[byte_index..]);
            base.utils.writePacked(f32, input[byte_index..], (value0 * b0) + (value1 * b1) + (value2 * b2));
        }

        if (byte_index < len)
            @memcpy(input[byte_index..], out0.blob[byte_index..len]);

        inputs[location] = .{ .blob = input, .free_responsability = true };
    }

    return inputs;
}

pub fn interpolateLineOutputs(
    allocator: std.mem.Allocator,
    v0: *const Renderer.Vertex,
    v1: *const Renderer.Vertex,
    t: f32,
) VkError![spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolation {
    return interpolateVertexOutputs(allocator, v0, v1, v0, 1.0 - t, t, 0.0);
}

inline fn interpolateF32x4(value0: F32x4, value1: F32x4, value2: F32x4, b0: f32, b1: f32, b2: f32) F32x4 {
    return (value0 * zm.f32x4s(b0)) + (value1 * zm.f32x4s(b1)) + (value2 * zm.f32x4s(b2));
}

pub fn writeToTargets(
    outputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(F32x4)]u8,
    draw_call: *Renderer.DrawCall,
    color_attachment_access: *const RenderTargetAccess,
    depth_attachment_access: ?*RenderTargetAccess,
    x: usize,
    y: usize,
    z: f32,
) VkError!void {
    const io = draw_call.renderer.device.interface.io();

    const color_offset = @as(usize, @intCast(x)) * color_attachment_access.texel_size + @as(usize, @intCast(y)) * color_attachment_access.row_pitch;

    // After work depth test to avoid overwritten depth pixels during fragment invocations
    if (depth_attachment_access) |depth| {
        const depth_offset = @as(usize, @intCast(x)) * depth.texel_size + @as(usize, @intCast(y)) * depth.row_pitch;

        depth.mutex.lock(io) catch return VkError.DeviceLost;
        defer depth.mutex.unlock(io);

        const depth_value = blitter.readFloat4(depth.base[depth_offset..], depth.format);
        if (z >= depth_value[0])
            return;
        blitter.writeFloat4(zm.f32x4s(z), depth.base[depth_offset..], depth.format);

        // Doubled line to stay inside the critical section
        if (base.format.isUnnormalizedInteger(color_attachment_access.format)) {
            blitter.writeInt4(std.mem.bytesToValue(U32x4, &outputs[0]), color_attachment_access.base[color_offset..], color_attachment_access.format);
        } else {
            blitter.writeFloat4(std.mem.bytesToValue(F32x4, &outputs[0]), color_attachment_access.base[color_offset..], color_attachment_access.format);
        }
    } else {
        if (base.format.isUnnormalizedInteger(color_attachment_access.format)) {
            blitter.writeInt4(std.mem.bytesToValue(U32x4, &outputs[0]), color_attachment_access.base[color_offset..], color_attachment_access.format);
        } else {
            blitter.writeFloat4(std.mem.bytesToValue(F32x4, &outputs[0]), color_attachment_access.base[color_offset..], color_attachment_access.format);
        }
    }
}
