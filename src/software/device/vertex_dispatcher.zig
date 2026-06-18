const std = @import("std");
const spv = @import("spv");
const base = @import("base");
const vk = @import("vulkan");

const F32x4 = base.zm.F32x4;

const SpvRuntimeError = spv.Runtime.RuntimeError;

const Renderer = @import("Renderer.zig");
const SoftPipeline = @import("../SoftPipeline.zig");
const blitter = @import("blitter.zig");

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
    indices: ?[]const u32,
    primitive_restart: ?[]const bool,
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
    const runtime = &shader.runtimes[data.batch_id];
    const mutex = &runtime.mutex;
    const rt = &runtime.rt;

    const io = data.draw_call.renderer.device.interface.io();
    mutex.lock(io) catch return VkError.DeviceLost;
    defer mutex.unlock(io);

    const entry = try rt.getEntryPointByName(shader.entry);

    var invocation_index: usize = data.batch_id;
    while (invocation_index < data.vertex_count) : (invocation_index += data.batch_size) {
        const output: *Renderer.Vertex = &data.draw_call.vertices[(data.instance_index * data.vertex_count) + invocation_index];
        if (data.primitive_restart) |primitive_restart| {
            if (primitive_restart[invocation_index]) {
                output.primitive_restart = true;
                continue;
            }
        }

        rt.resetInvocation(data.allocator);
        try rt.populatePushConstants(data.draw_call.renderer.state.push_constant_blob[0..]);

        const vertex_index_u32: u32 = if (data.indices) |indices| indices[invocation_index] else @intCast(data.first_vertex + invocation_index);
        const vertex_index: usize = vertex_index_u32;
        const instance_index = data.first_instance + data.instance_index;

        setupBuiltins(rt, vertex_index_u32, instance_index) catch |err| switch (err) {
            SpvRuntimeError.NotFound => {},
            else => return err,
        };

        if (data.pipeline.interface.mode.graphics.input_assembly.attribute_description) |attributes| {
            for (attributes) |attribute| {
                const binding_info = findBindingDescription(
                    data.pipeline.interface.mode.graphics.input_assembly.binding_description orelse return,
                    attribute.binding,
                ) orelse return VkError.ValidationFailed;

                const vertex_buffer = data.draw_call.renderer.state.data.graphics.vertex_buffers[attribute.binding];
                const buffer = vertex_buffer.buffer;
                const buffer_memory_size = base.format.texelSize(attribute.format);
                const buffer_memory = if (buffer.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
                const input_index = switch (binding_info.input_rate) {
                    .vertex => vertex_index,
                    .instance => data.instance_index,
                    else => return VkError.ValidationFailed,
                };
                const offset = buffer.interface.offset + vertex_buffer.offset + (binding_info.stride * input_index) + attribute.offset;

                const buffer_memory_map: []u8 = try buffer_memory.map(offset, buffer_memory_size);

                try writeVertexInput(rt, data.allocator, buffer_memory_map, attribute.format, attribute.location);
            }
        }

        rt.callEntryPoint(data.allocator, entry) catch |err| switch (err) {
            // Some errors can be safely ignored
            SpvRuntimeError.Killed => {
                try rt.flushDescriptorSets(data.allocator);
                return;
            },
            else => return err,
        };

        try readPosition(rt, std.mem.asBytes(&output.position));
        try readPointSize(rt, &output.point_size);

        for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
            for (0..4) |component| {
                const result_word = rt.getResultByLocationComponent(@intCast(location), @intCast(component), .output) catch |err| switch (err) {
                    SpvRuntimeError.NotFound => continue,
                    else => return err,
                };

                const memory_size = try rt.getResultMemorySize(result_word);

                const result_is_integer = blk: {
                    const result_type = rt.getResultPrimitiveType(result_word) catch break :blk false;
                    break :blk result_type == .SInt or result_type == .UInt;
                };

                output.outputs[location][component] = .{
                    .interpolation_type = if (rt.hasResultDecoration(result_word, .Flat) or result_is_integer) .flat else .smooth, // TODO : handle noperspective
                    .blob = data.allocator.alloc(u8, memory_size + INTERFACE_BLOB_PADDING) catch return VkError.OutOfDeviceMemory,
                    .size = memory_size,
                };
                @memset(output.outputs[location][component].?.blob, 0);
                try rt.readOutput(output.outputs[location][component].?.blob, result_word);
            }
        }

        try rt.flushDescriptorSets(data.allocator);
    }
}

fn findBindingDescription(binding_descriptions: []const vk.VertexInputBindingDescription, binding: u32) ?vk.VertexInputBindingDescription {
    for (binding_descriptions) |description| {
        if (description.binding == binding)
            return description;
    }
    return null;
}

