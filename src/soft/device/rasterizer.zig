const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;

const VkError = base.VkError;

const lib = @import("../lib.zig");

const Renderer = @import("Renderer.zig");
const spv = @import("spv");

pub const F32x4 = zm.F32x4;

fn writePacked(comptime T: type, bytes: []u8, value: T) void {
    const raw: [@sizeOf(T)]u8 = @bitCast(value);
    @memcpy(bytes[0..@sizeOf(T)], raw[0..]);
}

fn interpolateF32x4(value0: F32x4, value1: F32x4, value2: F32x4, b0: f32, b1: f32, b2: f32) F32x4 {
    return (value0 * @as(F32x4, @splat(b0))) + (value1 * @as(F32x4, @splat(b1))) + (value2 * @as(F32x4, @splat(b2)));
}

fn interpolateVertexOutputs(
    allocator: std.mem.Allocator,
    v0: *const Renderer.Vertex,
    v1: *const Renderer.Vertex,
    v2: *const Renderer.Vertex,
    b0: f32,
    b1: f32,
    b2: f32,
) VkError![spv.SPIRV_MAX_OUTPUT_LOCATIONS][]u8 {
    var inputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS][]u8 = undefined;

    for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
        const out0 = v0.outputs[location] orelse continue;
        const out1 = v1.outputs[location] orelse continue;
        const out2 = v2.outputs[location] orelse continue;

        if (out0.interpolation_type == .flat or out0.blob.len == 0) {
            inputs[location] = out0.blob;
            continue;
        }

        const len = @min(out0.blob.len, out1.blob.len, out2.blob.len);
        const input = allocator.alloc(u8, len) catch return VkError.OutOfDeviceMemory;

        var byte_index: usize = 0;
        while (byte_index + @sizeOf(F32x4) <= len) : (byte_index += @sizeOf(F32x4)) {
            const value0 = std.mem.bytesToValue(F32x4, out0.blob[byte_index..]);
            const value1 = std.mem.bytesToValue(F32x4, out1.blob[byte_index..]);
            const value2 = std.mem.bytesToValue(F32x4, out2.blob[byte_index..]);
            writePacked(F32x4, input[byte_index..], interpolateF32x4(value0, value1, value2, b0, b1, b2));
        }

        while (byte_index + @sizeOf(f32) <= len) : (byte_index += @sizeOf(f32)) {
            const value0 = std.mem.bytesToValue(f32, out0.blob[byte_index..]);
            const value1 = std.mem.bytesToValue(f32, out1.blob[byte_index..]);
            const value2 = std.mem.bytesToValue(f32, out2.blob[byte_index..]);
            writePacked(f32, input[byte_index..], (value0 * b0) + (value1 * b1) + (value2 * b2));
        }

        if (byte_index < len)
            @memcpy(input[byte_index..], out0.blob[byte_index..len]);

        inputs[location] = input;
    }

    return inputs;
}

fn interpolateLineOutputs(allocator: std.mem.Allocator, v0: *const Renderer.Vertex, v1: *const Renderer.Vertex, t: f32) VkError![spv.SPIRV_MAX_OUTPUT_LOCATIONS][]u8 {
    return interpolateVertexOutputs(allocator, v0, v1, v0, 1.0 - t, t, 0.0);
}

pub fn drawLineBresenham(allocator: std.mem.Allocator, fragments: *std.ArrayList(Renderer.Fragment), v0: *Renderer.Vertex, v1: *Renderer.Vertex) VkError!void {
    var x0: i32 = @intFromFloat(v0.position[0]);
    var y0: i32 = @intFromFloat(v0.position[1]);
    var x1: i32 = @intFromFloat(v1.position[0]);
    var y1: i32 = @intFromFloat(v1.position[1]);

    const steep = blk: {
        if (@abs(y1 - y0) > @abs(x1 - x0)) {
            std.mem.swap(i32, &x0, &y0);
            std.mem.swap(i32, &x1, &y1);
            break :blk true;
        }
        break :blk false;
    };

    var start_vertex = v0;
    var end_vertex = v1;
    if (x0 > x1) {
        std.mem.swap(i32, &x0, &x1);
        std.mem.swap(i32, &y0, &y1);
        std.mem.swap(*Renderer.Vertex, &start_vertex, &end_vertex);
    }

    const d_err = @abs(y1 - y0);
    const d_x = x1 - x0;
    const y_step: i32 = if (y0 > y1) -1 else 1;

    var err = @divTrunc(d_x, 2); // Pixel center.
    var y = y0;

    var x = x0;
    while (x <= x1) : (x += 1) {
        const x_fragment: f32 = @floatFromInt(if (steep) y else x);
        const y_fragment: f32 = @floatFromInt(if (steep) x else y);
        const t = @as(f32, @floatFromInt(x - x0)) / @as(f32, @floatFromInt(@max(d_x, 1)));

        const z = ((1.0 - t) * start_vertex.position[2]) + (t * end_vertex.position[2]);

        fragments.append(allocator, .{
            .position = zm.f32x4(x_fragment, y_fragment, z, 1.0),
            .color = zm.f32x4(1.0, 1.0, 1.0, 1.0),
            .inputs = try interpolateLineOutputs(allocator, start_vertex, end_vertex, t),
        }) catch return VkError.OutOfDeviceMemory;

        err -= @intCast(d_err);
        if (err < 0) {
            y += y_step;
            err += d_x;
        }
    }
}

fn edgeFunction(a: F32x4, b: F32x4, p: F32x4) f32 {
    return ((p[0] - a[0]) * (b[1] - a[1])) - ((p[1] - a[1]) * (b[0] - a[0]));
}

pub fn drawTriangleFilled(allocator: std.mem.Allocator, fragments: *std.ArrayList(Renderer.Fragment), v0: *Renderer.Vertex, v1: *Renderer.Vertex, v2: *Renderer.Vertex) VkError!void {
    const min_x: i32 = @intFromFloat(@floor(@min(v0.position[0], v1.position[0], v2.position[0])));
    const max_x: i32 = @intFromFloat(@ceil(@max(v0.position[0], v1.position[0], v2.position[0])));
    const min_y: i32 = @intFromFloat(@floor(@min(v0.position[1], v1.position[1], v2.position[1])));
    const max_y: i32 = @intFromFloat(@ceil(@max(v0.position[1], v1.position[1], v2.position[1])));

    const area = edgeFunction(v0.position, v1.position, v2.position);
    if (area == 0.0)
        return;

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const p = zm.f32x4(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, 0.0, 1.0);

            const w0 = edgeFunction(v1.position, v2.position, p);
            const w1 = edgeFunction(v2.position, v0.position, p);
            const w2 = edgeFunction(v0.position, v1.position, p);

            const inside = if (area > 0.0)
                w0 >= 0.0 and w1 >= 0.0 and w2 >= 0.0
            else
                w0 <= 0.0 and w1 <= 0.0 and w2 <= 0.0;

            if (!inside)
                continue;

            const b0 = w0 / area;
            const b1 = w1 / area;
            const b2 = w2 / area;
            const z = (b0 * v0.position[2]) + (b1 * v1.position[2]) + (b2 * v2.position[2]);

            fragments.append(allocator, .{
                .position = zm.f32x4(@floatFromInt(x), @floatFromInt(y), z, 1.0),
                .color = zm.f32x4(1.0, 1.0, 1.0, 1.0),
                .inputs = try interpolateVertexOutputs(allocator, v0, v1, v2, b0, b1, b2),
            }) catch return VkError.OutOfDeviceMemory;
        }
    }
}
