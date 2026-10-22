const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");
const zm = base.zm;

const common = @import("common.zig");
const fragment = @import("../fragment/dispatcher.zig");
const interpreter_simd = @import("../../interpreter/simd.zig");

const Renderer = @import("../Renderer.zig");

const VkError = base.VkError;
const SpvRuntimeError = spv.Runtime.RuntimeError;
const F32x4 = zm.F32x4;

const SamplePosition = struct {
    x: f32,
    y: f32,
};

pub const FillState = struct {
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
    has_fragment_shader: bool,
    early_fragment_tests: bool,
    fragment_uses_derivatives: bool,
    fragment_uses_sample_id: bool,
    fragment_uses_centroid: bool,
    sample_count: usize,
    depth_stencil_state: ?vk.PipelineDepthStencilStateCreateInfo,
    depth_bias: ?Renderer.DepthBias,
    opaque_single_sample_output: bool,
    worker_capacity: usize,
    ordering: common.AttachmentOrdering,
};

pub const PreparedTriangle = struct {
    vertices: [3]common.RasterVertex,
    provoking_vertex: *const Renderer.Vertex,
    bounds: common.PixelBounds,
    area: f32,
    depth_bias_slope: f32,
    front_face: bool,
};

const RunData = struct {
    state: *const FillState,
    triangle: *const PreparedTriangle,
    batch_id: usize,
    bounds: common.PixelBounds,
};

pub fn initFillState(
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
    ordering: common.AttachmentOrdering,
) VkError!FillState {
    const pipeline = draw_call.renderer.state.pipeline orelse return VkError.InvalidPipelineDrv;
    const pipeline_data = pipeline.interface.mode.graphics;
    const fragment_stage = pipeline.stages.getPtr(.fragment);
    const fragment_uses_derivatives = if (comptime base.config.soft_ir_interpreter)
        (if (fragment_stage) |stage| stage.program.uses_derivatives else false)
    else if (fragment_stage) |stage|
        stage.module.module.reflection_infos.needs_derivatives
    else
        false;
    const early_fragment_tests = if (fragment_stage) |stage|
        if (comptime base.config.soft_ir_interpreter) stage.early_fragment_tests else stage.module.module.reflection_infos.early_fragment_tests
    else
        false;
    const fragment_uses_sample_id = if (comptime base.config.soft_ir_interpreter)
        false
    else if (fragment_stage) |stage|
        stage.module.module.builtins.get(.SampleId) != null
    else
        false;
    const fragment_uses_centroid = if (comptime base.config.soft_ir_interpreter)
        false
    else if (fragment_stage) |stage|
        fragmentStageUsesInputDecoration(stage, .Centroid)
    else
        false;

    var worker_capacity = if (fragment_stage) |stage|
        if (comptime base.config.soft_ir_interpreter) stage.workerCount() else stage.runtimes.len
    else if (pipeline.stages.getPtr(.vertex)) |stage|
        if (comptime base.config.soft_ir_interpreter) stage.workerCount() else stage.runtimes.len
    else
        1;
    if (comptime base.config.soft_ir_interpreter) {
        if (fragment_stage) |stage| {
            if (stage.program.uses_atomics)
                worker_capacity = @min(worker_capacity, 1);
        }
    }
    if (worker_capacity == 0)
        return VkError.InvalidPipelineDrv;

    const depth_stencil_state = if (pipeline_data.depth_stencil) |state| common.resolveDepthStencilState(draw_call, state) else null;
    const depth_bias: ?Renderer.DepthBias = if (pipeline_data.rasterization.depth_bias_enable == .true and depth_attachment_access != null)
        if (pipeline_data.dynamic_state.depth_bias)
            draw_call.renderer.dynamic_state.depth_bias orelse Renderer.DepthBias{
                .constant_factor = 0.0,
                .clamp = 0.0,
                .slope_factor = 0.0,
            }
        else
            Renderer.DepthBias{
                .constant_factor = pipeline_data.rasterization.depth_bias_constant_factor,
                .clamp = pipeline_data.rasterization.depth_bias_clamp,
                .slope_factor = pipeline_data.rasterization.depth_bias_slope_factor,
            }
    else
        null;

    return .{
        .allocator = allocator,
        .draw_call = draw_call,
        .color_attachment_access = color_attachment_access,
        .depth_attachment_access = depth_attachment_access,
        .stencil_attachment_access = stencil_attachment_access,
        .has_fragment_shader = fragment_stage != null,
        .early_fragment_tests = early_fragment_tests,
        .fragment_uses_derivatives = fragment_uses_derivatives,
        .fragment_uses_sample_id = fragment_uses_sample_id,
        .fragment_uses_centroid = fragment_uses_centroid,
        .sample_count = pipeline_data.multisample.rasterization_samples.toInt(),
        .depth_stencil_state = depth_stencil_state,
        .depth_bias = depth_bias,
        .opaque_single_sample_output = common.canUseOpaqueSingleSampleOutput(
            draw_call,
            color_attachment_access,
            depth_stencil_state,
            stencil_attachment_access,
        ),
        .worker_capacity = worker_capacity,
        .ordering = ordering,
    };
}

