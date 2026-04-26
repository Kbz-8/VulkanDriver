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
        rt.callEntryPoint(allocator, entry) catch |err| switch (err) {
            // Some errors can be safely ignored
            SpvRuntimeError.OutOfBounds,
            SpvRuntimeError.Killed,
            => {},
            else => return err,
        };

        const output: *F32x4 = &data.draw_call.fragments[invocation_index].color;
        try rt.readOutput(std.mem.asBytes(output), output_result);
        output.* = std.math.clamp(output.*, zm.f32x4s(0.0), zm.f32x4s(1.0));
    }
}
