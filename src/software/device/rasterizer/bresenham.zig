const std = @import("std");
const base = @import("base");
const spv = @import("spv");
const vk = @import("vulkan");
const zm = base.zm;

const common = @import("common.zig");
const fragment = @import("../fragment.zig");

const Renderer = @import("../Renderer.zig");
const SoftImage = @import("../../SoftImage.zig");

const VkError = base.VkError;
const SpvRuntimeError = spv.Runtime.RuntimeError;
const F32x4 = zm.F32x4;

const RunData = struct {
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    batch_id: usize,
    x0: i32,
    y0: i32,
    d_x: i32,
    d_err: i32,
    y_step: i32,
    steep: bool,
    start_vertex: *Renderer.Vertex,
    end_vertex: *Renderer.Vertex,
    provoking_vertex: *Renderer.Vertex,
    start_step: usize,
    end_step: usize,
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
    has_fragment_shader: bool,
};

pub fn drawLine(
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    v0: *Renderer.Vertex,
    v1: *Renderer.Vertex,
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
) VkError!void {
    try drawLineWithEndpointMode(allocator, draw_call, v0, v1, color_attachment_access, depth_attachment_access, stencil_attachment_access, false);
}

pub fn drawLineIncludingEndpoint(
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    v0: *Renderer.Vertex,
    v1: *Renderer.Vertex,
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
) VkError!void {
    try drawLineWithEndpointMode(allocator, draw_call, v0, v1, color_attachment_access, depth_attachment_access, stencil_attachment_access, true);
}

fn drawLineWithEndpointMode(
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    v0: *Renderer.Vertex,
    v1: *Renderer.Vertex,
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
    include_last_endpoint: bool,
) VkError!void {
    if (depth_attachment_access != null) {
        try drawLineBresenham(
            allocator,
            draw_call,
            v0,
            v1,
            color_attachment_access,
            depth_attachment_access,
            stencil_attachment_access,
            include_last_endpoint,
        );
        return;
    }

    try drawLineDiamond(
        allocator,
        draw_call,
        v0,
        v1,
        color_attachment_access,
        depth_attachment_access,
        stencil_attachment_access,
        include_last_endpoint,
    );
}

fn drawLineBresenham(
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    v0: *Renderer.Vertex,
    v1: *Renderer.Vertex,
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
    include_last_endpoint: bool,
) VkError!void {
    const io = draw_call.renderer.device.interface.io();

    var x0: i32 = @intFromFloat(v0.position[0]);
    var y0: i32 = @intFromFloat(@floor(v0.position[1] - 0.5));
    var x1: i32 = @intFromFloat(v1.position[0]);
    var y1: i32 = @intFromFloat(@floor(v1.position[1] - 0.5));

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

    const d_err: i32 = @intCast(@abs(y1 - y0));
    const d_x = x1 - x0;
    const y_step: i32 = if (y0 > y1) -1 else 1;

    const pipeline = draw_call.renderer.state.pipeline orelse return;
    const fragment_stage = pipeline.stages.getPtr(.fragment);
    const runtimes_count = if (fragment_stage) |stage| stage.runtimes.len else 1;
    if (runtimes_count == 0)
        return;

    const step_count: usize = @intCast(if (include_last_endpoint) @max(d_x, 0) + 1 else @max(d_x, 1));
    const runs_count = @min(runtimes_count, step_count);
    const steps_per_run = @divTrunc(step_count + runs_count - 1, runs_count);

    var batch_id: usize = 0;
    for (0..runs_count) |run_index| {
        defer batch_id = @mod(batch_id + 1, runtimes_count);

        const start_step = run_index * steps_per_run;
        if (start_step >= step_count)
            continue;

        const end_step = @min(start_step + steps_per_run - 1, step_count - 1);

        const run_data: RunData = .{
            .allocator = allocator,
            .draw_call = draw_call,
            .batch_id = batch_id,
            .x0 = x0,
            .y0 = y0,
            .d_x = d_x,
            .d_err = d_err,
            .y_step = y_step,
            .steep = steep,
            .start_vertex = start_vertex,
            .end_vertex = end_vertex,
            .provoking_vertex = v0,
            .start_step = start_step,
            .end_step = end_step,
            .color_attachment_access = color_attachment_access,
            .depth_attachment_access = depth_attachment_access,
            .stencil_attachment_access = stencil_attachment_access,
            .has_fragment_shader = fragment_stage != null,
        };

        draw_call.rasterizer_wait_group.async(io, runWrapper, .{run_data});
    }

    draw_call.rasterizer_wait_group.await(io) catch return VkError.DeviceLost;
}