pub fn prepareTriangle(
    state: *const FillState,
    vertices: [3]common.RasterVertex,
    provoking_vertex: *const Renderer.Vertex,
    front_face: bool,
) ?PreparedTriangle {
    const p0 = vertices[0].position;
    const p1 = vertices[1].position;
    const p2 = vertices[2].position;
    const area = edgeFunction(p0, p1, p2);
    if (area == 0.0)
        return null;

    var bounds: common.PixelBounds = .{
        .min_x = @intFromFloat(@floor(@min(p0[0], p1[0], p2[0]))),
        .max_x = @intFromFloat(@ceil(@max(p0[0], p1[0], p2[0]))),
        .min_y = @intFromFloat(@floor(@min(p0[1], p1[1], p2[1]))),
        .max_y = @intFromFloat(@ceil(@max(p0[1], p1[1], p2[1]))),
    };
    bounds = intersectRect(bounds, state.draw_call.scissor) orelse return null;
    if (state.draw_call.renderer.render_area) |render_area|
        bounds = intersectRect(bounds, render_area) orelse return null;
    bounds = common.PixelBounds.intersect(bounds, .{
        .min_x = 0,
        .max_x = clampUsizeToI32(state.draw_call.framebuffer.interface.width) - 1,
        .min_y = 0,
        .max_y = clampUsizeToI32(state.draw_call.framebuffer.interface.height) - 1,
    }) orelse return null;

    const inv_area = 1.0 / area;
    const dz_dx =
        (p0[2] * ((p1[1] - p2[1]) * inv_area)) +
        (p1[2] * ((p2[1] - p0[1]) * inv_area)) +
        (p2[2] * ((p0[1] - p1[1]) * inv_area));
    const dz_dy =
        (p0[2] * ((p2[0] - p1[0]) * inv_area)) +
        (p1[2] * ((p0[0] - p2[0]) * inv_area)) +
        (p2[2] * ((p1[0] - p0[0]) * inv_area));

    return .{
        .vertices = vertices,
        .provoking_vertex = provoking_vertex,
        .bounds = bounds,
        .area = area,
        .depth_bias_slope = @max(@abs(dz_dx), @abs(dz_dy)),
        .front_face = front_face,
    };
}

pub fn drawTriangle(
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    v0: *Renderer.Vertex,
    v1: *Renderer.Vertex,
    v2: *Renderer.Vertex,
    provoking_vertex: *Renderer.Vertex,
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
    front_face: bool,
) VkError!void {
    var state = try initFillState(
        allocator,
        draw_call,
        color_attachment_access,
        depth_attachment_access,
        stencil_attachment_access,
        .locked,
    );
    var triangle = prepareTriangle(&state, .{
        .{ .position = v0.position, .attributes = v0 },
        .{ .position = v1.position, .attributes = v1 },
        .{ .position = v2.position, .attributes = v2 },
    }, provoking_vertex, front_face) orelse return;

    const io = draw_call.renderer.device.interface.io();
    const grid_size: usize = @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(state.worker_capacity)))));
    const width: usize = @intCast(triangle.bounds.max_x - triangle.bounds.min_x + 1);
    const height: usize = @intCast(triangle.bounds.max_y - triangle.bounds.min_y + 1);
    const cols_per_run = @divTrunc(width + grid_size - 1, grid_size);
    const rows_per_run = @divTrunc(height + grid_size - 1, grid_size);
    var batch_id: usize = 0;

    for (0..grid_size) |gy| {
        for (0..grid_size) |gx| {
            defer batch_id = @mod(batch_id + 1, state.worker_capacity);
            const min_x = triangle.bounds.min_x + @as(i32, @intCast(gx * cols_per_run));
            const min_y = triangle.bounds.min_y + @as(i32, @intCast(gy * rows_per_run));
            if (min_x > triangle.bounds.max_x or min_y > triangle.bounds.max_y)
                continue;
            const data: RunData = .{
                .state = &state,
                .triangle = &triangle,
                .batch_id = batch_id,
                .bounds = .{
                    .min_x = min_x,
                    .max_x = @min(min_x + @as(i32, @intCast(cols_per_run)) - 1, triangle.bounds.max_x),
                    .min_y = min_y,
                    .max_y = @min(min_y + @as(i32, @intCast(rows_per_run)) - 1, triangle.bounds.max_y),
                },
            };
            draw_call.rasterizer_wait_group.async(io, runWrapper, .{data});
        }
    }
    draw_call.rasterizer_wait_group.await(io) catch return VkError.DeviceLost;
}

