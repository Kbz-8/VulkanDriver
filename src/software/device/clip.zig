const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;
const spv = @import("spv");

pub const F32x4 = zm.F32x4;

const Renderer = @import("Renderer.zig");
const Vertex = Renderer.Vertex;

const VkError = base.VkError;
const INTERFACE_BLOB_PADDING = @sizeOf(F32x4);

const ClipPlane = enum {
    left,
    right,
    bottom,
    top,
    near,
    far,
};

const MAX_CLIPPED_POLYGON_VERTICES = 16;

pub const ClippedLine = struct {
    v0: Vertex,
    v1: Vertex,
};

const ClippedPolygon = struct {
    vertices: [MAX_CLIPPED_POLYGON_VERTICES]Vertex = std.mem.zeroes([MAX_CLIPPED_POLYGON_VERTICES]Vertex),
    len: usize = 0,

    fn append(self: *@This(), vertex: Vertex) VkError!void {
        if (self.len >= self.vertices.len)
            return VkError.OutOfDeviceMemory;

        self.vertices[self.len] = vertex;
        self.len += 1;
    }
};

pub fn clipTriangle(allocator: std.mem.Allocator, v0: *const Vertex, v1: *const Vertex, v2: *const Vertex) VkError!ClippedPolygon {
    var polygon: ClippedPolygon = .{};
    try polygon.append(v0.*);
    try polygon.append(v1.*);
    try polygon.append(v2.*);

    const planes = [_]ClipPlane{
        .left,
        .right,
        .bottom,
        .top,
        .near,
        .far,
    };

    for (planes) |plane| {
        polygon = try clipPolygonAgainstPlane(allocator, &polygon, plane);
        if (polygon.len < 3)
            return polygon;
    }

    return polygon;
}

pub fn clipLine(allocator: std.mem.Allocator, v0: *const Vertex, v1: *const Vertex) VkError!?ClippedLine {
    var line: ClippedLine = .{
        .v0 = v0.*,
        .v1 = v1.*,
    };

    const planes = [_]ClipPlane{
        .left,
        .right,
        .bottom,
        .top,
        .near,
        .far,
    };

    for (planes) |plane| {
        const v0_distance = clipDistance(line.v0.position, plane);
        const v1_distance = clipDistance(line.v1.position, plane);
        const v0_inside = v0_distance >= 0.0;
        const v1_inside = v1_distance >= 0.0;

        if (!v0_inside and !v1_inside)
            return null;

        if (v0_inside and v1_inside)
            continue;

        const t = v0_distance / (v0_distance - v1_distance);
        const clipped_vertex = try interpolateVertexForClipping(allocator, &line.v0, &line.v1, t);

        if (v0_inside) {
            line.v1 = clipped_vertex;
        } else {
            line.v0 = clipped_vertex;
        }
    }

    return line;
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

    const subpixel_scale = 16.0;
    const x_screen = @round((((p_x / 2.0) * x_ndc) + o_x) * subpixel_scale) / subpixel_scale;
    const y_screen = @round((((p_y / 2.0) * y_ndc) + o_y) * subpixel_scale) / subpixel_scale;
    const z_screen = (p_z * z_ndc) + o_z;

    vertex.position = zm.f32x4(x_screen, y_screen, z_screen, w);
}

fn clipDistance(position: F32x4, plane: ClipPlane) f32 {
    const x, const y, const z, const w = position;
    return switch (plane) {
        .left => x + w,
        .right => w - x,
        .bottom => y + w,
        .top => w - y,
        .near => z,
        .far => w - z,
    };
}

fn isVertexInsidePlane(vertex: *const Vertex, plane: ClipPlane) bool {
    return clipDistance(vertex.position, plane) >= 0.0;
}

fn interpolateBlob(allocator: std.mem.Allocator, a: []const u8, b: []const u8, size: usize, t: f32) VkError![]u8 {
    const len = @min(size, a.len, b.len);
    const result = allocator.alloc(u8, len + INTERFACE_BLOB_PADDING) catch return VkError.OutOfDeviceMemory;
    @memset(result, 0);

    var byte_index: usize = 0;
    while (byte_index + @sizeOf(F32x4) <= len) : (byte_index += @sizeOf(F32x4)) {
        const value_a = std.mem.bytesToValue(F32x4, a[byte_index..]);
        const value_b = std.mem.bytesToValue(F32x4, b[byte_index..]);
        base.utils.writePacked(F32x4, result[byte_index..], value_a + ((value_b - value_a) * zm.f32x4s(t)));
    }

    while (byte_index + @sizeOf(f32) <= len) : (byte_index += @sizeOf(f32)) {
        const value_a = std.mem.bytesToValue(f32, a[byte_index..]);
        const value_b = std.mem.bytesToValue(f32, b[byte_index..]);
        base.utils.writePacked(f32, result[byte_index..], value_a + ((value_b - value_a) * t));
    }

    if (byte_index < len)
        @memcpy(result[byte_index..len], a[byte_index..len]);

    return result;
}

fn interpolateVertexForClipping(allocator: std.mem.Allocator, a: *const Vertex, b: *const Vertex, t: f32) VkError!Vertex {
    var result: Vertex = .{
        .primitive_restart = false,
        .position = a.position + ((b.position - a.position) * zm.f32x4s(t)),
        .point_size = a.point_size + ((b.point_size - a.point_size) * t),
        .outputs = @splat(@splat(null)),
    };

    for (&result.outputs) |*location| {
        @memset(location, null);
    }

    for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
        for (0..4) |component| {
            const out_a = a.outputs[location][component] orelse continue;
            const out_b = b.outputs[location][component] orelse continue;

            result.outputs[location][component] = .{
                .interpolation_type = out_a.interpolation_type,
                .centroid = out_a.centroid,
                .blob = if (out_a.interpolation_type == .flat)
                    allocator.dupe(u8, out_a.blob) catch return VkError.OutOfDeviceMemory
                else
                    try interpolateBlob(allocator, out_a.blob, out_b.blob, @min(out_a.size, out_b.size), t),
                .size = @min(out_a.size, out_b.size),
            };
        }
    }

    return result;
}

fn clipPolygonAgainstPlane(allocator: std.mem.Allocator, input: *const ClippedPolygon, plane: ClipPlane) VkError!ClippedPolygon {
    var output: ClippedPolygon = .{};

    if (input.len == 0)
        return output;

    var previous = input.vertices[input.len - 1];
    var previous_inside = isVertexInsidePlane(&previous, plane);
    var previous_distance = clipDistance(previous.position, plane);

    for (input.vertices[0..input.len]) |current| {
        const current_inside = isVertexInsidePlane(&current, plane);
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
