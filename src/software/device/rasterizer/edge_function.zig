const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");
const zm = base.zm;

const common = @import("common.zig");
const fragment = @import("../fragment/dispatcher.zig");

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
        false
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
        stage.runtimes.len
    else if (pipeline.stages.getPtr(.vertex)) |stage|
        stage.runtimes.len
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
