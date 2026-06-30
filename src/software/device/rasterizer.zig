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
const SoftPipeline = @import("../SoftPipeline.zig");

const VkError = base.VkError;
const SpvRuntimeError = spv.Runtime.RuntimeError;

fn renderTargetSubresourceSize(image: *const SoftImage, image_view: *const base.ImageView, aspect_mask: vk.ImageAspectFlags, mip_level: u32) usize {
    if (image.interface.image_type == .@"3d" and image.interface.flags.@"2d_array_compatible_bit" and
        (image_view.view_type == .@"2d" or image_view.view_type == .@"2d_array"))
    {
        return image.interface.getSliceMemSizeForMipLevel(aspect_mask, mip_level) *
            image.interface.samples.toInt() *
            image_view.layerCount();
    }

    return image.getMultiSampledLevelSize(aspect_mask, mip_level);
}

fn snapshotInputAttachments(allocator: std.mem.Allocator, draw_call: *DrawCall) VkError![]SoftPipeline.InputAttachmentSnapshot {
    const subpass = draw_call.render_pass.interface.subpasses[draw_call.renderer.subpass_index];
    const input_attachments = subpass.input_attachments orelse return &.{};

    var snapshot_count: usize = 0;
    for (input_attachments) |attachment_ref| {
        if (attachment_ref.attachment == vk.ATTACHMENT_UNUSED)
            continue;

        const image_view = draw_call.framebuffer.interface.attachments[attachment_ref.attachment];
        if (image_view.image.samples.toInt() == 1)
            continue;

        const range = image_view.subresource_range;
        if (range.aspect_mask.depth_bit and range.aspect_mask.stencil_bit)
            snapshot_count += 2
        else
            snapshot_count += 1;
    }
    if (snapshot_count == 0)
        return &.{};

    const snapshots = allocator.alloc(SoftPipeline.InputAttachmentSnapshot, snapshot_count) catch return VkError.OutOfDeviceMemory;
    var snapshot_index: usize = 0;
    errdefer {
        for (snapshots[0..snapshot_index]) |snapshot| {
            allocator.free(snapshot.data);
        }
        allocator.free(snapshots);
    }

    for (input_attachments) |attachment_ref| {
        if (attachment_ref.attachment == vk.ATTACHMENT_UNUSED)
            continue;

        const image_view: *base.ImageView = draw_call.framebuffer.interface.attachments[attachment_ref.attachment];
        const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.image));
        if (image.interface.samples.toInt() == 1)
            continue;

        const range = image_view.subresource_range;
        const aspects: []const vk.ImageAspectFlags = if (range.aspect_mask.depth_bit and range.aspect_mask.stencil_bit)
            &.{ .{ .depth_bit = true }, .{ .stencil_bit = true } }
        else
            &.{range.aspect_mask};

        for (aspects) |aspect_mask| {
            const offset = try image.getSubresourceOffset(aspect_mask, range.base_mip_level, range.base_array_layer);
            const size = renderTargetSubresourceSize(image, image_view, aspect_mask, range.base_mip_level);
            const live_data = try image.mapAsSliceWithAddedOffset(u8, offset, size);
            const data = allocator.dupe(u8, live_data) catch return VkError.OutOfDeviceMemory;

            snapshots[snapshot_index] = .{
                .image = image_view.image,
                .aspect_mask = aspect_mask,
                .mip_level = range.base_mip_level,
                .array_layer = range.base_array_layer,
                .data = data,
                .row_pitch = image.getRowPitchMemSizeForMipLevelWithFormat(aspect_mask, range.base_mip_level, image_view.format),
                .slice_pitch = image.getSliceMemSizeForMipLevelWithFormat(aspect_mask, range.base_mip_level, image_view.format),
                .sample_stride = image.getMipLevelSize(aspect_mask, range.base_mip_level),
            };
            snapshot_index += 1;
        }
    }

    return snapshots;
}

