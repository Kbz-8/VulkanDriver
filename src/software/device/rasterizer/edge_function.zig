const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");
const zm = base.zm;

const common = @import("common.zig");
const fragment = @import("../fragment.zig");

const Renderer = @import("../Renderer.zig");

const VkError = base.VkError;
const SpvRuntimeError = spv.Runtime.RuntimeError;
const F32x4 = zm.F32x4;

const SamplePosition = struct {
    x: f32,
    y: f32,
};

const RunData = struct {
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    batch_id: usize,
    min_x: i32,
    max_x: i32,
    min_y: i32,
    max_y: i32,
    area: f32,
    v0: Renderer.Vertex,
    v1: Renderer.Vertex,
    v2: Renderer.Vertex,
    provoking_vertex: Renderer.Vertex,
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
    front_face: bool,
    has_fragment_shader: bool,
    early_fragment_tests: bool,
    fragment_uses_derivatives: bool,
    fragment_uses_sample_id: bool,
    fragment_uses_centroid: bool,
    sample_count: usize,
    depth_stencil_state: ?vk.PipelineDepthStencilStateCreateInfo,
    depth_bias: ?Renderer.DepthBias,
    depth_bias_slope: f32,
};

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
    const io = draw_call.renderer.device.interface.io();

    var min_x: i32 = @intFromFloat(@floor(@min(v0.position[0], v1.position[0], v2.position[0])));
    var max_x: i32 = @intFromFloat(@ceil(@max(v0.position[0], v1.position[0], v2.position[0])));
    var min_y: i32 = @intFromFloat(@floor(@min(v0.position[1], v1.position[1], v2.position[1])));
    var max_y: i32 = @intFromFloat(@ceil(@max(v0.position[1], v1.position[1], v2.position[1])));

    const area = edgeFunction(v0.position, v1.position, v2.position);
    if (area == 0.0)
        return;
    const inv_area = 1.0 / area;
    const dz_dx =
        (v0.position[2] * ((v1.position[1] - v2.position[1]) * inv_area)) +
        (v1.position[2] * ((v2.position[1] - v0.position[1]) * inv_area)) +
        (v2.position[2] * ((v0.position[1] - v1.position[1]) * inv_area));
    const dz_dy =
        (v0.position[2] * ((v2.position[0] - v1.position[0]) * inv_area)) +
        (v1.position[2] * ((v0.position[0] - v2.position[0]) * inv_area)) +
        (v2.position[2] * ((v1.position[0] - v0.position[0]) * inv_area));
    const depth_bias_slope = @max(@abs(dz_dx), @abs(dz_dy));

    const pipeline = draw_call.renderer.state.pipeline orelse return;
    const pipeline_data = pipeline.interface.mode.graphics;
    if (!clipToRect(&min_x, &max_x, &min_y, &max_y, draw_call.scissor))
        return;
    if (draw_call.renderer.render_area) |render_area| {
        if (!clipToRect(&min_x, &max_x, &min_y, &max_y, render_area))
            return;
    }

    const fragment_stage = pipeline.stages.getPtr(.fragment);
    const fragment_uses_derivatives = if (fragment_stage) |stage|
        stage.module.module.reflection_infos.needs_derivatives
    else
        false;
    const early_fragment_tests = if (fragment_stage) |stage|
        stage.module.module.reflection_infos.early_fragment_tests
    else
        false;
    const fragment_uses_sample_id = if (fragment_stage) |stage|
        stage.module.module.builtins.get(.SampleId) != null
    else
        false;
    const fragment_uses_centroid = if (fragment_stage) |stage|
        fragmentStageUsesInputDecoration(stage, .Centroid)
    else
        false;

    const runtimes_count = if (fragment_stage) |stage| stage.runtimes.len else 1;
    if (runtimes_count == 0)
        return;
    const sample_count = pipeline_data.multisample.rasterization_samples.toInt();
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
    const grid_size: usize = @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(runtimes_count)))));

    const width: usize = @intCast(max_x - min_x + 1);
    const height: usize = @intCast(max_y - min_y + 1);

    const cols_per_run = @divTrunc(width + grid_size - 1, grid_size);
    const rows_per_run = @divTrunc(height + grid_size - 1, grid_size);

    var batch_id: usize = 0;

    for (0..grid_size) |gy| {
        for (0..grid_size) |gx| {
            defer batch_id = @mod(batch_id + 1, runtimes_count);

            const run_min_x = min_x + @as(i32, @intCast(gx * cols_per_run));
            const run_min_y = min_y + @as(i32, @intCast(gy * rows_per_run));

            if (run_min_x > max_x or run_min_y > max_y)
                continue;

            const run_max_x = @min(
                run_min_x + @as(i32, @intCast(cols_per_run)) - 1,
                max_x,
            );

            const run_max_y = @min(
                run_min_y + @as(i32, @intCast(rows_per_run)) - 1,
                max_y,
            );

            const run_data: RunData = .{
                .allocator = allocator,
                .draw_call = draw_call,
                .batch_id = batch_id,
                .v0 = v0.*,
                .v1 = v1.*,
                .v2 = v2.*,
                .provoking_vertex = provoking_vertex.*,
                .area = area,
                .min_x = run_min_x,
                .max_x = run_max_x,
                .min_y = run_min_y,
                .max_y = run_max_y,
                .color_attachment_access = color_attachment_access,
                .depth_attachment_access = depth_attachment_access,
                .stencil_attachment_access = stencil_attachment_access,
                .front_face = front_face,
                .has_fragment_shader = fragment_stage != null,
                .early_fragment_tests = early_fragment_tests,
                .fragment_uses_derivatives = fragment_uses_derivatives,
                .fragment_uses_sample_id = fragment_uses_sample_id,
                .fragment_uses_centroid = fragment_uses_centroid,
                .sample_count = sample_count,
                .depth_stencil_state = depth_stencil_state,
                .depth_bias = depth_bias,
                .depth_bias_slope = depth_bias_slope,
            };

            draw_call.rasterizer_wait_group.async(io, runWrapper, .{run_data});
        }
    }

    draw_call.rasterizer_wait_group.await(io) catch return VkError.DeviceLost;
}