pub fn rasterizeTriangleInRect(
    state: *const FillState,
    optional_worker: ?*fragment.Worker,
    triangle: *const PreparedTriangle,
    rect: common.PixelBounds,
) VkError!void {
    const bounds = common.PixelBounds.intersect(triangle.bounds, rect) orelse return;
    if (comptime base.config.soft_ir_interpreter) {
        if (state.has_fragment_shader and state.sample_count == 1) {
            const worker = optional_worker orelse return VkError.InvalidPipelineDrv;
            if (state.fragment_uses_derivatives)
                return rasterizeTriangleInRectQuads(state, worker, triangle, bounds);
            return rasterizeTriangleInRectWave(state, worker, triangle, bounds);
        }
    }

    const v0 = triangle.vertices[0];
    const v1 = triangle.vertices[1];
    const v2 = triangle.vertices[2];

    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        var x = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            const p = zm.f32x4(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, 0.0, 1.0);
            const w0 = edgeFunction(v1.position, v2.position, p);
            const w1 = edgeFunction(v2.position, v0.position, p);
            const w2 = edgeFunction(v0.position, v1.position, p);
            const coverage_sample_mask = if (state.sample_count == 1) blk: {
                const inside =
                    edgeContainsPixel(v1.position, v2.position, w0, triangle.area) and
                    edgeContainsPixel(v2.position, v0.position, w1, triangle.area) and
                    edgeContainsPixel(v0.position, v1.position, w2, triangle.area);
                break :blk if (inside) @as(vk.SampleMask, 1) else @as(vk.SampleMask, 0);
            } else triangleCoverageMask(triangle, x, y, state.sample_count);
            if (coverage_sample_mask == 0)
                continue;

            const b0 = w0 / triangle.area;
            const b1 = w1 / triangle.area;
            const b2 = w2 / triangle.area;
            const z = (b0 * v0.position[2]) + (b1 * v1.position[2]) + (b2 * v2.position[2]);
            const depth_z = biasedDepth(state, triangle, z);
            const frag_w = (b0 / v0.position[3]) + (b1 / v1.position[3]) + (b2 / v2.position[3]);
            const early_depth = try applyEarlyDepth(state, coverage_sample_mask, x, y, depth_z);
            if (early_depth.mask == 0)
                continue;

            const centroid_barycentrics = if (state.sample_count > 1 and state.fragment_uses_centroid) blk: {
                const sample_pos = firstCoveredSamplePosition(state.sample_count, early_depth.mask);
                const centroid_p = zm.f32x4(
                    @as(f32, @floatFromInt(x)) + sample_pos.x,
                    @as(f32, @floatFromInt(y)) + sample_pos.y,
                    0.0,
                    1.0,
                );
                break :blk .{
                    edgeFunction(v1.position, v2.position, centroid_p) / triangle.area,
                    edgeFunction(v2.position, v0.position, centroid_p) / triangle.area,
                    edgeFunction(v0.position, v1.position, centroid_p) / triangle.area,
                };
            } else .{ b0, b1, b2 };

            var fragment_result: fragment.InvocationResult = .{
                .outputs = std.mem.zeroes([spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(F32x4)]u8),
                .depth = null,
                .sample_mask = null,
            };
            if (state.has_fragment_shader and state.fragment_uses_sample_id and state.sample_count > 1) {
                const worker = optional_worker orelse return VkError.InvalidPipelineDrv;
                for (0..state.sample_count) |sample_index| {
                    if (sample_index >= @bitSizeOf(vk.SampleMask))
                        break;
                    const bit_index: u5 = @intCast(sample_index);
                    const sample_coverage_mask = @as(vk.SampleMask, 1) << bit_index;
                    if ((early_depth.mask & sample_coverage_mask) == 0)
                        continue;

                    const inputs = try fragmentInputs(
                        state,
                        triangle,
                        .{ b0, b1, b2 },
                        centroid_barycentrics,
                    );
                    const sample_result = fragment.shaderInvocation(
                        worker,
                        state.allocator,
                        zm.f32x4(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, depth_z, frag_w),
                        null,
                        @intCast(sample_index),
                        triangle.front_face,
                        inputs,
                        null,
                    ) catch |err| {
                        if (err == SpvRuntimeError.Killed)
                            continue;
                        logFragmentError(err);
                        return VkError.Unknown;
                    };
                    try common.writeToTargets(
                        sample_result.outputs,
                        state.draw_call,
                        state.color_attachment_access,
                        state.depth_attachment_access,
                        state.stencil_attachment_access,
                        triangle.front_face,
                        @intCast(x),
                        @intCast(y),
                        sample_result.depth orelse depth_z,
                        sample_coverage_mask,
                        sample_result.sample_mask,
                        early_depth.applied,
                        state.ordering,
                    );
                }
                continue;
            }

            if (state.has_fragment_shader) {
                const worker = optional_worker orelse return VkError.InvalidPipelineDrv;
                const inputs = try fragmentInputs(
                    state,
                    triangle,
                    .{ b0, b1, b2 },
                    centroid_barycentrics,
                );
                const derivative_inputs: ?fragment.DerivativeInputs = if (state.fragment_uses_derivatives) blk: {
                    if (comptime base.config.soft_ir_interpreter)
                        break :blk try irQuadHelpers(state, triangle, x, y);
                    const p_dx = zm.f32x4(@as(f32, @floatFromInt(x)) + 1.5, @as(f32, @floatFromInt(y)) + 0.5, 0.0, 1.0);
                    const p_dy = zm.f32x4(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 1.5, 0.0, 1.0);

                    break :blk fragment.DerivativeInputs{
                        .dx = try common.interpolateVertexOutputDerivatives(
                            state.allocator,
                            v0.attributes,
                            v1.attributes,
                            v2.attributes,
                            b0,
                            b1,
                            b2,
                            (edgeFunction(v1.position, v2.position, p_dx) / triangle.area) - b0,
                            (edgeFunction(v2.position, v0.position, p_dx) / triangle.area) - b1,
                            (edgeFunction(v0.position, v1.position, p_dx) / triangle.area) - b2,
                        ),
                        .dy = try common.interpolateVertexOutputDerivatives(
                            state.allocator,
                            v0.attributes,
                            v1.attributes,
                            v2.attributes,
                            b0,
                            b1,
                            b2,
                            (edgeFunction(v1.position, v2.position, p_dy) / triangle.area) - b0,
                            (edgeFunction(v2.position, v0.position, p_dy) / triangle.area) - b1,
                            (edgeFunction(v0.position, v1.position, p_dy) / triangle.area) - b2,
                        ),
                    };
                } else null;

                fragment_result = fragment.shaderInvocation(
                    worker,
                    state.allocator,
                    zm.f32x4(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, depth_z, frag_w),
                    null,
                    null,
                    triangle.front_face,
                    inputs,
                    derivative_inputs,
                ) catch |err| {
                    if (err == SpvRuntimeError.Killed)
                        continue;
                    logFragmentError(err);
                    return VkError.Unknown;
                };
            }

            try common.writeToTargets(
                fragment_result.outputs,
                state.draw_call,
                state.color_attachment_access,
                state.depth_attachment_access,
                state.stencil_attachment_access,
                triangle.front_face,
                @intCast(x),
                @intCast(y),
                fragment_result.depth orelse depth_z,
                early_depth.mask,
                fragment_result.sample_mask,
                early_depth.applied,
                state.ordering,
            );
        }
    }
}

