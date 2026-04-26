const std = @import("std");
const spv = @import("spv");

const SpvRuntimeError = spv.Runtime.RuntimeError;

const Renderer = @import("Renderer.zig");
const SoftPipeline = @import("../SoftPipeline.zig");

pub const RunData = struct {
    renderer: *Renderer,
    pipeline: *SoftPipeline,
    batch_id: usize,
    batch_size: usize,
    invocation_count: usize,
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

    const shader = data.pipeline.stages.getPtrAssertContains(.vertex);
    const rt = &shader.runtimes[data.batch_id];

    const entry = try rt.getEntryPointByName(shader.entry);

    var invocation_index: usize = data.batch_id;
    while (invocation_index < data.invocation_count) : (invocation_index += data.batch_size) {
        rt.callEntryPoint(allocator, entry) catch |err| switch (err) {
            // Some errors can be ignored
            SpvRuntimeError.OutOfBounds,
            SpvRuntimeError.Killed,
            => {},
            else => return err,
        };

        var output: [4]f32 = undefined;
        try rt.readBuiltIn(std.mem.asBytes(output[0..output.len]), .Position);
        std.debug.print("Output: Vec4{any}\n", .{output});
    }
}