fn clipToRect(min_x: *i32, max_x: *i32, min_y: *i32, max_y: *i32, rect: vk.Rect2D) bool {
    if (rect.extent.width == 0 or rect.extent.height == 0)
        return false;

    const rect_min_x = rect.offset.x;
    const rect_min_y = rect.offset.y;
    const rect_max_x = clampI64ToI32(@as(i64, rect.offset.x) + @as(i64, @intCast(rect.extent.width)) - 1);
    const rect_max_y = clampI64ToI32(@as(i64, rect.offset.y) + @as(i64, @intCast(rect.extent.height)) - 1);

    min_x.* = @max(min_x.*, rect_min_x);
    min_y.* = @max(min_y.*, rect_min_y);
    max_x.* = @min(max_x.*, rect_max_x);
    max_y.* = @min(max_y.*, rect_max_y);
    return min_x.* <= max_x.* and min_y.* <= max_y.*;
}

fn clampI64ToI32(value: i64) i32 {
    return @intCast(std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32)));
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

inline fn standardSamplePosition(sample_count: usize, sample_index: usize) SamplePosition {
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

fn triangleCoverageMask(data: RunData, x: i32, y: i32, sample_count: usize) vk.SampleMask {
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

        const w0 = edgeFunction(data.v1.position, data.v2.position, p);
        const w1 = edgeFunction(data.v2.position, data.v0.position, p);
        const w2 = edgeFunction(data.v0.position, data.v1.position, p);

        const inside =
            edgeContainsPixel(data.v1.position, data.v2.position, w0, data.area) and
            edgeContainsPixel(data.v2.position, data.v0.position, w1, data.area) and
            edgeContainsPixel(data.v0.position, data.v1.position, w2, data.area);

        if (inside) {
            const bit_index: u5 = @intCast(sample_index);
            mask |= @as(vk.SampleMask, 1) << bit_index;
        }
    }
    return mask;
}

