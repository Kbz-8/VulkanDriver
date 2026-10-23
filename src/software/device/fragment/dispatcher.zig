const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;
const shader_types = @import("../../shader_types.zig");

const rasterizer = @import("../rasterizer/common.zig");
const Renderer = @import("../Renderer.zig");
const interpreter_simd = @import("../../interpreter/simd.zig");
const backend = @import("ir_interpreter.zig");

pub const RuntimeError = error{
    InvalidShader,
    OutOfMemory,
    OutOfBounds,
    Unknown,
    Killed,
};
pub const InvocationResult = struct {
    outputs: [shader_types.max_output_locations][@sizeOf(zm.F32x4)]u8,
    depth: ?f32,
    sample_mask: ?vk.SampleMask,
};

pub const FragmentInputs = rasterizer.FragmentInputs;

pub const DerivativeInputs = struct {
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
    if (worker.program.uses_derivatives)
        return .{ .quad_inputs = @splat(inputs), .quad_positions = quadPositions(position), .quad_lane = quadLane(position) };
    return null;
}

pub const WaveInvocation = backend.WaveInvocation;
pub const WaveResult = backend.WaveResult;
pub const Worker = backend.Worker;

pub fn prepareDraw(allocator: std.mem.Allocator, draw_call: *Renderer.DrawCall) base.VkError!void {
    try backend.prepareDraw(allocator, draw_call);
}

pub fn finishDraw(allocator: std.mem.Allocator, draw_call: *Renderer.DrawCall) void {
    backend.finishDraw(allocator, draw_call);
}

pub fn acquireWorker(draw_call: *Renderer.DrawCall, batch_id: usize) base.VkError!Worker {
    return backend.acquireWorker(draw_call, batch_id);
}

pub inline fn shaderWave(worker: *Worker, invocations: *const [interpreter_simd.lane_count]WaveInvocation, mask: interpreter_simd.LaneMask) RuntimeError!WaveResult {
    return backend.shaderWave(worker, invocations, mask);
}

pub inline fn shaderWaveMasked(worker: *Worker, invocations: *const [interpreter_simd.lane_count]WaveInvocation, execution_mask: interpreter_simd.LaneMask, observable_mask: interpreter_simd.LaneMask) RuntimeError!WaveResult {
    return backend.shaderWaveMasked(worker, invocations, execution_mask, observable_mask);
}

pub inline fn shaderInvocation(
    worker: *Worker,
    position: zm.F32x4,
    point_coord: ?@Vector(2, f32),
    sample_id: ?u32,
    front_face: bool,
    inputs: FragmentInputs,
    derivative_inputs: ?DerivativeInputs,
) RuntimeError!InvocationResult {
    return backend.shaderInvocation(worker, position, point_coord, sample_id, front_face, inputs, derivative_inputs);
}
