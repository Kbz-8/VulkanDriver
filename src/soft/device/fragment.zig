const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;
const spv = @import("spv");

const VertexInterpolation = @import("rasterizer/common.zig").VertexInterpolation;

const Renderer = @import("Renderer.zig");
const SoftImage = @import("../SoftImage.zig");

const VkError = base.VkError;
const SpvRuntimeError = spv.Runtime.RuntimeError;

pub fn shaderInvocation(
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    batch_id: usize,
    position: zm.F32x4,
    inputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolation,
) SpvRuntimeError![spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(zm.F32x4)]u8 {
    const io = draw_call.renderer.device.interface.io();

    _ = position;
    const pipeline = draw_call.renderer.state.pipeline orelse return undefined;

    const shader = pipeline.stages.getPtr(.fragment) orelse return undefined;
    const runtime = &shader.runtimes[batch_id];
    const mutex = &runtime.mutex;
    const rt = &runtime.rt;

    mutex.lock(io) catch return SpvRuntimeError.Unknown;
    defer mutex.unlock(io);

    try rt.populatePushConstants(draw_call.renderer.state.push_constant_blob[0..]);

    const entry = try rt.getEntryPointByName(shader.entry);

    for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
        const result_word = rt.getResultByLocation(@intCast(location), .input) catch |err| switch (err) {
            SpvRuntimeError.NotFound => continue,
            else => return err,
        };
        try rt.writeInput(inputs[location].blob, result_word);
        if (inputs[location].free_responsability)
            allocator.free(inputs[location].blob);
    }

    rt.callEntryPoint(allocator, entry) catch |err| switch (err) {
        // Some errors can be safely ignored
        SpvRuntimeError.OutOfBounds,
        SpvRuntimeError.Killed,
        => {},
        else => return err,
    };

    var outputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(zm.F32x4)]u8 = undefined;
    @memset(std.mem.asBytes(&outputs), 0);

    for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
        const result_word = rt.getResultByLocation(@intCast(location), .output) catch |err| switch (err) {
            SpvRuntimeError.NotFound => continue,
            else => return err,
        };
        try rt.readOutput(&outputs[location], result_word);
    }

    try rt.flushDescriptorSets(allocator);

    return outputs;
}