fn applyEarlyDepth(data: RunData, coverage_sample_mask: vk.SampleMask, x: i32, y: i32, z: f32, sample_count: usize) VkError!struct {
    mask: vk.SampleMask,
    applied: bool,
} {
    if (!data.early_fragment_tests)
        return .{ .mask = coverage_sample_mask, .applied = false };

    const depth = data.depth_attachment_access orelse return .{ .mask = coverage_sample_mask, .applied = false };
    const io = data.draw_call.renderer.device.interface.io();

    var passed_mask: vk.SampleMask = 0;
    for (0..sample_count) |sample_index| {
        if (sample_index >= @bitSizeOf(vk.SampleMask))
            break;

        const bit = @as(vk.SampleMask, 1) << @as(u5, @intCast(sample_index));
        if ((coverage_sample_mask & bit) == 0)
            continue;

        if (try common.depthTestSampleAndUpdate(io, depth, @intCast(x), @intCast(y), sample_index, z, data.depth_stencil_state))
            passed_mask |= bit;
    }

    return .{ .mask = passed_mask, .applied = true };
}

fn biasedDepth(data: RunData, z: f32) f32 {
    const depth = data.depth_attachment_access orelse return z;
    const bias_state = data.depth_bias orelse return z;

    const bias =
        bias_state.constant_factor * common.depthBiasConstantUnit(depth.format, z) +
        bias_state.slope_factor * data.depth_bias_slope;
    return z + common.clampDepthBias(bias, bias_state.clamp);
}

fn runWrapper(data: RunData) void {
    @call(.always_inline, run, .{data}) catch |err| {
        std.log.scoped(.@"Rasterization stage").err("triangle fill mode catched a '{s}'", .{@errorName(err)});
        if (comptime base.config.logs == .verbose) {
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
        }
    };
}

