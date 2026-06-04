const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");
const zm = base.zm;

const clip = @import("clip.zig");

const bresenham = @import("rasterizer/bresenham.zig");
const edge_function = @import("rasterizer/edge_function.zig");
const common = @import("rasterizer/common.zig");
const fragment = @import("fragment.zig");

const Renderer = @import("Renderer.zig");
const Vertex = Renderer.Vertex;
const DrawCall = Renderer.DrawCall;
const SoftImage = @import("../SoftImage.zig");

const VkError = base.VkError;

pub fn processThenFragmentStage(renderer: *Renderer, allocator: std.mem.Allocator, draw_call: *DrawCall) VkError!void {
    const io = draw_call.renderer.device.interface.io();

    const pipeline_data = (renderer.state.pipeline orelse return VkError.InvalidHandleDrv).interface.mode.graphics;
    const topology = pipeline_data.input_assembly.topology;

    const color_attachments = draw_call.render_pass.interface.subpasses[renderer.subpass_index].color_attachments orelse &.{};
    const color_attachment_access = allocator.alloc(?common.RenderTargetAccess, color_attachments.len) catch return VkError.OutOfDeviceMemory;
    @memset(color_attachment_access, null);

    for (color_attachments, color_attachment_access) |attachment_ref, *access| {
        if (attachment_ref.attachment == vk.ATTACHMENT_UNUSED)
            continue;

        const render_target_view: *base.ImageView = draw_call.color_attachments[attachment_ref.attachment];
        const render_target: *SoftImage = @alignCast(@fieldParentPtr("interface", render_target_view.image));

        const color_range = render_target_view.subresource_range;
        const color_format = render_target_view.format;
        const color_extent = render_target.getMipLevelExtent(color_range.base_mip_level);

        const color_attachment_subresource_offset = try render_target.getSubresourceOffset(
            color_range.aspect_mask,
            color_range.base_mip_level,
            color_range.base_array_layer,
        );
        const color_attachment_subresource_size = render_target.getLayerSize(color_range.aspect_mask);
        access.* = .{
            .mutex = undefined,
            .base = try render_target.mapAsSliceWithAddedOffset(u8, color_attachment_subresource_offset, color_attachment_subresource_size),
            .row_pitch = render_target.getRowPitchMemSizeForMipLevelWithFormat(color_range.aspect_mask, color_range.base_mip_level, color_format),
            .texel_size = base.format.texelSize(color_format),
            .width = color_extent.width,
            .height = color_extent.height,
            .format = color_format,
        };
    }

    const depth_attachment_view: ?*base.ImageView = if (draw_call.depth_attachment) |view| view else null;
    const depth_attachment: ?*SoftImage = if (depth_attachment_view) |view| @alignCast(@fieldParentPtr("interface", view.image)) else null;

    var depth_attachment_access: ?common.RenderTargetAccess = blk: {
        if (depth_attachment == null)
            break :blk null;

        const depth_range = depth_attachment_view.?.subresource_range;
        if (!depth_range.aspect_mask.depth_bit)
            break :blk null;

        const depth_format = depth_attachment_view.?.format;
        const depth_aspect: vk.ImageAspectFlags = .{ .depth_bit = true };
        const depth_aspect_format = base.format.fromAspect(depth_format, depth_aspect);
        const depth_extent = depth_attachment.?.getMipLevelExtent(depth_range.base_mip_level);

        const attachment_subresource_offset = try depth_attachment.?.getSubresourceOffset(
            depth_aspect,
            depth_range.base_mip_level,
            depth_range.base_array_layer,
        );
        const attachment_subresource_size = depth_attachment.?.getLayerSize(depth_aspect);
        break :blk .{
            .mutex = .init,
            .base = try depth_attachment.?.mapAsSliceWithAddedOffset(u8, attachment_subresource_offset, attachment_subresource_size),
            .row_pitch = depth_attachment.?.getRowPitchMemSizeForMipLevelWithFormat(depth_aspect, depth_range.base_mip_level, depth_format),
            .texel_size = base.format.texelSize(depth_aspect_format),
            .width = depth_extent.width,
            .height = depth_extent.height,
            .format = depth_aspect_format,
        };
    };

    var stencil_attachment_access: ?common.RenderTargetAccess = blk: {
        if (depth_attachment == null)
            break :blk null;

        const stencil_range = depth_attachment_view.?.subresource_range;
        if (!stencil_range.aspect_mask.stencil_bit)
            break :blk null;

        const stencil_format = depth_attachment_view.?.format;
        const stencil_aspect: vk.ImageAspectFlags = .{ .stencil_bit = true };
        const stencil_aspect_format = base.format.fromAspect(stencil_format, stencil_aspect);
        const stencil_extent = depth_attachment.?.getMipLevelExtent(stencil_range.base_mip_level);

        const attachment_subresource_offset = try depth_attachment.?.getSubresourceOffset(
            stencil_aspect,
            stencil_range.base_mip_level,
            stencil_range.base_array_layer,
        );
        const attachment_subresource_size = depth_attachment.?.getLayerSize(stencil_aspect);
        break :blk .{
            .mutex = .init,
            .base = try depth_attachment.?.mapAsSliceWithAddedOffset(u8, attachment_subresource_offset, attachment_subresource_size),
            .row_pitch = depth_attachment.?.getRowPitchMemSizeForMipLevelWithFormat(stencil_aspect, stencil_range.base_mip_level, stencil_format),
            .texel_size = base.format.texelSize(stencil_aspect_format),
            .width = stencil_extent.width,
            .height = stencil_extent.height,
            .format = stencil_aspect_format,
        };
    };

    switch (topology) {
        .point_list => for (draw_call.vertices) |*vertex| {
            try clipTransformAndRasterizePoint(
                allocator,
                draw_call,
                vertex,
                color_attachment_access,
                if (depth_attachment_access) |*access| access else null,
                if (stencil_attachment_access) |*access| access else null,
            );
        },
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
                color_attachment_access,
                if (depth_attachment_access) |*access| access else null,
                if (stencil_attachment_access) |*access| access else null,
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
                    color_attachment_access,
                    if (depth_attachment_access) |*access| access else null,
                    if (stencil_attachment_access) |*access| access else null,
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
                        color_attachment_access,
                        if (depth_attachment_access) |*access| access else null,
                        if (stencil_attachment_access) |*access| access else null,
                    );
                } else {
                    try clipTransformAndRasterizeTriangle(
                        renderer,
                        allocator,
                        draw_call,
                        v1,
                        v0,
                        v2,
                        color_attachment_access,
                        if (depth_attachment_access) |*access| access else null,
                        if (stencil_attachment_access) |*access| access else null,
                    );
                }
            }
        },
        .line_list => for (0..@divTrunc(draw_call.vertices.len, 2)) |line_index| {
            const first_vertex = line_index * 2;
            const v0 = &draw_call.vertices[first_vertex + 0];
            const v1 = &draw_call.vertices[first_vertex + 1];

            try clipTransformAndRasterizeLine(
                allocator,
                draw_call,
                v0,
                v1,
                color_attachment_access,
                if (depth_attachment_access) |*access| access else null,
                if (stencil_attachment_access) |*access| access else null,
            );
        },
        .line_strip => if (draw_call.vertices.len >= 2) {
            for (0..(draw_call.vertices.len - 1)) |vertex_index| {
                const v0 = &draw_call.vertices[vertex_index + 0];
                const v1 = &draw_call.vertices[vertex_index + 1];

                try clipTransformAndRasterizeLine(
                    allocator,
                    draw_call,
                    v0,
                    v1,
                    color_attachment_access,
                    if (depth_attachment_access) |*access| access else null,
                    if (stencil_attachment_access) |*access| access else null,
                );
            }
        },
        else => base.unsupported("primitive topology {any}", .{topology}),
    }

    draw_call.rasterizer_wait_group.await(io) catch return VkError.DeviceLost;
}

