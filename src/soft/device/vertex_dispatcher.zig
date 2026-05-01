const std = @import("std");
const spv = @import("spv");
const base = @import("base");

const F32x4 = Renderer.F32x4;

const SpvRuntimeError = spv.Runtime.RuntimeError;

const Renderer = @import("Renderer.zig");
const SoftPipeline = @import("../SoftPipeline.zig");

const VkError = base.VkError;

pub const RunData = struct {
    allocator: std.mem.Allocator,
    renderer: *Renderer,
    pipeline: *SoftPipeline,
    batch_id: usize,
    batch_size: usize,
    vertex_count: usize,
    first_vertex: usize,
    first_instance: usize,
    indices: ?[]const i32,
    instance_index: usize,
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

    const shader = data.pipeline.stages.getPtrAssertContains(.vertex);
    const rt = &shader.runtimes[data.batch_id];

    const entry = try rt.getEntryPointByName(shader.entry);

    var invocation_index: usize = data.batch_id;
    while (invocation_index < data.vertex_count) : (invocation_index += data.batch_size) {
        const vertex_index: usize = if (data.indices) |indices| @intCast(indices[invocation_index]) else data.first_vertex + invocation_index;
        const instance_index = data.first_instance + data.instance_index;

        setupBuiltins(rt, vertex_index, instance_index) catch |err| switch (err) {
            SpvRuntimeError.NotFound => {},
            else => return err,
        };

        if (data.pipeline.interface.mode.graphics.input_assembly.attribute_description) |attributes| {
            for (attributes) |attribute| {
                const location_result = try rt.getResultByLocation(attribute.location, .input);

                const binding_info = (data.pipeline.interface.mode.graphics.input_assembly.binding_description orelse return)[attribute.binding];

                const vertex_buffer = data.renderer.state.data.graphics.vertex_buffers[attribute.binding];
                const buffer = vertex_buffer.buffer;
                const buffer_memory_size = base.format.texelSize(attribute.format);
                const buffer_memory = if (buffer.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
                const offset = buffer.interface.offset + vertex_buffer.offset + (binding_info.stride * vertex_index) + attribute.offset;

                const buffer_memory_map: []u8 = @as([*]u8, @ptrCast(@alignCast(try buffer_memory.map(offset, buffer_memory_size))))[0..buffer_memory_size];

                try rt.writeInput(buffer_memory_map, location_result);
            }
        }

        rt.callEntryPoint(allocator, entry) catch |err| switch (err) {
            // Some errors can be safely ignored
            SpvRuntimeError.OutOfBounds,
            SpvRuntimeError.Killed,
            => {},
            else => return err,
        };

        const output: *Renderer.Vertex = &data.draw_call.vertices[(data.instance_index * data.vertex_count) + invocation_index];
        try rt.readBuiltIn(std.mem.asBytes(&output.position), .Position);

        for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
            const result_word = rt.getResultByLocation(@intCast(location), .output) catch |err| switch (err) {
                SpvRuntimeError.NotFound => continue,
                else => return err,
            };
            output.outputs[location] = .{
                .interpolation_type = if (rt.hasResultDecoration(result_word, .Flat)) .flat else .smooth, // TODO : handle noperspective
                .blob = data.allocator.alloc(u8, try rt.getResultMemorySize(result_word)) catch return VkError.OutOfDeviceMemory,
            };
            try rt.readOutput(output.outputs[location].?.blob, result_word);
        }
    }
}

fn setupBuiltins(rt: *spv.Runtime, vertex_index: usize, instance_index: usize) !void {
    try rt.writeBuiltIn(std.mem.asBytes(&vertex_index), .VertexIndex);
    try rt.writeBuiltIn(std.mem.asBytes(&instance_index), .InstanceIndex);
}
