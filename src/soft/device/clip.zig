const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;
const lib = @import("../lib.zig");
const spv = @import("spv");

pub const F32x4 = zm.F32x4;

const Renderer = @import("Renderer.zig");
const Vertex = Renderer.Vertex;

const VkError = base.VkError;

const ClipPlane = enum {
    Left,
    Right,
    Bottom,
    Top,
    Near,
    Far,
};

const MAX_CLIPPED_POLYGON_VERTICES = 16;

const ClippedPolygon = struct {
    vertices: [MAX_CLIPPED_POLYGON_VERTICES]Vertex = undefined,
    len: usize = 0,

    fn append(self: *@This(), vertex: Vertex) VkError!void {
        if (self.len >= self.vertices.len)
            return VkError.OutOfDeviceMemory;

        self.vertices[self.len] = vertex;
        self.len += 1;
    }
};

fn clipDistance(position: F32x4, plane: ClipPlane) f32 {
    const x = position[0];
    const y = position[1];
    const z = position[2];
    const w = position[3];

    return switch (plane) {
        .Left => x + w,
        .Right => w - x,
        .Bottom => y + w,
        .Top => w - y,
        .Near => z,
        .Far => w - z,
    };
}

fn vertexInsidePlane(vertex: *const Vertex, plane: ClipPlane) bool {
    return clipDistance(vertex.position, plane) >= 0.0;
}

fn copyBlob(allocator: std.mem.Allocator, blob: []const u8) VkError![]u8 {
    const result = allocator.alloc(u8, blob.len) catch return VkError.OutOfDeviceMemory;
    @memcpy(result, blob);
    return result;
}

fn writePacked(comptime T: type, bytes: []u8, value: T) void {
    const raw: [@sizeOf(T)]u8 = @bitCast(value);
    @memcpy(bytes[0..@sizeOf(T)], raw[0..]);
}

fn interpolateBlob(allocator: std.mem.Allocator, a: []const u8, b: []const u8, t: f32) VkError![]u8 {
    const len = @min(a.len, b.len);
    const result = allocator.alloc(u8, len) catch return VkError.OutOfDeviceMemory;

    var byte_index: usize = 0;
    while (byte_index + @sizeOf(F32x4) <= len) : (byte_index += @sizeOf(F32x4)) {
        const value_a = std.mem.bytesToValue(F32x4, a[byte_index..]);
        const value_b = std.mem.bytesToValue(F32x4, b[byte_index..]);
        writePacked(F32x4, result[byte_index..], value_a + ((value_b - value_a) * @as(F32x4, @splat(t))));
    }

    while (byte_index + @sizeOf(f32) <= len) : (byte_index += @sizeOf(f32)) {
        const value_a = std.mem.bytesToValue(f32, a[byte_index..]);
        const value_b = std.mem.bytesToValue(f32, b[byte_index..]);
        writePacked(f32, result[byte_index..], value_a + ((value_b - value_a) * t));
    }

    if (byte_index < len)
        @memcpy(result[byte_index..], a[byte_index..len]);

    return result;
}

fn interpolateVertexForClipping(allocator: std.mem.Allocator, a: *const Vertex, b: *const Vertex, t: f32) VkError!Vertex {
    var result: Vertex = .{
        .position = a.position + ((b.position - a.position) * @as(F32x4, @splat(t))),
        .outputs = undefined,
    };

    @memset(result.outputs[0..], null);

    for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
        const out_a = a.outputs[location] orelse continue;
        const out_b = b.outputs[location] orelse continue;

        result.outputs[location] = .{
            .interpolation_type = out_a.interpolation_type,
            .blob = if (out_a.interpolation_type == .flat)
                try copyBlob(allocator, out_a.blob)
            else
                try interpolateBlob(allocator, out_a.blob, out_b.blob, t),
        };
    }

    return result;
}

fn clipPolygonAgainstPlane(allocator: std.mem.Allocator, input: *const ClippedPolygon, plane: ClipPlane) VkError!ClippedPolygon {
    var output: ClippedPolygon = .{};

    if (input.len == 0)
        return output;

    var previous = input.vertices[input.len - 1];
    var previous_inside = vertexInsidePlane(&previous, plane);
    var previous_distance = clipDistance(previous.position, plane);

    for (input.vertices[0..input.len]) |current| {
        const current_inside = vertexInsidePlane(&current, plane);
        const current_distance = clipDistance(current.position, plane);

        if (current_inside != previous_inside) {
            const t = previous_distance / (previous_distance - current_distance);
            try output.append(try interpolateVertexForClipping(allocator, &previous, &current, t));
        }

        if (current_inside)
            try output.append(current);

        previous = current;
        previous_inside = current_inside;
        previous_distance = current_distance;
    }

    return output;
}

pub fn clipTriangle(allocator: std.mem.Allocator, v0: *const Vertex, v1: *const Vertex, v2: *const Vertex) VkError!ClippedPolygon {
    var polygon: ClippedPolygon = .{};
    try polygon.append(v0.*);
    try polygon.append(v1.*);
    try polygon.append(v2.*);

    const planes = [_]ClipPlane{
        .Left,
        .Right,
        .Bottom,
        .Top,
        .Near,
        .Far,
    };

    for (planes) |plane| {
        polygon = try clipPolygonAgainstPlane(allocator, &polygon, plane);
        if (polygon.len < 3)
            return polygon;
    }

    return polygon;
}

pub fn viewportTransformVertex(viewport: vk.Viewport, vertex: *Vertex) void {
    const x, const y, const z, const w = vertex.position;

    const x_ndc = x / w;
    const y_ndc = y / w;
    const z_ndc = z / w;

    const p_x = viewport.width;
    const p_y = viewport.height;
    const p_z = viewport.max_depth - viewport.min_depth;

    const o_x = viewport.x + viewport.width / 2.0;
    const o_y = viewport.y + viewport.height / 2.0;
    const o_z = viewport.min_depth;

    const x_screen = ((p_x / 2.0) * x_ndc) + o_x;
    const y_screen = ((p_y / 2.0) * y_ndc) + o_y;
    const z_screen = (p_z * z_ndc) + o_z;

    vertex.position = zm.f32x4(x_screen, y_screen, z_screen, w);
}
