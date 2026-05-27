const std = @import("std");
const base = @import("base");

const clip = @import("clip.zig");

const bresenham = @import("rasterizer/bresenham.zig");
const edge_function = @import("rasterizer/edge_function.zig");
const common = @import("rasterizer/common.zig");

const Renderer = @import("Renderer.zig");
const Vertex = Renderer.Vertex;
const DrawCall = Renderer.DrawCall;
const SoftImage = @import("../SoftImage.zig");

const VkError = base.VkError;

pub fn processThenFragmentStage(renderer: *Renderer, allocator: std.mem.Allocator, draw_call: *DrawCall) VkError!void {
    const io = draw_call.renderer.device.interface.io();

    const pipeline_data = (renderer.state.pipeline orelse return VkError.InvalidHandleDrv).interface.mode.graphics;
    const topology = pipeline_data.input_assembly.topology;

    const color_attachment = if (draw_call.render_pass.interface.subpasses[renderer.subpass_index].color_attachments) |attachments| attachments[0].attachment else return VkError.InvalidAttachmentDrv;
    const render_target_view: *base.ImageView = draw_call.color_attachments[color_attachment];
    const render_target: *SoftImage = @alignCast(@fieldParentPtr("interface", render_target_view.image));

    const color_range = render_target_view.subresource_range;
    const color_format = render_target_view.format;

    const color_attachment_subresource_offset = try render_target.getSubresourceOffset(
        color_range.aspect_mask,
        color_range.base_mip_level,
        color_range.base_array_layer,
    );
    const color_attachment_subresource_size = render_target.getLayerSize(color_range.aspect_mask);
    const color_attachment_access: common.RenderTargetAccess = .{
        .mutex = undefined,
        .base = try render_target.mapAsSliceWithAddedOffset(u8, color_attachment_subresource_offset, color_attachment_subresource_size),
        .row_pitch = render_target.getRowPitchMemSizeForMipLevelWithFormat(color_range.aspect_mask, color_range.base_mip_level, color_format),
        .texel_size = base.format.texelSize(color_format),
        .format = color_format,
    };

    const depth_attachment_view: ?*base.ImageView = if (draw_call.depth_attachment) |view| view else null;
    const depth_attachment: ?*SoftImage = if (depth_attachment_view) |view| @alignCast(@fieldParentPtr("interface", view.image)) else null;

    var depth_attachment_access: ?common.RenderTargetAccess = blk: {
        if (depth_attachment == null)
            break :blk null;

        const depth_range = depth_attachment_view.?.subresource_range;
        const depth_format = depth_attachment_view.?.format;

        const attachment_subresource_offset = try depth_attachment.?.getSubresourceOffset(
            depth_range.aspect_mask,
            depth_range.base_mip_level,
            depth_range.base_array_layer,
        );
        const attachment_subresource_size = depth_attachment.?.getLayerSize(depth_range.aspect_mask);
        break :blk .{
            .mutex = .init,
            .base = try depth_attachment.?.mapAsSliceWithAddedOffset(u8, attachment_subresource_offset, attachment_subresource_size),
            .row_pitch = render_target.getRowPitchMemSizeForMipLevelWithFormat(depth_range.aspect_mask, depth_range.base_mip_level, depth_format),
            .texel_size = base.format.texelSize(depth_format),
            .format = depth_format,
        };
    };

    switch (topology) {
        .triangle_list => for (0..@divTrunc(draw_call.vertices.len, 3)) |triangle_index| {
            const first_vertex = triangle_index * 3;
            const v0 = &draw_call.vertices[first_vertex + 0];
            const v1 = &draw_call.vertices[first_vertex + 1];
            const v2 = &draw_call.vertices[first_vertex + 2];

            try clipTransformAndRasterizeTriangle(
                renderer,
                allocator,
                draw_call,
                v0,
                v1,
                v2,
                &color_attachment_access,
                if (depth_attachment_access) |*access| access else null,
            );
        },
        .triangle_fan => if (draw_call.vertices.len >= 3) {
            const v0 = &draw_call.vertices[0];
            for (1..(draw_call.vertices.len - 1)) |vertex_index| {
                const v1 = &draw_call.vertices[vertex_index];
                const v2 = &draw_call.vertices[vertex_index + 1];

                try clipTransformAndRasterizeTriangle(
                    renderer,
                    allocator,
                    draw_call,
                    v0,
                    v1,
                    v2,
                    &color_attachment_access,
                    if (depth_attachment_access) |*access| access else null,
                );
            }
        },
        .triangle_strip => if (draw_call.vertices.len >= 3) {
            for (0..(draw_call.vertices.len - 2)) |vertex_index| {
                const v0 = &draw_call.vertices[vertex_index + 0];
                const v1 = &draw_call.vertices[vertex_index + 1];
                const v2 = &draw_call.vertices[vertex_index + 2];

                if ((vertex_index & 1) == 0) {
                    try clipTransformAndRasterizeTriangle(
                        renderer,
                        allocator,
                        draw_call,
                        v0,
                        v1,
                        v2,
                        &color_attachment_access,
                        if (depth_attachment_access) |*access| access else null,
                    );
                } else {
                    try clipTransformAndRasterizeTriangle(
                        renderer,
                        allocator,
                        draw_call,
                        v1,
                        v0,
                        v2,
                        &color_attachment_access,
                        if (depth_attachment_access) |*access| access else null,
                    );
                }
            }
        },
        else => base.unsupported("primitive topology {any}", .{topology}),
    }

    draw_call.rasterizer_wait_group.await(io) catch return VkError.DeviceLost;
}

fn clipTransformAndRasterizeTriangle(
    renderer: *Renderer,
    allocator: std.mem.Allocator,
    draw_call: *DrawCall,
    v0: *Vertex,
    v1: *Vertex,
    v2: *Vertex,
    color_attachment_access: *const common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
) VkError!void {
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

        try rasterizeTriangle(
            renderer,
            allocator,
            draw_call,
            &tv0,
            &tv1,
            &tv2,
            color_attachment_access,
            depth_attachment_access,
        );
    }
}

fn rasterizeTriangle(
    renderer: *Renderer,
    allocator: std.mem.Allocator,
    draw_call: *DrawCall,
    v0: *Vertex,
    v1: *Vertex,
    v2: *Vertex,
    color_attachment_access: *const common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
) VkError!void {
    if (try triangleIsCulled(renderer, v0, v1, v2))
        return;

    draw_call.stats.polygons_drawn += 1;

    const pipeline_data = (renderer.state.pipeline orelse return VkError.InvalidHandleDrv).interface.mode.graphics;
    switch (pipeline_data.rasterization.polygon_mode) {
        .fill => try edge_function.drawTriangle(
            allocator,
            draw_call,
            v0,
            v1,
            v2,
            color_attachment_access,
            depth_attachment_access,
        ),
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
