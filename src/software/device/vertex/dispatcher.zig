const std = @import("std");
const base = @import("base");

const Renderer = @import("../Renderer.zig");
const SoftPipeline = @import("../../SoftPipeline.zig");

const backend = @import("ir_interpreter.zig");

pub const batch_width = @import("../../interpreter/Runtime.zig").lane_count;

pub const RunData = struct {
    allocator: std.mem.Allocator,
    pipeline: *SoftPipeline,
    batch_id: usize,
    batch_size: usize,
    vertex_count: usize,
    invocation_indices: ?[]const usize = null,
    first_vertex: usize,
    first_instance: usize,
    indices: ?[]const u32,
    primitive_restart: ?[]const bool,
    instance_index: usize,
    draw_call: *Renderer.DrawCall,
};

pub fn runInline(data: RunData) base.VkError!void {
    return backend.run(data);
}

pub fn runWrapper(data: RunData) void {
    @call(.always_inline, backend.run, .{data}) catch |err| {
        std.log.scoped(.VertexDispatcher).err("IR interpreter runtime caught a '{s}'", .{@errorName(err)});
        if (comptime base.config.logs == .verbose) {
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
        }
    };
}