fn readPosition(rt: *spv.Runtime, output: []u8) !void {
    if (rt.readBuiltIn(output, .Position)) {
        return;
    } else |err| switch (err) {
        SpvRuntimeError.InvalidSpirV => {},
        else => return err,
    }

    for (rt.results) |*result| {
        const variant = result.variant orelse continue;
        switch (variant) {
            .AccessChain => |*access_chain| {
                if (access_chain.indexes.len == 0)
                    continue;

                const base_variant = rt.results[access_chain.base].variant orelse continue;
                switch (base_variant) {
                    .Variable => |variable| {
                        if (variable.storage_class != .Output)
                            continue;
                    },
                    else => continue,
                }

                if (!isConstantZero(rt, access_chain.indexes[0]))
                    continue;

                switch (access_chain.value) {
                    .Pointer => |ptr| switch (ptr.ptr) {
                        .common => |value| _ = try value.read(output),
                        else => continue,
                    },
                    else => _ = try access_chain.value.read(output),
                }
                return;
            },
            else => {},
        }
    }

    return SpvRuntimeError.InvalidSpirV;
}

fn readPointSize(rt: *spv.Runtime, output: *f32) !void {
    if (rt.readBuiltIn(std.mem.asBytes(output), .PointSize)) {
        return;
    } else |err| switch (err) {
        SpvRuntimeError.InvalidSpirV, SpvRuntimeError.NotFound => {},
        else => return err,
    }
}

fn isConstantZero(rt: *spv.Runtime, result_word: spv.SpvWord) bool {
    if (result_word >= rt.results.len)
        return false;

    const variant = rt.results[result_word].variant orelse return false;
    switch (variant) {
        .Constant => |constant| {
            var value: u32 = undefined;
            _ = constant.value.read(std.mem.asBytes(&value)) catch return false;
            return value == 0;
        },
        else => return false,
    }
}

fn setupBuiltins(rt: *spv.Runtime, vertex_index_u32: u32, instance_index: usize) !void {
    const instance_index_u32: u32 = @intCast(instance_index);

    try rt.writeBuiltIn(std.mem.asBytes(&vertex_index_u32), .VertexIndex);
    try rt.writeBuiltIn(std.mem.asBytes(&instance_index_u32), .InstanceIndex);
}

fn writeVertexInput(rt: *spv.Runtime, allocator: std.mem.Allocator, raw_input: []const u8, format: vk.Format, location: u32) !void {
    var expanded_input: [@sizeOf(F32x4)]u8 = @splat(0);
    const expanded_slice = expandedVertexInput(raw_input, format, &expanded_input);

    var has_split_components = false;
    for (1..4) |component| {
        _ = rt.getResultByLocationComponent(location, @intCast(component), .input) catch |err| switch (err) {
            SpvRuntimeError.NotFound => continue,
            else => return err,
        };
        has_split_components = true;
        break;
    }

    if (has_split_components) {
        for (0..4) |component| {
            const result_word = rt.getResultByLocationComponent(location, @intCast(component), .input) catch |err| switch (err) {
                SpvRuntimeError.NotFound => continue,
                else => return err,
            };
            const input_memory_size = try rt.getResultMemorySize(result_word);
            const raw_offset = component * @sizeOf(f32);

            if (raw_offset + input_memory_size <= expanded_slice.len) {
                try rt.writeInput(expanded_slice[raw_offset .. raw_offset + input_memory_size], result_word);
                continue;
            }

            const input = allocator.alloc(u8, input_memory_size) catch return VkError.OutOfDeviceMemory;
            defer allocator.free(input);

            @memset(input, 0);
            if (raw_offset < raw_input.len) {
                const copy_size = @min(input_memory_size, raw_input.len - raw_offset);
                @memcpy(input[0..copy_size], raw_input[raw_offset .. raw_offset + copy_size]);
            }

            if (component == 3 and input_memory_size >= @sizeOf(f32)) {
                if (base.format.isUnnormalizedInteger(format)) {
                    const one: u32 = 1;
                    @memcpy(input[0..@sizeOf(u32)], std.mem.asBytes(&one));
                } else {
                    const one: f32 = 1.0;
                    @memcpy(input[0..@sizeOf(f32)], std.mem.asBytes(&one));
                }
            }

            try rt.writeInput(input, result_word);
        }
        return;
    }

    const input_memory_size = rt.getInputLocationMemorySize(location) catch |err| switch (err) {
        SpvRuntimeError.NotFound => return,
        else => return err,
    };

    if (expanded_slice.len >= input_memory_size) {
        try rt.writeInputLocation(expanded_slice[0..input_memory_size], location);
        return;
    }

    const input = allocator.alloc(u8, input_memory_size) catch return VkError.OutOfDeviceMemory;
    defer allocator.free(input);

    @memset(input, 0);
    @memcpy(input[0..expanded_slice.len], expanded_slice);

    fillMissingVertexComponents(input, expanded_slice.len, format);
    try rt.writeInputLocation(input, location);
}

fn expandedVertexInput(raw_input: []const u8, format: vk.Format, expanded: *[@sizeOf(F32x4)]u8) []const u8 {
    if (base.format.isUnnormalizedInteger(format)) {
        const value = blitter.readInt4(raw_input, format);
        @memcpy(expanded, std.mem.asBytes(&value));
        return expanded;
    }

    const value = blitter.readFloat4(raw_input, format);
    @memcpy(expanded, std.mem.asBytes(&value));
    return expanded;
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
