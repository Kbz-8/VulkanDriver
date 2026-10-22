const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;
const spv = @import("spv");

const rasterizer = @import("../rasterizer/common.zig");
const Renderer = @import("../Renderer.zig");
const interpreter_simd = @import("../../interpreter/simd.zig");
const backend = if (base.config.soft_ir_interpreter)
    @import("ir_interpreter.zig")
else
    @import("spirv_interpreter.zig");

pub const SpvRuntimeError = spv.Runtime.RuntimeError;
pub const InvocationResult = struct {
    outputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(zm.F32x4)]u8,
    depth: ?f32,
    sample_mask: ?vk.SampleMask,
};

pub const FragmentInputs = rasterizer.FragmentInputs;

pub const DerivativeInputs = struct {
    dx: FragmentInputs,
    dy: FragmentInputs,
    // IR helpers carry actual interpolated values, not input-space derivatives.
    quad_inputs: ?[4]FragmentInputs = null,
    quad_positions: ?[4]zm.F32x4 = null,
    quad_lane: u2 = 0,
};

pub fn quadPositions(position: zm.F32x4) [4]zm.F32x4 {
    const x: i32 = @intFromFloat(@floor(position[0]));
    const y: i32 = @intFromFloat(@floor(position[1]));
    var positions: [4]zm.F32x4 = undefined;
    for (&positions, 0..) |*helper, lane| {
        helper.* = position;
        helper.*[0] = @as(f32, @floatFromInt((x & ~@as(i32, 1)) + @as(i32, @intCast(lane & 1)))) + 0.5;
        helper.*[1] = @as(f32, @floatFromInt((y & ~@as(i32, 1)) + @as(i32, @intCast(lane >> 1)))) + 0.5;
    }
    return positions;
}

pub fn quadLane(position: zm.F32x4) u2 {
    const x: i32 = @intFromFloat(@floor(position[0]));
    const y: i32 = @intFromFloat(@floor(position[1]));
    return @intCast((x & 1) | ((y & 1) << 1));
}

pub fn constantQuadHelpers(worker: *const Worker, position: zm.F32x4, inputs: FragmentInputs) ?DerivativeInputs {
    if (comptime base.config.soft_ir_interpreter) {
        if (worker.program.uses_derivatives)
            return .{ .dx = inputs, .dy = inputs, .quad_inputs = @splat(inputs), .quad_positions = quadPositions(position), .quad_lane = quadLane(position) };
    }
    return null;
}

pub const WaveInvocation = if (base.config.soft_ir_interpreter) backend.WaveInvocation else void;
pub const WaveResult = if (base.config.soft_ir_interpreter) backend.WaveResult else void;

pub fn prepareDraw(allocator: std.mem.Allocator, draw_call: *Renderer.DrawCall) base.VkError!void {
    if (comptime base.config.soft_ir_interpreter)
        try backend.prepareDraw(allocator, draw_call);
}

pub fn finishDraw(allocator: std.mem.Allocator, draw_call: *Renderer.DrawCall) void {
    if (comptime base.config.soft_ir_interpreter)
        backend.finishDraw(allocator, draw_call);
}

pub const Worker = if (base.config.soft_ir_interpreter)
    backend.Worker
else
    struct {
        draw_call: *Renderer.DrawCall,
        batch_id: usize,

        pub fn release(_: *@This()) void {}
    };

pub fn acquireWorker(draw_call: *Renderer.DrawCall, batch_id: usize) base.VkError!Worker {
    if (comptime base.config.soft_ir_interpreter)
        return backend.acquireWorker(draw_call, batch_id);
    return .{ .draw_call = draw_call, .batch_id = batch_id };
}

pub inline fn shaderWave(worker: *Worker, invocations: *const [interpreter_simd.lane_count]WaveInvocation, mask: interpreter_simd.LaneMask) SpvRuntimeError!WaveResult {
    if (comptime base.config.soft_ir_interpreter)
        return backend.shaderWave(worker, invocations, mask);
    unreachable;
}

pub inline fn shaderWaveMasked(worker: *Worker, invocations: *const [interpreter_simd.lane_count]WaveInvocation, execution_mask: interpreter_simd.LaneMask, observable_mask: interpreter_simd.LaneMask) SpvRuntimeError!WaveResult {
    if (comptime base.config.soft_ir_interpreter)
        return backend.shaderWaveMasked(worker, invocations, execution_mask, observable_mask);
    unreachable;
}

pub inline fn shaderInvocation(
    worker: *Worker,
    allocator: std.mem.Allocator,
    position: zm.F32x4,
    point_coord: ?@Vector(2, f32),
    sample_id: ?u32,
    front_face: bool,
    inputs: FragmentInputs,
    derivative_inputs: ?DerivativeInputs,
) SpvRuntimeError!InvocationResult {
    if (comptime base.config.soft_ir_interpreter) {
        return backend.shaderInvocation(worker, position, point_coord, sample_id, front_face, inputs, derivative_inputs);
    }
    return backend.shaderInvocation(allocator, worker.draw_call, worker.batch_id, position, point_coord, sample_id, front_face, inputs, derivative_inputs);
}

pub fn freeOwnedInputs(allocator: std.mem.Allocator, inputs: FragmentInputs) void {
    if (comptime base.config.soft_ir_interpreter) {
        return;
    } else {
        for (inputs) |location| {
            for (location) |input| {
                if (input.free_responsability)
                    allocator.free(input.blob);
            }
        }
    }
}