pub fn processThenFragmentStage(renderer: *Renderer, allocator: std.mem.Allocator, draw_call: *DrawCall) VkError!void {
    const io = draw_call.renderer.device.interface.io();

    const pipeline_data = (renderer.state.pipeline orelse return VkError.InvalidHandleDrv).interface.mode.graphics;
    const topology = pipeline_data.input_assembly.topology;
    if (renderer.input_attachment_snapshots.len == 0) {
        renderer.input_attachment_snapshots = try snapshotInputAttachments(renderer.device.device_allocator.allocator(), draw_call);
    }
    draw_call.input_attachment_snapshots = renderer.input_attachment_snapshots;

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
        const color_attachment_subresource_size = renderTargetSubresourceSize(render_target, render_target_view, color_range.aspect_mask, color_range.base_mip_level);
        access.* = .{
            .mutex = undefined,
            .base = try render_target.mapAsSliceWithAddedOffset(u8, color_attachment_subresource_offset, color_attachment_subresource_size),
            .row_pitch = render_target.getRowPitchMemSizeForMipLevelWithFormat(color_range.aspect_mask, color_range.base_mip_level, color_format),
            .texel_size = base.format.texelSize(color_format),
            .sample_count = render_target.interface.samples.toInt(),
            .sample_stride = render_target.getMipLevelSize(color_range.aspect_mask, color_range.base_mip_level),
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
        const attachment_subresource_size = renderTargetSubresourceSize(depth_attachment.?, depth_attachment_view.?, depth_aspect, depth_range.base_mip_level);
        break :blk .{
            .mutex = .init,
            .base = try depth_attachment.?.mapAsSliceWithAddedOffset(u8, attachment_subresource_offset, attachment_subresource_size),
            .row_pitch = depth_attachment.?.getRowPitchMemSizeForMipLevelWithFormat(depth_aspect, depth_range.base_mip_level, depth_format),
            .texel_size = base.format.texelSize(depth_aspect_format),
            .sample_count = depth_attachment.?.interface.samples.toInt(),
            .sample_stride = depth_attachment.?.getMipLevelSize(depth_aspect, depth_range.base_mip_level),
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
        const attachment_subresource_size = renderTargetSubresourceSize(depth_attachment.?, depth_attachment_view.?, stencil_aspect, stencil_range.base_mip_level);
        break :blk .{
            .mutex = .init,
            .base = try depth_attachment.?.mapAsSliceWithAddedOffset(u8, attachment_subresource_offset, attachment_subresource_size),
            .row_pitch = depth_attachment.?.getRowPitchMemSizeForMipLevelWithFormat(stencil_aspect, stencil_range.base_mip_level, stencil_format),
            .texel_size = base.format.texelSize(stencil_aspect_format),
            .sample_count = depth_attachment.?.interface.samples.toInt(),
            .sample_stride = depth_attachment.?.getMipLevelSize(stencil_aspect, stencil_range.base_mip_level),
            .width = stencil_extent.width,
            .height = stencil_extent.height,
            .format = stencil_aspect_format,
        };
    };

    switch (topology) {
        .point_list => for (0..draw_call.instance_count) |instance_index| {
            const range = instanceVertexRange(draw_call, instance_index);
            for (draw_call.vertices[range.start..range.end]) |*vertex| {
                if (vertex.primitive_restart)
                    continue;

                try clipTransformAndRasterizePoint(
                    allocator,
                    draw_call,
                    vertex,
                    color_attachment_access,
                    if (depth_attachment_access) |*access| access else null,
                    if (stencil_attachment_access) |*access| access else null,
                );
            }
        },
        .triangle_list => for (0..draw_call.instance_count) |instance_index| {
            const range = instanceVertexRange(draw_call, instance_index);
            const vertex_count = range.end - range.start;
            for (0..@divTrunc(vertex_count, 3)) |triangle_index| {
                const first_vertex = range.start + triangle_index * 3;
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
                    v0,
                    color_attachment_access,
                    if (depth_attachment_access) |*access| access else null,
                    if (stencil_attachment_access) |*access| access else null,
                );
            }
        },
        .triangle_fan => {
            for (0..draw_call.instance_count) |instance_index| {
                const range = instanceVertexRange(draw_call, instance_index);
                var segment_start = firstNonRestart(draw_call, range.start, range.end);
                while (segment_start < range.end) {
                    const segment_end = nextRestart(draw_call, segment_start, range.end);
                    if (segment_end - segment_start >= 3) {
                        const v0 = &draw_call.vertices[segment_start];
                        for ((segment_start + 1)..(segment_end - 1)) |vertex_index| {
                            const v1 = &draw_call.vertices[vertex_index];
                            const v2 = &draw_call.vertices[vertex_index + 1];

                            try clipTransformAndRasterizeTriangle(
                                renderer,
                                allocator,
                                draw_call,
                                v0,
                                v1,
                                v2,
                                v1,
                                color_attachment_access,
                                if (depth_attachment_access) |*access| access else null,
                                if (stencil_attachment_access) |*access| access else null,
                            );
                        }
                    }
                    segment_start = firstNonRestart(draw_call, segment_end + 1, range.end);
                }
            }
        },
        .triangle_strip => {
            for (0..draw_call.instance_count) |instance_index| {
                const range = instanceVertexRange(draw_call, instance_index);
                var segment_start = firstNonRestart(draw_call, range.start, range.end);
                while (segment_start < range.end) {
                    const segment_end = nextRestart(draw_call, segment_start, range.end);
                    if (segment_end - segment_start >= 3) {
                        for (segment_start..(segment_end - 2)) |vertex_index| {
                            const local_index = vertex_index - segment_start;
                            const v0 = &draw_call.vertices[vertex_index + 0];
                            const v1 = &draw_call.vertices[vertex_index + 1];
                            const v2 = &draw_call.vertices[vertex_index + 2];

                            if ((local_index & 1) == 0) {
                                try clipTransformAndRasterizeTriangle(
                                    renderer,
                                    allocator,
                                    draw_call,
                                    v0,
                                    v1,
                                    v2,
                                    v0,
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
                                    v0,
                                    color_attachment_access,
                                    if (depth_attachment_access) |*access| access else null,
                                    if (stencil_attachment_access) |*access| access else null,
                                );
                            }
                        }
                    }
                    segment_start = firstNonRestart(draw_call, segment_end + 1, range.end);
                }
            }
        },
        .line_list => for (0..draw_call.instance_count) |instance_index| {
            const range = instanceVertexRange(draw_call, instance_index);
            const vertex_count = range.end - range.start;
            for (0..@divTrunc(vertex_count, 2)) |line_index| {
                const first_vertex = range.start + line_index * 2;
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
                    false,
                );
            }
        },
        .line_strip => {
            for (0..draw_call.instance_count) |instance_index| {
                const range = instanceVertexRange(draw_call, instance_index);
                var segment_start = firstNonRestart(draw_call, range.start, range.end);
                while (segment_start < range.end) {
                    const segment_end = nextRestart(draw_call, segment_start, range.end);
                    if (segment_end - segment_start >= 2) {
                        for (segment_start..(segment_end - 1)) |vertex_index| {
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
                                true,
                            );
                        }
                    }
                    segment_start = firstNonRestart(draw_call, segment_end + 1, range.end);
                }
            }
        },
        else => base.unsupported("primitive topology {any}", .{topology}),
    }

    draw_call.rasterizer_wait_group.await(io) catch return VkError.DeviceLost;
}

