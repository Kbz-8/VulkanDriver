const std = @import("std");
const base = @import("base");

const Renderer = @import("Renderer.zig");
const SoftPipeline = @import("../SoftPipeline.zig");
const backend = if (base.config.soft_ir_interpreter)
    @import("vertex/ir_interpreter.zig")
else
    @import("vertex/spirv_interpreter.zig");

pub const RunData = struct {
    allocator: std.mem.Allocator,
    pipeline: *SoftPipeline,
    batch_id: usize,
    batch_size: usize,
    vertex_count: usize,
    first_vertex: usize,
    first_instance: usize,
    indices: ?[]const u32,
    primitive_restart: ?[]const bool,
    instance_index: usize,
    draw_call: *Renderer.DrawCall,
};

pub fn runWrapper(data: RunData) void {
    @call(.always_inline, backend.run, .{data}) catch |err| {
        std.log.scoped(.VertexDispatcher).err("{s} interpreter runtime caught a '{s}'", .{
            if (comptime base.config.soft_ir_interpreter) "IR" else "SPIR-V",
            @errorName(err),
        });
        if (comptime base.config.logs == .verbose) {
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
        }
    };
}