fn rasterizeTriangleInRectWave(
    state: *const FillState,
    worker: *fragment.Worker,
    triangle: *const PreparedTriangle,
    bounds: common.PixelBounds,
) VkError!void {
    const v0 = triangle.vertices[0];
    const v1 = triangle.vertices[1];
    const v2 = triangle.vertices[2];
    const lane_count = interpreter_simd.lane_count;
    const inv_area = 1.0 / triangle.area;
    const edge_dx = [3]f32{
        v2.position[1] - v1.position[1],
        v0.position[1] - v2.position[1],
        v1.position[1] - v0.position[1],
    };
    const edge_dy = [3]f32{
        v1.position[0] - v2.position[0],
        v2.position[0] - v0.position[0],
        v0.position[0] - v1.position[0],
    };
    const first_sample = zm.f32x4(
        @as(f32, @floatFromInt(bounds.min_x)) + 0.5,
        @as(f32, @floatFromInt(bounds.min_y)) + 0.5,
        0.0,
        1.0,
    );
    var row_edges = [3]f32{
        edgeFunction(v1.position, v2.position, first_sample),
        edgeFunction(v2.position, v0.position, first_sample),
        edgeFunction(v0.position, v1.position, first_sample),
    };

    var y = bounds.min_y;
    while (y <= bounds.max_y) : ({
        y += 1;
        for (&row_edges, edge_dy) |*edge, step|
            edge.* += step;
    }) {
        var x = bounds.min_x;
        var chunk_edges = row_edges;
        while (x <= bounds.max_x) : ({
            x += lane_count;
            for (&chunk_edges, edge_dx) |*edge, step|
                edge.* += step * lane_count;
        }) {
            var invocations: [lane_count]fragment.WaveInvocation = undefined;
            var barycentrics: [lane_count][3]f32 = undefined;
            var depths: [lane_count]f32 = undefined;
            var early_applied: [lane_count]bool = undefined;
            var mask: interpreter_simd.LaneMask = 0;

            // SAFETY: only read when soft_profile is enabled at comptime, which also initializes the timer
            const coverage_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(worker.io, .real) else undefined;
            for (0..lane_count) |lane| {
                const lane_x = x + @as(i32, @intCast(lane));
                if (lane_x > bounds.max_x)
                    continue;

                const lane_offset: f32 = @floatFromInt(lane);
                const w0 = chunk_edges[0] + edge_dx[0] * lane_offset;
                const w1 = chunk_edges[1] + edge_dx[1] * lane_offset;
                const w2 = chunk_edges[2] + edge_dx[2] * lane_offset;
                if (!edgeContainsPixel(v1.position, v2.position, w0, triangle.area) or
                    !edgeContainsPixel(v2.position, v0.position, w1, triangle.area) or
                    !edgeContainsPixel(v0.position, v1.position, w2, triangle.area))
                    continue;

                const weights = [3]f32{ w0 * inv_area, w1 * inv_area, w2 * inv_area };
                barycentrics[lane] = weights;
                const z = (weights[0] * v0.position[2]) + (weights[1] * v1.position[2]) + (weights[2] * v2.position[2]);
                depths[lane] = biasedDepth(state, triangle, z);
                mask |= interpreter_simd.laneBit(@intCast(lane));
            }
            if (comptime base.config.soft_profile)
                worker.coverage_ns += Renderer.profileElapsedNs(coverage_timer, worker.io);

            if (mask == 0)
                continue;

            // SAFETY: only read when soft_profile is enabled at comptime, which also initializes the timer
            const depth_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(worker.io, .real) else undefined;
            for (0..lane_count) |lane| {
                const bit = interpreter_simd.laneBit(@intCast(lane));
                if ((mask & bit) == 0)
                    continue;
                const lane_x = x + @as(i32, @intCast(lane));
                const early_depth = try applyEarlyDepth(state, 1, lane_x, y, depths[lane]);
                if (early_depth.mask == 0) {
                    mask &= ~bit;
                    continue;
                }
                early_applied[lane] = early_depth.applied;
            }
            if (comptime base.config.soft_profile)
                worker.depth_ns += Renderer.profileElapsedNs(depth_timer, worker.io);

            if (mask == 0)
                continue;

            // SAFETY: only read when soft_profile is enabled at comptime, which also initializes the timer
            const interpolation_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(worker.io, .real) else undefined;
            for (0..lane_count) |lane| {
                const bit = interpreter_simd.laneBit(@intCast(lane));
                if ((mask & bit) == 0)
                    continue;
                const lane_x = x + @as(i32, @intCast(lane));
                const weights = barycentrics[lane];
                const frag_w = (weights[0] / v0.position[3]) + (weights[1] / v1.position[3]) + (weights[2] / v2.position[3]);
                invocations[lane] = .{
                    .position = zm.f32x4(@as(f32, @floatFromInt(lane_x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, depths[lane], frag_w),
                    .inputs = try fragmentInputs(state, triangle, weights, weights),
                };
            }
            if (comptime base.config.soft_profile)
                worker.interpolation_ns += Renderer.profileElapsedNs(interpolation_timer, worker.io);

            const wave = fragment.shaderWave(worker, &invocations, mask) catch |err| {
                logFragmentError(err);
                return VkError.Unknown;
            };

            // SAFETY: only read when soft_profile is enabled at comptime, which also initializes the timer
            const target_output_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(worker.io, .real) else undefined;
            if (state.opaque_single_sample_output) {
                var output_depths = depths;
                const shader_depths: [lane_count]f32 = @bitCast(wave.depths);
                for (0..lane_count) |lane| {
                    const bit = interpreter_simd.laneBit(@intCast(lane));
                    if ((wave.depth_mask & bit) != 0)
                        output_depths[lane] = shader_depths[lane];
                }
                try common.writeOpaqueSingleSampleWaveToTargets(
                    &wave.outputs,
                    &wave.output_components,
                    state.draw_call,
                    state.color_attachment_access,
                    state.depth_attachment_access,
                    state.depth_stencil_state,
                    @intCast(x),
                    @intCast(y),
                    wave.returned_mask,
                    &output_depths,
                    &early_applied,
                    state.ordering,
                );
            } else {
                for (0..lane_count) |lane| {
                    const bit = interpreter_simd.laneBit(@intCast(lane));
                    if ((wave.returned_mask & bit) == 0)
                        continue;
                    const lane_x = x + @as(i32, @intCast(lane));
                    const result = wave.laneResult(lane);
                    try common.writeToTargets(
                        result.outputs,
                        state.draw_call,
                        state.color_attachment_access,
                        state.depth_attachment_access,
                        state.stencil_attachment_access,
                        triangle.front_face,
                        @intCast(lane_x),
                        @intCast(y),
                        result.depth orelse depths[lane],
                        1,
                        result.sample_mask,
                        early_applied[lane],
                        state.ordering,
                    );
                }
            }
            if (comptime base.config.soft_profile)
                worker.target_output_ns += Renderer.profileElapsedNs(target_output_timer, worker.io);
        }
    }
}

fn rasterizeTriangleInRectQuads(state: *const FillState, worker: *fragment.Worker, triangle: *const PreparedTriangle, bounds: common.PixelBounds) VkError!void {
    const lane_count = interpreter_simd.lane_count;
    const quads_per_wave = lane_count / 4;

    var y = bounds.min_y & ~@as(i32, 1);

    while (y <= bounds.max_y) : (y += 2) {
        var x = bounds.min_x & ~@as(i32, 1);

        while (x <= bounds.max_x) : (x += 2 * quads_per_wave) {
            var invocations: [lane_count]fragment.WaveInvocation = undefined;
            var early_applied: [lane_count]bool = @splat(false);
            var execution_mask: interpreter_simd.LaneMask = 0;
            var observable_mask: interpreter_simd.LaneMask = 0;

            for (0..quads_per_wave) |quad_index| {
                const quad_x = x + @as(i32, @intCast(quad_index * 2));

                if (quad_x > bounds.max_x)
                    break;

                // SAFETY: only read when soft_profile is enabled at comptime, which also initializes the timer
                const coverage_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(worker.io, .real) else undefined;
                const quad = irQuadCoverage(state, triangle, bounds, quad_x, y);

                if (comptime base.config.soft_profile)
                    worker.coverage_ns += Renderer.profileElapsedNs(coverage_timer, worker.io);

                if (quad.mask == 0)
                    continue;

                var quad_mask = quad.mask;
                // SAFETY: only read when soft_profile is enabled at comptime, which also initializes the timer
                const depth_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(worker.io, .real) else undefined;

                for (0..4) |quad_lane| {
                    const bit = @as(u4, 1) << @intCast(quad_lane);
                    if (quad_mask & bit == 0)
                        continue;

                    const pixel_x = quad_x + @as(i32, @intCast(quad_lane & 1));
                    const pixel_y = y + @as(i32, @intCast(quad_lane >> 1));
                    const depth = try applyEarlyDepth(state, 1, pixel_x, pixel_y, quad.positions[quad_lane][2]);

                    if (depth.mask == 0) {
                        quad_mask &= ~bit;
                    } else {
                        early_applied[quad_index * 4 + quad_lane] = depth.applied;
                    }
                }

                if (comptime base.config.soft_profile)
                    worker.depth_ns += Renderer.profileElapsedNs(depth_timer, worker.io);

                if (quad_mask == 0)
                    continue;

                // SAFETY: only read when soft_profile is enabled at comptime, which also initializes the timer
                const interpolation_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(worker.io, .real) else undefined;

                // Remaining fragments need all four interpolated lanes
                for (0..4) |quad_lane| {
                    const weights = quad.barycentrics[quad_lane];
                    invocations[quad_index * 4 + quad_lane] = .{
                        .position = quad.positions[quad_lane],
                        .inputs = try fragmentInputs(state, triangle, weights, weights),
                    };
                }

                if (comptime base.config.soft_profile)
                    worker.interpolation_ns += Renderer.profileElapsedNs(interpolation_timer, worker.io);

                const shift: interpreter_simd.Lane = @intCast(quad_index * 4);
                execution_mask |= @as(interpreter_simd.LaneMask, 0b1111) << shift;
                observable_mask |= @as(interpreter_simd.LaneMask, quad_mask) << shift;
            }

            if (observable_mask == 0)
                continue;

            const wave = fragment.shaderWaveMasked(worker, &invocations, execution_mask, observable_mask) catch |err| {
                logFragmentError(err);
                return VkError.Unknown;
            };

            // SAFETY: only read when soft_profile is enabled at comptime, which also initializes the timer
            const target_output_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(worker.io, .real) else undefined;

            for (0..lane_count) |lane| {
                if (wave.returned_mask & interpreter_simd.laneBit(@intCast(lane)) == 0)
                    continue;

                const pixel_x = x + @as(i32, @intCast((lane / 4) * 2 + (lane & 1)));
                const pixel_y = y + @as(i32, @intCast((lane % 4) >> 1));
                const result = wave.laneResult(lane);

                try common.writeToTargets(
                    result.outputs,
                    state.draw_call,
                    state.color_attachment_access,
                    state.depth_attachment_access,
                    state.stencil_attachment_access,
                    triangle.front_face,
                    @intCast(pixel_x),
                    @intCast(pixel_y),
                    result.depth orelse invocations[lane].position[2],
                    1,
                    result.sample_mask,
                    early_applied[lane],
                    state.ordering,
                );
            }

            if (comptime base.config.soft_profile)
                worker.target_output_ns += Renderer.profileElapsedNs(target_output_timer, worker.io);
        }
    }
}

const QuadCoverage = struct {
    positions: [4]F32x4,
    barycentrics: [4][3]f32,
    mask: u4,
};

fn irQuadCoverage(state: *const FillState, triangle: *const PreparedTriangle, bounds: common.PixelBounds, x: i32, y: i32) QuadCoverage {
    const v0 = triangle.vertices[0].position;
    const v1 = triangle.vertices[1].position;
    const v2 = triangle.vertices[2].position;

    // SAFETY: the loop initializes all four positions and barycentrics before returning the quad.
    var quad: QuadCoverage = .{ .positions = undefined, .barycentrics = undefined, .mask = 0 };

    for (0..4) |lane| {
        const pixel_x = x + @as(i32, @intCast(lane & 1));
        const pixel_y = y + @as(i32, @intCast(lane >> 1));

        var p = zm.f32x4(@as(f32, @floatFromInt(pixel_x)) + 0.5, @as(f32, @floatFromInt(pixel_y)) + 0.5, 0, 1);

        const edges = [3]f32{ edgeFunction(v1, v2, p), edgeFunction(v2, v0, p), edgeFunction(v0, v1, p) };
        const weights = [3]f32{ edges[0] / triangle.area, edges[1] / triangle.area, edges[2] / triangle.area };

        p[2] = biasedDepth(state, triangle, weights[0] * v0[2] + weights[1] * v1[2] + weights[2] * v2[2]);
        p[3] = weights[0] / v0[3] + weights[1] / v1[3] + weights[2] / v2[3];

        quad.positions[lane] = p;
        quad.barycentrics[lane] = weights;

        if (pixel_x >= bounds.min_x and pixel_x <= bounds.max_x and pixel_y >= bounds.min_y and pixel_y <= bounds.max_y and
            edgeContainsPixel(v1, v2, edges[0], triangle.area) and
            edgeContainsPixel(v2, v0, edges[1], triangle.area) and
            edgeContainsPixel(v0, v1, edges[2], triangle.area))
        {
            quad.mask |= @as(u4, 1) << @intCast(lane);
        }
    }
    return quad;
}

fn irQuadHelpers(state: *const FillState, triangle: *const PreparedTriangle, x: i32, y: i32) VkError!fragment.DerivativeInputs {
    const v0 = triangle.vertices[0];
    const v1 = triangle.vertices[1];
    const v2 = triangle.vertices[2];
    var inputs: [4]fragment.FragmentInputs = undefined;
    var positions: [4]F32x4 = undefined;
    for (0..4) |lane| {
        const helper_x = (x & ~@as(i32, 1)) + @as(i32, @intCast(lane & 1));
        const helper_y = (y & ~@as(i32, 1)) + @as(i32, @intCast(lane >> 1));
        var p = zm.f32x4(@as(f32, @floatFromInt(helper_x)) + 0.5, @as(f32, @floatFromInt(helper_y)) + 0.5, 0, 1);
        const weights = [3]f32{
            edgeFunction(v1.position, v2.position, p) / triangle.area,
            edgeFunction(v2.position, v0.position, p) / triangle.area,
            edgeFunction(v0.position, v1.position, p) / triangle.area,
        };
        p[2] = biasedDepth(state, triangle, weights[0] * v0.position[2] + weights[1] * v1.position[2] + weights[2] * v2.position[2]);
        p[3] = weights[0] / v0.position[3] + weights[1] / v1.position[3] + weights[2] / v2.position[3];
        positions[lane] = p;
        // Extrapolate even outside coverage, scissor, or a worker's tile.
        inputs[lane] = try fragmentInputs(state, triangle, weights, weights);
    }
    return .{
        .dx = inputs[1],
        .dy = inputs[2],
        .quad_inputs = inputs,
        .quad_positions = positions,
        .quad_lane = @intCast((x & 1) | ((y & 1) << 1)),
    };
}

fn fragmentInputs(
    state: *const FillState,
    triangle: *const PreparedTriangle,
    barycentrics: [3]f32,
    centroid_barycentrics: [3]f32,
) VkError!fragment.FragmentInputs {
    if (comptime base.config.soft_ir_interpreter) {
        return common.packedFragmentInputs(
            triangle.vertices[0],
            triangle.vertices[1],
            triangle.vertices[2],
            triangle.provoking_vertex,
            barycentrics,
            centroid_barycentrics,
        );
    }
    return common.interpolateVertexOutputs(
        state.allocator,
        triangle.vertices[0].attributes,
        triangle.vertices[1].attributes,
        triangle.vertices[2].attributes,
        triangle.provoking_vertex,
        barycentrics[0],
        barycentrics[1],
        barycentrics[2],
        centroid_barycentrics[0],
        centroid_barycentrics[1],
        centroid_barycentrics[2],
    );
}

fn triangleCoverageMask(triangle: *const PreparedTriangle, x: i32, y: i32, sample_count: usize) vk.SampleMask {
    const v0 = triangle.vertices[0].position;
    const v1 = triangle.vertices[1].position;
    const v2 = triangle.vertices[2].position;
    var mask: vk.SampleMask = 0;
    for (0..sample_count) |sample_index| {
        if (sample_index >= @bitSizeOf(vk.SampleMask))
            break;
        const sample_pos = standardSamplePosition(sample_count, sample_index);
        const p = zm.f32x4(
            @as(f32, @floatFromInt(x)) + sample_pos.x,
            @as(f32, @floatFromInt(y)) + sample_pos.y,
            0.0,
            1.0,
        );
        const w0 = edgeFunction(v1, v2, p);
        const w1 = edgeFunction(v2, v0, p);
        const w2 = edgeFunction(v0, v1, p);
        if (edgeContainsPixel(v1, v2, w0, triangle.area) and
            edgeContainsPixel(v2, v0, w1, triangle.area) and
            edgeContainsPixel(v0, v1, w2, triangle.area))
        {
            mask |= @as(vk.SampleMask, 1) << @as(u5, @intCast(sample_index));
        }
    }
    return mask;
}

fn applyEarlyDepth(
    state: *const FillState,
    coverage_sample_mask: vk.SampleMask,
    x: i32,
    y: i32,
    z: f32,
) VkError!struct { mask: vk.SampleMask, applied: bool } {
    if (!state.early_fragment_tests)
        return .{ .mask = coverage_sample_mask, .applied = false };
    const depth = state.depth_attachment_access orelse return .{ .mask = coverage_sample_mask, .applied = false };
    const io = state.draw_call.renderer.device.interface.io();
    var passed_mask: vk.SampleMask = 0;
    for (0..state.sample_count) |sample_index| {
        if (sample_index >= @bitSizeOf(vk.SampleMask))
            break;
        const bit = @as(vk.SampleMask, 1) << @as(u5, @intCast(sample_index));
        if ((coverage_sample_mask & bit) == 0)
            continue;
        if (try common.depthTestSampleAndUpdate(
            io,
            depth,
            @intCast(x),
            @intCast(y),
            sample_index,
            z,
            state.depth_stencil_state,
            state.ordering,
        )) passed_mask |= bit;
    }
    return .{ .mask = passed_mask, .applied = true };
}

fn biasedDepth(state: *const FillState, triangle: *const PreparedTriangle, z: f32) f32 {
    const depth = state.depth_attachment_access orelse return z;
    const bias_state = state.depth_bias orelse return z;
    const bias = bias_state.constant_factor * common.depthBiasConstantUnit(depth.format, z) +
        bias_state.slope_factor * triangle.depth_bias_slope;
    return z + common.clampDepthBias(bias, bias_state.clamp);
}

fn runWrapper(data: RunData) void {
    run(data) catch |err| {
        std.log.scoped(.@"Rasterization stage").err("triangle fill mode caught a '{s}'", .{@errorName(err)});
        if (comptime base.config.logs == .verbose) {
            if (@errorReturnTrace()) |trace|
                std.debug.dumpErrorReturnTrace(trace);
        }
    };
}

fn run(data: RunData) VkError!void {
    // SAFETY: only used if data.sate.has_fragment_shader
    var fragment_worker: fragment.Worker = if (data.state.has_fragment_shader) try fragment.acquireWorker(data.state.draw_call, data.batch_id) else undefined;
    defer if (data.state.has_fragment_shader)
        fragment_worker.release();

    try rasterizeTriangleInRect(data.state, if (data.state.has_fragment_shader) &fragment_worker else null, data.triangle, data.bounds);
}

fn intersectRect(bounds: common.PixelBounds, rect: vk.Rect2D) ?common.PixelBounds {
    if (rect.extent.width == 0 or rect.extent.height == 0)
        return null;
    return common.PixelBounds.intersect(bounds, .{
        .min_x = rect.offset.x,
        .max_x = clampI64ToI32(@as(i64, rect.offset.x) + @as(i64, @intCast(rect.extent.width)) - 1),
        .min_y = rect.offset.y,
        .max_y = clampI64ToI32(@as(i64, rect.offset.y) + @as(i64, @intCast(rect.extent.height)) - 1),
    });
}

fn clampI64ToI32(value: i64) i32 {
    return @intCast(std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn clampUsizeToI32(value: usize) i32 {
    return @intCast(@min(value, @as(usize, std.math.maxInt(i32))));
}

inline fn edgeFunction(a: F32x4, b: F32x4, p: F32x4) f32 {
    return ((p[0] - a[0]) * (b[1] - a[1])) - ((p[1] - a[1]) * (b[0] - a[0]));
}

inline fn isInclusiveEdge(a: F32x4, b: F32x4) bool {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    return dy > 0.0 or (dy == 0.0 and dx < 0.0);
}

inline fn edgeContainsPixel(a: F32x4, b: F32x4, edge_value: f32, area: f32) bool {
    return if (area > 0.0)
        edge_value > 0.0 or (edge_value == 0.0 and isInclusiveEdge(a, b))
    else
        edge_value < 0.0 or (edge_value == 0.0 and isInclusiveEdge(b, a));
}

fn standardSamplePosition(sample_count: usize, sample_index: usize) SamplePosition {
    return switch (sample_count) {
        1 => .{ .x = 0.5, .y = 0.5 },
        2 => switch (sample_index) {
            0 => .{ .x = 0.75, .y = 0.75 },
            1 => .{ .x = 0.25, .y = 0.25 },
            else => .{ .x = 0.5, .y = 0.5 },
        },
        4 => switch (sample_index) {
            0 => .{ .x = 0.375, .y = 0.125 },
            1 => .{ .x = 0.875, .y = 0.375 },
            2 => .{ .x = 0.125, .y = 0.625 },
            3 => .{ .x = 0.625, .y = 0.875 },
            else => .{ .x = 0.5, .y = 0.5 },
        },
        else => .{ .x = 0.5, .y = 0.5 },
    };
}

fn firstCoveredSamplePosition(sample_count: usize, coverage_sample_mask: vk.SampleMask) SamplePosition {
    for (0..sample_count) |sample_index| {
        if (sample_index >= @bitSizeOf(vk.SampleMask))
            break;
        const bit_index: u5 = @intCast(sample_index);
        if ((coverage_sample_mask & (@as(vk.SampleMask, 1) << bit_index)) != 0)
            return standardSamplePosition(sample_count, sample_index);
    }
    return .{ .x = 0.5, .y = 0.5 };
}

fn fragmentStageUsesInputDecoration(stage: anytype, decoration: anytype) bool {
    const rt = &stage.runtimes[0].rt;
    for (rt.mod.input_locations) |location| {
        for (location) |result_word| {
            if (result_word == 0)
                continue;
            if (rt.hasResultDecoration(result_word, decoration))
                return true;
        }
    }
    return false;
}

fn logFragmentError(err: anyerror) void {
    std.log.scoped(.@"Fragment stage").err("caught a '{s}'", .{@errorName(err)});
    if (comptime base.config.logs == .verbose) {
        if (@errorReturnTrace()) |trace|
            std.debug.dumpErrorReturnTrace(trace);
    }
}
