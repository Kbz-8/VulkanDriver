const std = @import("std");
const base = @import("base");

const clip = @import("clip.zig");

const bresenham = @import("rasterizer/bresenham.zig");
const edge_function = @import("rasterizer/edge_function.zig");

const Renderer = @import("Renderer.zig");
const Vertex = Renderer.Vertex;
const DrawCall = Renderer.DrawCall;

const VkError = base.VkError;

pub fn processThenFragmentStage(renderer: *Renderer, allocator: std.mem.Allocator, draw_call: *DrawCall) VkError!void {
    const pipeline_data = (renderer.state.pipeline orelse return VkError.InvalidHandleDrv).interface.mode.graphics;
    const topology = pipeline_data.input_assembly.topology;

    switch (topology) {
        .triangle_list => for (0..@divTrunc(draw_call.vertices.len, 3)) |triangle_index| {
            const first_vertex = triangle_index * 3;
            const v0 = &draw_call.vertices[first_vertex + 0];
            const v1 = &draw_call.vertices[first_vertex + 1];
            const v2 = &draw_call.vertices[first_vertex + 2];

            try clipTransformAndRasterizeTriangle(renderer, allocator, draw_call, v0, v1, v2);
        },
        .triangle_fan => if (draw_call.vertices.len >= 3) {
            const v0 = &draw_call.vertices[0];
            for (1..(draw_call.vertices.len - 1)) |vertex_index| {
                const v1 = &draw_call.vertices[vertex_index];
                const v2 = &draw_call.vertices[vertex_index + 1];

                try clipTransformAndRasterizeTriangle(renderer, allocator, draw_call, v0, v1, v2);
            }
        },
        .triangle_strip => if (draw_call.vertices.len >= 3) {
            for (0..(draw_call.vertices.len - 2)) |vertex_index| {
                const v0 = &draw_call.vertices[vertex_index + 0];
                const v1 = &draw_call.vertices[vertex_index + 1];
                const v2 = &draw_call.vertices[vertex_index + 2];

                if ((vertex_index & 1) == 0) {
                    try clipTransformAndRasterizeTriangle(renderer, allocator, draw_call, v0, v1, v2);
                } else {
                    try clipTransformAndRasterizeTriangle(renderer, allocator, draw_call, v1, v0, v2);
                }
            }
        },
        else => base.unsupported("primitive topology {any}", .{topology}),
    }
}

fn clipTransformAndRasterizeTriangle(renderer: *Renderer, allocator: std.mem.Allocator, draw_call: *DrawCall, v0: *Vertex, v1: *Vertex, v2: *Vertex) VkError!void {
    const clipped_polygon = try clip.clipTriangle(allocator, v0, v1, v2);

    if (clipped_polygon.len < 3)
        return;

    for (1..(clipped_polygon.len - 1)) |vertex_index| {
        var tv0 = clipped_polygon.vertices[0];
        var tv1 = clipped_polygon.vertices[vertex_index];
        var tv2 = clipped_polygon.vertices[vertex_index + 1];

        clip.viewportTransformVertex(draw_call.viewport, &tv0);
        clip.viewportTransformVertex(draw_call.viewport, &tv1);
        clip.viewportTransformVertex(draw_call.viewport, &tv2);

        try rasterizeTriangle(renderer, allocator, draw_call, &tv0, &tv1, &tv2);
    }
}

fn rasterizeTriangle(renderer: *Renderer, allocator: std.mem.Allocator, draw_call: *DrawCall, v0: *Vertex, v1: *Vertex, v2: *Vertex) VkError!void {
    if (try triangleIsCulled(renderer, v0, v1, v2))
        return;

    draw_call.stats.polygons_drawn += 1;

    const pipeline_data = (renderer.state.pipeline orelse return VkError.InvalidHandleDrv).interface.mode.graphics;
    switch (pipeline_data.rasterization.polygon_mode) {
        .fill => try edge_function.drawTriangle(allocator, draw_call, v0, v1, v2),
        .line => {
            try bresenham.drawLine(allocator, draw_call, v0, v1);
            try bresenham.drawLine(allocator, draw_call, v1, v2);
            try bresenham.drawLine(allocator, draw_call, v2, v0);
        },
        .point => {}, // TODO
        else => base.unsupported("polygon mode {any}", .{pipeline_data.rasterization.polygon_mode}),
    }
}

fn triangleIsCulled(renderer: *Renderer, v0: *const Vertex, v1: *const Vertex, v2: *const Vertex) VkError!bool {
    const pipeline_data = (renderer.state.pipeline orelse return VkError.InvalidHandleDrv).interface.mode.graphics;
    const rasterization = pipeline_data.rasterization;
    const cull_mode = rasterization.cull_mode;

    if (!cull_mode.front_bit and !cull_mode.back_bit)
        return false;

    if (cull_mode.front_bit and cull_mode.back_bit)
        return true;

    const area = triangleArea(v0, v1, v2);
    if (area == 0.0)
        return true;

    const front_face = switch (rasterization.front_face) {
        .counter_clockwise => area < 0.0,
        .clockwise => area > 0.0,
        else => return false,
    };

    return (cull_mode.front_bit and front_face) or (cull_mode.back_bit and !front_face);
}

inline fn triangleArea(v0: *const Vertex, v1: *const Vertex, v2: *const Vertex) f32 {
    const x0, const y0, _, _ = v0.position;
    const x1, const y1, _, _ = v1.position;
    const x2, const y2, _, _ = v2.position;
    return ((x1 - x0) * (y2 - y0)) - ((y1 - y0) * (x2 - x0));
}