fn drawLineDiamond(
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    v0: *Renderer.Vertex,
    v1: *Renderer.Vertex,
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
    include_last_endpoint: bool,
) VkError!void {
    const pipeline = draw_call.renderer.state.pipeline orelse return;
    const fragment_stage = pipeline.stages.getPtr(.fragment);
    const has_fragment_shader = fragment_stage != null;
    const batch_id: usize = 0;

    const min_x: i32 = @intFromFloat(@floor(@min(v0.position[0], v1.position[0]) - 1.0));
    const max_x: i32 = @intFromFloat(@ceil(@max(v0.position[0], v1.position[0]) + 1.0));
    const min_y: i32 = @intFromFloat(@floor(@min(v0.position[1], v1.position[1]) - 1.0));
    const max_y: i32 = @intFromFloat(@ceil(@max(v0.position[1], v1.position[1]) + 1.0));

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            if (!common.scissorContainsPixel(draw_call.scissor, x, y))
                continue;

            const coverage = diamondCoverage(v0.position, v1.position, x, y, include_last_endpoint);
            const t = coverage orelse continue;
            const z = ((1.0 - t) * v0.position[2]) + (t * v1.position[2]);
            const frag_w = ((1.0 - t) / v0.position[3]) + (t / v1.position[3]);

            var fragment_result: fragment.InvocationResult = .{
                .outputs = std.mem.zeroes([spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(F32x4)]u8),
                .depth = null,
                .sample_mask = null,
            };
            if (has_fragment_shader) {
                fragment_result = fragment.shaderInvocation(
                    allocator,
                    draw_call,
                    batch_id,
                    zm.f32x4(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, z, frag_w),
                    null,
                    null,
                    true,
                    try common.interpolateLineOutputs(allocator, v0, v1, v0, t),
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
                @intCast(x),
                @intCast(y),
                fragment_result.depth orelse z,
                lineCoverageMaskFloat(
                    v0.position,
                    v1.position,
                    x,
                    y,
                    pipeline.interface.mode.graphics.multisample.rasterization_samples.toInt(),
                ),
                fragment_result.sample_mask,
                false,
            );
        }
    }
}

fn diamondCoverage(a: F32x4, b: F32x4, pixel_x: i32, pixel_y: i32, include_last_endpoint: bool) ?f32 {
    const cx = @as(f32, @floatFromInt(pixel_x)) + 0.5;
    const cy = @as(f32, @floatFromInt(pixel_y)) + 0.5;
    const clipped = clipSegmentToDiamond(a[0], a[1], b[0], b[1], cx, cy) orelse return null;
    if (!include_last_endpoint and a[3] == 1.0 and b[3] == 1.0 and clipped.min_t <= 0.0)
        return null;
    if (!include_last_endpoint and clipped.min_t >= 1.0)
        return null;
    return std.math.clamp((clipped.min_t + clipped.max_t) * 0.5, 0.0, 1.0);
}

fn clipSegmentToDiamond(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32) ?struct { min_t: f32, max_t: f32 } {
    var min_t: f32 = 0.0;
    var max_t: f32 = 1.0;
    const dx = bx - ax;
    const dy = by - ay;

    const normals = [_]struct { nx: f32, ny: f32 }{
        .{ .nx = 1.0, .ny = 1.0 },
        .{ .nx = 1.0, .ny = -1.0 },
        .{ .nx = -1.0, .ny = 1.0 },
        .{ .nx = -1.0, .ny = -1.0 },
    };

    for (normals) |normal| {
        const origin_distance = normal.nx * (ax - cx) + normal.ny * (ay - cy) - 0.5;
        const delta_distance = normal.nx * dx + normal.ny * dy;
        if (delta_distance == 0.0) {
            if (origin_distance > 0.0)
                return null;
            continue;
        }

        const t = -origin_distance / delta_distance;
        if (delta_distance > 0.0) {
            max_t = @min(max_t, t);
        } else {
            min_t = @max(min_t, t);
        }
        if (min_t > max_t)
            return null;
    }

    return .{ .min_t = min_t, .max_t = max_t };
}

fn lineCoverageMaskFloat(a: F32x4, b: F32x4, pixel_x: i32, pixel_y: i32, sample_count: usize) vk.SampleMask {
    if (sample_count <= 1)
        return 1;

    const ab_x = b[0] - a[0];
    const ab_y = b[1] - a[1];
    const ab_len2 = ab_x * ab_x + ab_y * ab_y;
    if (ab_len2 == 0.0)
        return 1;

    var mask: vk.SampleMask = 0;
    for (0..sample_count) |sample_index| {
        if (sample_index >= @bitSizeOf(vk.SampleMask))
            break;

        const sample_pos = standardSamplePosition(sample_count, sample_index);
        const sample_x = @as(f32, @floatFromInt(pixel_x)) + sample_pos.x;
        const sample_y = @as(f32, @floatFromInt(pixel_y)) + sample_pos.y;
        const ap_x = sample_x - a[0];
        const ap_y = sample_y - a[1];
        const t = std.math.clamp(((ap_x * ab_x) + (ap_y * ab_y)) / ab_len2, 0.0, 1.0);
        const closest_x = a[0] + ab_x * t;
        const closest_y = a[1] + ab_y * t;
        const dx = sample_x - closest_x;
        const dy = sample_y - closest_y;

        if (dx * dx + dy * dy <= 0.25) {
            const bit_index: u5 = @intCast(sample_index);
            mask |= @as(vk.SampleMask, 1) << bit_index;
        }
    }

    return if (mask == 0) 1 else mask;
}

