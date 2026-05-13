const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;
const spv = @import("spv");

const lib = @import("../lib.zig");

const Renderer = @import("Renderer.zig");
const SoftImage = @import("../SoftImage.zig");

const VkError = base.VkError;
const SpvRuntimeError = spv.Runtime.RuntimeError;

pub fn shaderInvocation(allocator: std.mem.Allocator, draw_call: *Renderer.DrawCall, batch_id: usize, position: zm.F32x4, inputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS][]const u8) SpvRuntimeError!zm.F32x4 {
    _ = position;
    const pipeline = draw_call.renderer.state.pipeline orelse return zm.f32x4s(0.0);

    const shader = pipeline.stages.getPtrAssertContains(.fragment);
    const rt = &shader.runtimes[batch_id];

    const entry = try rt.getEntryPointByName(shader.entry);
    const output_result = try rt.getResultByLocation(0, .output);

    for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
        const result_word = rt.getResultByLocation(@intCast(location), .input) catch |err| switch (err) {
            SpvRuntimeError.NotFound => continue,
            else => return err,
        };
        try rt.writeInput(inputs[location], result_word);
        allocator.free(inputs[location]);
    }

    rt.callEntryPoint(allocator, entry) catch |err| switch (err) {
        // Some errors can be safely ignored
        SpvRuntimeError.OutOfBounds,
        SpvRuntimeError.Killed,
        => {},
        else => return err,
    };

    var color = zm.f32x4s(0.0);
    try rt.readOutput(std.mem.asBytes(&color), output_result);
    return std.math.clamp(color, zm.f32x4s(0.0), zm.f32x4s(1.0));
}
