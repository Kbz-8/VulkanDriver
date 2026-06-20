const std = @import("std");
const base = @import("base");
const spv = @import("spv");
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

    const step_count: usize = if (d_x == 0) 1 else @intCast(d_x);
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

fn bresenhamYAtStep(y0: i32, d_x: i32, d_err: i32, y_step: i32, step: usize) i32 {
    if (d_x == 0)
        return y0;

    const numerator = (@as(i64, @intCast(step)) * @as(i64, d_err)) + @as(i64, @divTrunc(d_x - 1, 2));
    const y_offset: i32 = @intCast(@divTrunc(numerator, @as(i64, d_x)));
    return y0 + (y_step * y_offset);
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
                true,
                try common.interpolateLineOutputs(data.allocator, data.start_vertex, data.end_vertex, t),
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
            fragment_result.sample_mask,
        );
    }
}