fn bresenhamYAtStep(y0: i32, d_x: i32, d_err: i32, y_step: i32, step: usize) i32 {
    if (d_x == 0)
        return y0;

    const numerator = (@as(i64, @intCast(step)) * @as(i64, d_err)) + @as(i64, @divTrunc(d_x - 1, 2));
    const y_offset: i32 = @intCast(@divTrunc(numerator, @as(i64, d_x)));
    return y0 + (y_step * y_offset);
}

fn standardSamplePosition(sample_count: usize, sample_index: usize) struct { x: f32, y: f32 } {
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

fn lineCoverageMask(data: RunData, pixel_x: i32, pixel_y: i32, sample_count: usize) vk.SampleMask {
    if (sample_count <= 1)
        return 1;

    const a = data.start_vertex.position;
    const b = data.end_vertex.position;
    const ab_x = b[0] - a[0];
    const ab_y = b[1] - a[1];
    const ab_len2 = ab_x * ab_x + ab_y * ab_y;
    if (ab_len2 == 0.0)
        return 1;

    var mask: vk.SampleMask = 0;
    for (0..sample_count) |sample_index| {
        if (sample_index >= @bitSizeOf(vk.SampleMask))
            break;

        const sample_pos = standardSamplePosition(sample_count, sample_index);
        const sample_x = @as(f32, @floatFromInt(pixel_x)) + sample_pos.x;
        const sample_y = @as(f32, @floatFromInt(pixel_y)) + sample_pos.y;
        const ap_x = sample_x - a[0];
        const ap_y = sample_y - a[1];
        const t = std.math.clamp(((ap_x * ab_x) + (ap_y * ab_y)) / ab_len2, 0.0, 1.0);
        const closest_x = a[0] + ab_x * t;
        const closest_y = a[1] + ab_y * t;
        const dx = sample_x - closest_x;
        const dy = sample_y - closest_y;

        if (dx * dx + dy * dy <= 0.25) {
            const bit_index: u5 = @intCast(sample_index);
            mask |= @as(vk.SampleMask, 1) << bit_index;
        }
    }

    return if (mask == 0) 1 else mask;
}

fn runWrapper(data: RunData) void {
    @call(.always_inline, run, .{data}) catch |err| {
        std.log.scoped(.@"Rasterization stage").err("line fill mode catched a '{s}'", .{@errorName(err)});
        if (comptime base.config.logs == .verbose) {
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
        }
    };
}

inline fn run(data: RunData) !void {
    var step = data.start_step;
    while (step <= data.end_step) : (step += 1) {
        const x = data.x0 + @as(i32, @intCast(step));
        const y = bresenhamYAtStep(data.y0, data.d_x, data.d_err, data.y_step, step);

        const pixel_x = if (data.steep) y else x;
        const pixel_y = if (data.steep) x else y;

        if (!common.scissorContainsPixel(data.draw_call.scissor, pixel_x, pixel_y)) {
            continue;
        }

        const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(@max(data.d_x, 1)));
        const z = ((1.0 - t) * data.start_vertex.position[2]) + (t * data.end_vertex.position[2]);
        const frag_w = ((1.0 - t) / data.start_vertex.position[3]) + (t / data.end_vertex.position[3]);

        var fragment_result: fragment.InvocationResult = .{
            .outputs = std.mem.zeroes([spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(F32x4)]u8),
            .depth = null,
            .sample_mask = null,
        };
        if (data.has_fragment_shader) {
            fragment_result = fragment.shaderInvocation(
                data.allocator,
                data.draw_call,
                data.batch_id,
                zm.f32x4(@as(f32, @floatFromInt(pixel_x)) + 0.5, @as(f32, @floatFromInt(pixel_y)) + 0.5, z, frag_w),
                null,
                null,
                true,
                try common.interpolateLineOutputs(data.allocator, data.start_vertex, data.end_vertex, data.provoking_vertex, t),
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
            data.draw_call,
            data.color_attachment_access,
            data.depth_attachment_access,
            data.stencil_attachment_access,
            true,
            @intCast(pixel_x),
            @intCast(pixel_y),
            fragment_result.depth orelse z,
            lineCoverageMask(
                data,
                pixel_x,
                pixel_y,
                data.draw_call.renderer.state.pipeline.?.interface.mode.graphics.multisample.rasterization_samples.toInt(),
            ),
            fragment_result.sample_mask,
            false,
        );
    }
}
