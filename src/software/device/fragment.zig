const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;
const spv = @import("spv");

const VertexInterpolationLocation = @import("rasterizer/common.zig").VertexInterpolationLocation;
const Renderer = @import("Renderer.zig");
const backend = if (base.config.soft_ir_interpreter)
    @import("fragment/ir_interpreter.zig")
else
    @import("fragment/spirv_interpreter.zig");

pub const SpvRuntimeError = spv.Runtime.RuntimeError;
pub const InvocationResult = struct {
    outputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(zm.F32x4)]u8,
    depth: ?f32,
    sample_mask: ?vk.SampleMask,
};

pub const DerivativeInputs = struct {
    dx: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation,
    dy: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation,
};

pub inline fn shaderInvocation(
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    batch_id: usize,
    position: zm.F32x4,
    point_coord: ?@Vector(2, f32),
    sample_id: ?u32,
    front_face: bool,
    inputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation,
    derivative_inputs: ?DerivativeInputs,
) SpvRuntimeError!InvocationResult {
    return backend.shaderInvocation(allocator, draw_call, batch_id, position, point_coord, sample_id, front_face, inputs, derivative_inputs);
}

pub fn freeOwnedInputs(allocator: std.mem.Allocator, inputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation) void {
    for (inputs) |location| {
        for (location) |input| {
            if (input.free_responsability)
                allocator.free(input.blob);
        }
    }
}
