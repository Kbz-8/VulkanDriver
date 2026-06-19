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
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
    front_face: bool,
    has_fragment_shader: bool,
    fragment_uses_derivatives: bool,
};

pub fn drawTriangle(
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    v0: *Renderer.Vertex,
    v1: *Renderer.Vertex,
    v2: *Renderer.Vertex,
    color_attachment_access: []const ?common.RenderTargetAccess,
    depth_attachment_access: ?*common.RenderTargetAccess,
    stencil_attachment_access: ?*common.RenderTargetAccess,
    front_face: bool,
) VkError!void {
    const io = draw_call.renderer.device.interface.io();

    const min_x: i32 = @intFromFloat(@floor(@min(v0.position[0], v1.position[0], v2.position[0])));
    const max_x: i32 = @intFromFloat(@ceil(@max(v0.position[0], v1.position[0], v2.position[0])));
    const min_y: i32 = @intFromFloat(@floor(@min(v0.position[1], v1.position[1], v2.position[1])));
    const max_y: i32 = @intFromFloat(@ceil(@max(v0.position[1], v1.position[1], v2.position[1])));

    const area = edgeFunction(v0.position, v1.position, v2.position);
    if (area == 0.0)
        return;

    const pipeline = draw_call.renderer.state.pipeline orelse return;
    const fragment_stage = pipeline.stages.getPtr(.fragment);
    const fragment_uses_derivatives = if (fragment_stage) |stage|
        stage.module.module.reflection_infos.needs_derivatives
    else
        false;

    const runtimes_count = if (fragment_stage) |stage| stage.runtimes.len else 1;
    if (runtimes_count == 0)
        return;
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
                .fragment_uses_derivatives = fragment_uses_derivatives,
            };

            draw_call.rasterizer_wait_group.async(io, runWrapper, .{run_data});
        }
    }

    draw_call.rasterizer_wait_group.await(io) catch return VkError.DeviceLost;
}

inline fn edgeFunction(a: F32x4, b: F32x4, p: F32x4) f32 {
    return ((p[0] - a[0]) * (b[1] - a[1])) - ((p[1] - a[1]) * (b[0] - a[0]));
}

inline fn isInclusiveEdge(a: F32x4, b: F32x4) bool {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    return dy < 0.0 or (dy == 0.0 and dx > 0.0);
}

inline fn edgeContainsPixel(a: F32x4, b: F32x4, edge_value: f32, area: f32) bool {
    return if (area > 0.0)
        edge_value > 0.0 or (edge_value == 0.0 and isInclusiveEdge(a, b))
    else
        edge_value < 0.0 or (edge_value == 0.0 and isInclusiveEdge(b, a));
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
            if (!common.scissorContainsPixel(data.draw_call.scissor, x, y)) {
                continue;
            }

            const p = zm.f32x4(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, 0.0, 1.0);

            const w0 = edgeFunction(data.v1.position, data.v2.position, p);
            const w1 = edgeFunction(data.v2.position, data.v0.position, p);
            const w2 = edgeFunction(data.v0.position, data.v1.position, p);

            const inside =
                edgeContainsPixel(data.v1.position, data.v2.position, w0, data.area) and
                edgeContainsPixel(data.v2.position, data.v0.position, w1, data.area) and
                edgeContainsPixel(data.v0.position, data.v1.position, w2, data.area);

            if (!inside)
                continue;

            const b0 = w0 / data.area;
            const b1 = w1 / data.area;
            const b2 = w2 / data.area;
            const z = (b0 * data.v0.position[2]) + (b1 * data.v1.position[2]) + (b2 * data.v2.position[2]);
            const frag_w = (b0 / data.v0.position[3]) + (b1 / data.v1.position[3]) + (b2 / data.v2.position[3]);

            var fragment_result: fragment.InvocationResult = .{
                .outputs = std.mem.zeroes([spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(F32x4)]u8),
                .depth = null,
            };
            if (data.has_fragment_shader) {
                const inputs = try common.interpolateVertexOutputs(data.allocator, &data.v0, &data.v1, &data.v2, b0, b1, b2);
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
                    zm.f32x4(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, z, frag_w),
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
                fragment_result.depth orelse z,
            );
        }
    }
}
