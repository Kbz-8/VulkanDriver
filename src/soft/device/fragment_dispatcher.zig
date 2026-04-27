const std = @import("std");
const spv = @import("spv");
const base = @import("base");
const zm = base.zm;

const F32x4 = Renderer.F32x4;

const SpvRuntimeError = spv.Runtime.RuntimeError;

const Renderer = @import("Renderer.zig");
const SoftPipeline = @import("../SoftPipeline.zig");

const VkError = base.VkError;

pub const RunData = struct {
    renderer: *Renderer,
    pipeline: *SoftPipeline,
    batch_id: usize,
    batch_size: usize,
    fragment_count: usize,
    draw_call: *Renderer.DrawCall,
};

pub fn runWrapper(data: RunData) void {
    @call(.always_inline, run, .{data}) catch |err| {
        std.log.scoped(.@"SPIR-V runtime").err("SPIR-V runtime catched a '{s}'", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(trace);
        }
    };
}

inline fn run(data: RunData) !void {
    const allocator = data.renderer.device.device_allocator.allocator();

    const shader = data.pipeline.stages.getPtrAssertContains(.fragment);
    const rt = &shader.runtimes[data.batch_id];

    const entry = try rt.getEntryPointByName(shader.entry);
    const output_result = try rt.getResultByLocation(0, .output);

    var invocation_index: usize = data.batch_id;
    while (invocation_index < data.fragment_count) : (invocation_index += data.batch_size) {
        const fragment: *Renderer.Fragment = &data.draw_call.fragments[invocation_index];

        for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
            const result_word = rt.getResultByLocation(@intCast(location), .input) catch |err| switch (err) {
                SpvRuntimeError.NotFound => continue,
                else => return err,
            };
            if (result_word != 0) {
                try rt.writeInput(fragment.inputs[location], result_word);
            }
        }

        rt.callEntryPoint(allocator, entry) catch |err| switch (err) {
            // Some errors can be safely ignored
            SpvRuntimeError.OutOfBounds,
            SpvRuntimeError.Killed,
            => {},
            else => return err,
        };

        try rt.readOutput(std.mem.asBytes(&fragment.color), output_result);
        fragment.color = std.math.clamp(fragment.color, zm.f32x4s(0.0), zm.f32x4s(1.0));
    }
}