const VertexRange = struct {
    start: usize,
    end: usize,
};

fn instanceVertexRange(draw_call: *const DrawCall, instance_index: usize) VertexRange {
    const start = instance_index * draw_call.vertex_count;
    return .{
        .start = start,
        .end = @min(start + draw_call.vertex_count, draw_call.vertices.len),
    };
}

fn firstNonRestart(draw_call: *const DrawCall, start: usize, end: usize) usize {
    var index = start;
    while (index < end and draw_call.vertices[index].primitive_restart) : (index += 1) {}
    return index;
}

fn nextRestart(draw_call: *const DrawCall, start: usize, end: usize) usize {
    var index = start;
    while (index < end and !draw_call.vertices[index].primitive_restart) : (index += 1) {}
    return index;
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

    try rasterizeTransformedPoint(
        allocator,
        draw_call,
        &transformed,
        color_attachment_access,
        depth_attachment_access,
        stencil_attachment_access,
    );
}

fn rasterizeTransformedPoint(
    allocator: std.mem.Allocator,
    draw_call: *DrawCall,
    vertex: *Vertex,
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
) VkError!void {
    const point_size = vertex.point_size;
    const min_x: i32 = @intFromFloat(@ceil(vertex.position[0] - (point_size / 2.0) - 0.5));
    const max_x: i32 = @intFromFloat(@ceil(vertex.position[0] + (point_size / 2.0) - 0.5) - 1.0);
    const min_y: i32 = @intFromFloat(@ceil(vertex.position[1] - (point_size / 2.0) - 0.5));
    const max_y: i32 = @intFromFloat(@ceil(vertex.position[1] + (point_size / 2.0) - 0.5) - 1.0);
    const point_min_x = vertex.position[0] - (point_size / 2.0);
    const point_min_y = vertex.position[1] - (point_size / 2.0);
    const pipeline = draw_call.renderer.state.pipeline orelse return;
    const has_fragment_shader = pipeline.stages.getPtr(.fragment) != null;

    var py = min_y;
    while (py <= max_y) : (py += 1) {
        var px = min_x;
        while (px <= max_x) : (px += 1) {
            if (!common.scissorContainsPixel(draw_call.scissor, px, py))
                continue;

            var fragment_result: fragment.InvocationResult = .{
                .outputs = std.mem.zeroes([spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(zm.F32x4)]u8),
                .depth = null,
                .sample_mask = null,
            };
            if (has_fragment_shader) {
                const frag_x = @as(f32, @floatFromInt(px)) + 0.5;
                const frag_y = @as(f32, @floatFromInt(py)) + 0.5;
                const point_coord = @Vector(2, f32){
                    (frag_x - point_min_x) / point_size,
                    (frag_y - point_min_y) / point_size,
                };

                fragment_result = fragment.shaderInvocation(
                    allocator,
                    draw_call,
                    0,
                    zm.f32x4(frag_x, frag_y, vertex.position[2], 1.0 / vertex.position[3]),
                    point_coord,
                    null,
                    true,
                    try common.interpolateVertexOutputs(allocator, vertex, vertex, vertex, vertex, 1.0, 0.0, 0.0),
                    null,
                ) catch |err| {
                    if (err == SpvRuntimeError.Killed)
                        continue;

                    std.log.scoped(.@"Fragment stage").err("catched a '{s}'", .{@errorName(err)});
                    if (comptime base.config.logs == .verbose) {
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpErrorReturnTrace(trace);
                        }
                    }
                    return;
                };
            }

            try common.writeToTargets(
                fragment_result.outputs,
                draw_call,
                color_attachment_access,
                depth_attachment_access,
                stencil_attachment_access,
                true,
                @intCast(px),
                @intCast(py),
                fragment_result.depth orelse vertex.position[2],
                null,
                fragment_result.sample_mask,
                false,
            );
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
    include_last_endpoint: bool,
) VkError!void {
    const clipped_line = (try clip.clipLine(allocator, v0, v1)) orelse return;

    var tv0 = clipped_line.v0;
    var tv1 = clipped_line.v1;

    clip.viewportTransformVertex(draw_call.viewport, &tv0);
    clip.viewportTransformVertex(draw_call.viewport, &tv1);

    if (include_last_endpoint) {
        try bresenham.drawLineIncludingEndpoint(
            allocator,
            draw_call,
            &tv0,
            &tv1,
            color_attachment_access,
            depth_attachment_access,
            stencil_attachment_access,
        );
    } else {
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
}

fn clipTransformAndRasterizeTriangle(
    renderer: *Renderer,
    allocator: std.mem.Allocator,
    draw_call: *DrawCall,
    v0: *Vertex,
    v1: *Vertex,
    v2: *Vertex,
    provoking_vertex: *Vertex,
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
            provoking_vertex,
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
    provoking_vertex: *Vertex,
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
        .fill => try edge_function.drawTriangle(allocator, draw_call, v0, v1, v2, provoking_vertex, color_attachment_access, depth_attachment_access, stencil_attachment_access, front_face),
        .line => {
            try bresenham.drawLine(allocator, draw_call, v0, v1, color_attachment_access, depth_attachment_access, stencil_attachment_access);
            try bresenham.drawLine(allocator, draw_call, v1, v2, color_attachment_access, depth_attachment_access, stencil_attachment_access);
            try bresenham.drawLine(allocator, draw_call, v2, v0, color_attachment_access, depth_attachment_access, stencil_attachment_access);
        },
        .point => {
            try rasterizeTransformedPoint(allocator, draw_call, v0, color_attachment_access, depth_attachment_access, stencil_attachment_access);
            try rasterizeTransformedPoint(allocator, draw_call, v1, color_attachment_access, depth_attachment_access, stencil_attachment_access);
            try rasterizeTransformedPoint(allocator, draw_call, v2, color_attachment_access, depth_attachment_access, stencil_attachment_access);
        },
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