inline fn run(data: RunData) !void {
    var y = data.min_y;
    while (y <= data.max_y) : (y += 1) {
        var x = data.min_x;
        while (x <= data.max_x) : (x += 1) {
            const p = zm.f32x4(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, 0.0, 1.0);

            const w0 = edgeFunction(data.v1.position, data.v2.position, p);
            const w1 = edgeFunction(data.v2.position, data.v0.position, p);
            const w2 = edgeFunction(data.v0.position, data.v1.position, p);
            const coverage_sample_mask = if (data.sample_count == 1) blk: {
                const inside =
                    edgeContainsPixel(data.v1.position, data.v2.position, w0, data.area) and
                    edgeContainsPixel(data.v2.position, data.v0.position, w1, data.area) and
                    edgeContainsPixel(data.v0.position, data.v1.position, w2, data.area);
                break :blk if (inside) @as(vk.SampleMask, 1) else @as(vk.SampleMask, 0);
            } else triangleCoverageMask(data, x, y, data.sample_count);
            if (coverage_sample_mask == 0)
                continue;

            const b0 = w0 / data.area;
            const b1 = w1 / data.area;
            const b2 = w2 / data.area;
            const z = (b0 * data.v0.position[2]) + (b1 * data.v1.position[2]) + (b2 * data.v2.position[2]);
            const depth_z = biasedDepth(data, z);
            const frag_w = (b0 / data.v0.position[3]) + (b1 / data.v1.position[3]) + (b2 / data.v2.position[3]);
            const early_depth = try applyEarlyDepth(data, coverage_sample_mask, x, y, depth_z, data.sample_count);
            if (early_depth.mask == 0)
                continue;

            const interpolation_barycentrics = if (data.sample_count > 1) blk: {
                const sample_pos = firstCoveredSamplePosition(data.sample_count, early_depth.mask);
                const centroid_p = zm.f32x4(
                    @as(f32, @floatFromInt(x)) + sample_pos.x,
                    @as(f32, @floatFromInt(y)) + sample_pos.y,
                    0.0,
                    1.0,
                );
                const centroid_w0 = edgeFunction(data.v1.position, data.v2.position, centroid_p);
                const centroid_w1 = edgeFunction(data.v2.position, data.v0.position, centroid_p);
                const centroid_w2 = edgeFunction(data.v0.position, data.v1.position, centroid_p);
                break :blk .{
                    centroid_w0 / data.area,
                    centroid_w1 / data.area,
                    centroid_w2 / data.area,
                };
            } else .{ b0, b1, b2 };
            const input_b0 = interpolation_barycentrics[0];
            const input_b1 = interpolation_barycentrics[1];
            const input_b2 = interpolation_barycentrics[2];

            var fragment_result: fragment.InvocationResult = .{
                .outputs = std.mem.zeroes([spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(F32x4)]u8),
                .depth = null,
                .sample_mask = null,
            };
            if (data.has_fragment_shader and data.fragment_uses_sample_id and data.sample_count > 1) {
                for (0..data.sample_count) |sample_index| {
                    if (sample_index >= @bitSizeOf(vk.SampleMask))
                        break;

                    const bit_index: u5 = @intCast(sample_index);
                    const sample_coverage_mask = @as(vk.SampleMask, 1) << bit_index;
                    if ((early_depth.mask & sample_coverage_mask) == 0)
                        continue;

                    const inputs = try common.interpolateVertexOutputs(data.allocator, &data.v0, &data.v1, &data.v2, &data.provoking_vertex, input_b0, input_b1, input_b2);
                    const sample_result = fragment.shaderInvocation(
                        data.allocator,
                        data.draw_call,
                        data.batch_id,
                        zm.f32x4(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, depth_z, frag_w),
                        null,
                        @intCast(sample_index),
                        data.front_face,
                        inputs,
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

                    try common.writeToTargets(
                        sample_result.outputs,
                        data.draw_call,
                        data.color_attachment_access,
                        data.depth_attachment_access,
                        data.stencil_attachment_access,
                        data.front_face,
                        @intCast(x),
                        @intCast(y),
                        sample_result.depth orelse depth_z,
                        sample_coverage_mask,
                        sample_result.sample_mask,
                        early_depth.applied,
                    );
                }
                continue;
            }
            if (data.has_fragment_shader) {
                const inputs = try common.interpolateVertexOutputs(data.allocator, &data.v0, &data.v1, &data.v2, &data.provoking_vertex, input_b0, input_b1, input_b2);
                const derivative_inputs: ?fragment.DerivativeInputs = if (data.fragment_uses_derivatives) blk: {
                    var derivatives: fragment.DerivativeInputs = undefined;

                    const p_dx = zm.f32x4(@as(f32, @floatFromInt(x)) + 1.5, @as(f32, @floatFromInt(y)) + 0.5, 0.0, 1.0);
                    const dx_w0 = edgeFunction(data.v1.position, data.v2.position, p_dx);
                    const dx_w1 = edgeFunction(data.v2.position, data.v0.position, p_dx);
                    const dx_w2 = edgeFunction(data.v0.position, data.v1.position, p_dx);
                    derivatives.dx = try common.interpolateVertexOutputDerivatives(
                        data.allocator,
                        &data.v0,
                        &data.v1,
                        &data.v2,
                        b0,
                        b1,
                        b2,
                        (dx_w0 / data.area) - b0,
                        (dx_w1 / data.area) - b1,
                        (dx_w2 / data.area) - b2,
                    );

                    const p_dy = zm.f32x4(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 1.5, 0.0, 1.0);
                    const dy_w0 = edgeFunction(data.v1.position, data.v2.position, p_dy);
                    const dy_w1 = edgeFunction(data.v2.position, data.v0.position, p_dy);
                    const dy_w2 = edgeFunction(data.v0.position, data.v1.position, p_dy);
                    derivatives.dy = try common.interpolateVertexOutputDerivatives(
                        data.allocator,
                        &data.v0,
                        &data.v1,
                        &data.v2,
                        b0,
                        b1,
                        b2,
                        (dy_w0 / data.area) - b0,
                        (dy_w1 / data.area) - b1,
                        (dy_w2 / data.area) - b2,
                    );
                    break :blk derivatives;
                } else null;

                fragment_result = fragment.shaderInvocation(
                    data.allocator,
                    data.draw_call,
                    data.batch_id,
                    zm.f32x4(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, depth_z, frag_w),
                    null,
                    null,
                    data.front_face,
                    inputs,
                    derivative_inputs,
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
                data.draw_call,
                data.color_attachment_access,
                data.depth_attachment_access,
                data.stencil_attachment_access,
                data.front_face,
                @intCast(x),
                @intCast(y),
                fragment_result.depth orelse depth_z,
                early_depth.mask,
                fragment_result.sample_mask,
                early_depth.applied,
            );
        }
    }
}