fn clipTransformAndRasterizePoint(
    allocator: std.mem.Allocator,
    draw_call: *DrawCall,
    vertex: *Vertex,
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
) VkError!void {
    const x, const y, const z, const w = vertex.position;
    if (w == 0.0 or x < -w or x > w or y < -w or y > w or z < 0.0 or z > w)
        return;

    var transformed = vertex.*;
    clip.viewportTransformVertex(draw_call.viewport, &transformed);

    const point_size = 1.0;
    const min_x: i32 = @intFromFloat(@floor(transformed.position[0] - (point_size / 2.0)));
    const max_x: i32 = @intFromFloat(@ceil(transformed.position[0] + (point_size / 2.0)) - 1.0);
    const min_y: i32 = @intFromFloat(@floor(transformed.position[1] - (point_size / 2.0)));
    const max_y: i32 = @intFromFloat(@ceil(transformed.position[1] + (point_size / 2.0)) - 1.0);
    const pipeline = draw_call.renderer.state.pipeline orelse return;
    const has_fragment_shader = pipeline.stages.getPtr(.fragment) != null;

    var py = min_y;
    while (py <= max_y) : (py += 1) {
        var px = min_x;
        while (px <= max_x) : (px += 1) {
            if (!common.scissorContainsPixel(draw_call.scissor, px, py))
                continue;

            var outputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(zm.F32x4)]u8 = undefined;
            @memset(std.mem.asBytes(&outputs), 0);
            if (has_fragment_shader) {
                outputs = fragment.shaderInvocation(
                    allocator,
                    draw_call,
                    0,
                    zm.f32x4(@floatFromInt(px), @floatFromInt(py), transformed.position[2], 1.0),
                    try common.interpolateVertexOutputs(allocator, &transformed, &transformed, &transformed, 1.0, 0.0, 0.0),
                ) catch |err| {
                    std.log.scoped(.@"Fragment stage").err("catched a '{s}'", .{@errorName(err)});
                    if (comptime base.config.logs == .verbose) {
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpErrorReturnTrace(trace);
                        }
                    }
                    return;
                };
            }

            try common.writeToTargets(outputs, draw_call, color_attachment_access, depth_attachment_access, stencil_attachment_access, true, @intCast(px), @intCast(py), transformed.position[2]);
        }
    }
}

