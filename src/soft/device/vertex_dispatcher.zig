const std = @import("std");
const spv = @import("spv");
const base = @import("base");
const vk = @import("vulkan");

const F32x4 = base.zm.F32x4;

const SpvRuntimeError = spv.Runtime.RuntimeError;

const Renderer = @import("Renderer.zig");
const SoftPipeline = @import("../SoftPipeline.zig");

const VkError = base.VkError;
const INTERFACE_BLOB_PADDING = @sizeOf(F32x4);

pub const RunData = struct {
    allocator: std.mem.Allocator,
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
        if (comptime base.config.logs == .verbose) {
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
        }
    };
}

inline fn run(data: RunData) !void {
    const shader = data.pipeline.stages.getPtrAssertContains(.vertex);
    const rt = &shader.runtimes[data.batch_id].rt;

    const entry = try rt.getEntryPointByName(shader.entry);

    var invocation_index: usize = data.batch_id;
    while (invocation_index < data.vertex_count) : (invocation_index += data.batch_size) {
        rt.resetInvocation(data.allocator);
        try rt.populatePushConstants(data.draw_call.renderer.state.push_constant_blob[0..]);

        const vertex_index: usize = if (data.indices) |indices| @intCast(indices[invocation_index]) else data.first_vertex + invocation_index;
        const instance_index = data.first_instance + data.instance_index;

        setupBuiltins(rt, vertex_index, instance_index) catch |err| switch (err) {
            SpvRuntimeError.NotFound => {},
            else => return err,
        };

        if (data.pipeline.interface.mode.graphics.input_assembly.attribute_description) |attributes| {
            for (attributes) |attribute| {
                const binding_info = (data.pipeline.interface.mode.graphics.input_assembly.binding_description orelse return)[attribute.binding];

                const vertex_buffer = data.draw_call.renderer.state.data.graphics.vertex_buffers[attribute.binding];
                const buffer = vertex_buffer.buffer;
                const buffer_memory_size = base.format.texelSize(attribute.format);
                const buffer_memory = if (buffer.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
                const offset = buffer.interface.offset + vertex_buffer.offset + (binding_info.stride * vertex_index) + attribute.offset;

                const buffer_memory_map: []u8 = try buffer_memory.map(offset, buffer_memory_size);

                try writeVertexInput(rt, data.allocator, buffer_memory_map, attribute.format, attribute.location);
            }
        }

        rt.callEntryPoint(data.allocator, entry) catch |err| switch (err) {
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
            const memory_size = try rt.getResultMemorySize(result_word);
            output.outputs[location] = .{
                .interpolation_type = if (rt.hasResultDecoration(result_word, .Flat)) .flat else .smooth, // TODO : handle noperspective
                .blob = data.allocator.alloc(u8, memory_size + INTERFACE_BLOB_PADDING) catch return VkError.OutOfDeviceMemory,
                .size = memory_size,
            };
            @memset(output.outputs[location].?.blob, 0);
            try rt.readOutput(output.outputs[location].?.blob, result_word);
        }

        try rt.flushDescriptorSets(data.allocator);
    }
}

fn setupBuiltins(rt: *spv.Runtime, vertex_index: usize, instance_index: usize) !void {
    const vertex_index_u32: u32 = @intCast(vertex_index);
    const instance_index_u32: u32 = @intCast(instance_index);

    try rt.writeBuiltIn(std.mem.asBytes(&vertex_index_u32), .VertexIndex);
    try rt.writeBuiltIn(std.mem.asBytes(&instance_index_u32), .InstanceIndex);
}

fn writeVertexInput(
    rt: *spv.Runtime,
    allocator: std.mem.Allocator,
    raw_input: []const u8,
    format: vk.Format,
    location: u32,
) !void {
    const input_memory_size = try rt.getInputLocationMemorySize(location);

    if (raw_input.len >= input_memory_size) {
        try rt.writeInputLocation(raw_input[0..input_memory_size], location);
        return;
    }

    const input = allocator.alloc(u8, input_memory_size) catch return VkError.OutOfDeviceMemory;
    defer allocator.free(input);

    @memset(input, 0);
    @memcpy(input[0..raw_input.len], raw_input);

    fillMissingVertexComponents(input, raw_input.len, format);
    try rt.writeInputLocation(input, location);
}

fn fillMissingVertexComponents(input: []u8, raw_input_size: usize, format: vk.Format) void {
    if (input.len < @sizeOf(F32x4) or raw_input_size > 3 * @sizeOf(f32))
        return;

    const component_count = base.format.componentCount(format);
    if (component_count >= 4)
        return;

    const alpha_offset = 3 * @sizeOf(f32);
    if (base.format.isUnnormalizedInteger(format)) {
        const one: u32 = 1;
        @memcpy(input[alpha_offset .. alpha_offset + @sizeOf(u32)], std.mem.asBytes(&one));
    } else {
        const one: f32 = 1.0;
        @memcpy(input[alpha_offset .. alpha_offset + @sizeOf(f32)], std.mem.asBytes(&one));
    }
}