fn clipTransformAndRasterizeLine(
    allocator: std.mem.Allocator,
    draw_call: *DrawCall,
    v0: *Vertex,
    v1: *Vertex,
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
) VkError!void {
    const clipped_line = (try clip.clipLine(allocator, v0, v1)) orelse return;

    var tv0 = clipped_line.v0;
    var tv1 = clipped_line.v1;

    clip.viewportTransformVertex(draw_call.viewport, &tv0);
    clip.viewportTransformVertex(draw_call.viewport, &tv1);

    try bresenham.drawLine(
        allocator,
        draw_call,
        &tv0,
        &tv1,
        color_attachment_access,
        depth_attachment_access,
        stencil_attachment_access,
    );
}

fn clipTransformAndRasterizeTriangle(
    renderer: *Renderer,
    allocator: std.mem.Allocator,
    draw_call: *DrawCall,
    v0: *Vertex,
    v1: *Vertex,
    v2: *Vertex,
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
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
            stencil_attachment_access,
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
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
) VkError!void {
    const maybe_front_face = try triangleFrontFace(renderer, v0, v1, v2);
    const front_face = maybe_front_face orelse return;

    if (try triangleIsCulled(renderer, front_face))
        return;

    draw_call.stats.polygons_drawn += 1;

    const pipeline_data = (renderer.state.pipeline orelse return VkError.InvalidHandleDrv).interface.mode.graphics;
    switch (pipeline_data.rasterization.polygon_mode) {
        .fill => try edge_function.drawTriangle(allocator, draw_call, v0, v1, v2, color_attachment_access, depth_attachment_access, stencil_attachment_access, front_face),
        .line => {
            try bresenham.drawLine(allocator, draw_call, v0, v1, color_attachment_access, depth_attachment_access, stencil_attachment_access);
            try bresenham.drawLine(allocator, draw_call, v1, v2, color_attachment_access, depth_attachment_access, stencil_attachment_access);
            try bresenham.drawLine(allocator, draw_call, v2, v0, color_attachment_access, depth_attachment_access, stencil_attachment_access);
        },
        .point => {}, // TODO
        else => base.unsupported("polygon mode {any}", .{pipeline_data.rasterization.polygon_mode}),
    }
}

fn triangleIsCulled(renderer: *Renderer, front_face: bool) VkError!bool {
    const pipeline_data = (renderer.state.pipeline orelse return VkError.InvalidHandleDrv).interface.mode.graphics;
    const cull_mode = pipeline_data.rasterization.cull_mode;

    if (!cull_mode.front_bit and !cull_mode.back_bit)
        return false;

    if (cull_mode.front_bit and cull_mode.back_bit)
        return true;

    return (cull_mode.front_bit and front_face) or (cull_mode.back_bit and !front_face);
}

fn triangleFrontFace(renderer: *Renderer, v0: *const Vertex, v1: *const Vertex, v2: *const Vertex) VkError!?bool {
    const pipeline_data = (renderer.state.pipeline orelse return VkError.InvalidHandleDrv).interface.mode.graphics;
    const rasterization = pipeline_data.rasterization;
    const area = triangleArea(v0, v1, v2);
    if (area == 0.0)
        return null;

    return switch (rasterization.front_face) {
        .counter_clockwise => area < 0.0,
        .clockwise => area > 0.0,
        else => false,
    };
}

inline fn triangleArea(v0: *const Vertex, v1: *const Vertex, v2: *const Vertex) f32 {
    const x0, const y0, _, _ = v0.position;
    const x1, const y1, _, _ = v1.position;
    const x2, const y2, _, _ = v2.position;
    return ((x1 - x0) * (y2 - y0)) - ((y1 - y0) * (x2 - x0));
}
