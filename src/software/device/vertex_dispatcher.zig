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
        if (rt.specialization_constants.count() != 0)
            try rt.applySpecializationInvocationLayout(data.allocator);
        try @import("Device.zig").writeDescriptorSets(data.draw_call.renderer.state, rt);
        try rt.populatePushConstants(data.draw_call.renderer.state.push_constant_blob[0..]);

        const vertex_index_u32: u32 = if (data.indices) |indices| indices[invocation_index] else @intCast(data.first_vertex + invocation_index);
        const vertex_index: usize = vertex_index_u32;
        const instance_index = data.first_instance + data.instance_index;

        try setupBuiltins(rt, data.allocator, vertex_index_u32, instance_index);

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
                    .instance => data.first_instance + data.instance_index,
                    else => return VkError.ValidationFailed,
                };
                const offset = buffer.interface.offset + vertex_buffer.offset + (binding_info.stride * input_index) + attribute.offset;

                var robust_vertex_bytes: [64]u8 = @splat(0);
                if (buffer_memory_size > robust_vertex_bytes.len)
                    return VkError.Unknown;
                if (offset < buffer_memory.size) {
                    const available = @min(buffer_memory_size, @as(usize, @intCast(buffer_memory.size - offset)));
                    const buffer_memory_map: []const u8 = buffer_memory.map(offset, available) catch &.{};
                    @memcpy(robust_vertex_bytes[0..buffer_memory_map.len], buffer_memory_map);
                }

                try writeVertexInput(rt, data.allocator, robust_vertex_bytes[0..buffer_memory_size], attribute.format, attribute.location);
            }
        }

        rt.callEntryPoint(data.allocator, entry) catch |err| switch (err) {
            // Some errors can be safely ignored
            SpvRuntimeError.OutOfBounds => {},
            SpvRuntimeError.Killed => {
                try rt.flushDescriptorSets(data.allocator);
                return;
            },
            else => return err,
        };

        try readPosition(rt, std.mem.asBytes(&output.position));
        try readPointSize(rt, &output.point_size);

        for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
            const location_result = rt.getResultByLocation(@intCast(location), .output) catch |err| switch (err) {
                SpvRuntimeError.NotFound => continue,
                else => return err,
            };

            try readVertexOutput(data, output, rt, location, 0, location_result);

            for (1..4) |component| {
                const component_result = rt.getResultByLocationComponent(@intCast(location), @intCast(component), .output) catch |err| switch (err) {
                    SpvRuntimeError.NotFound => continue,
                    else => return err,
                };

                if (component_result == location_result)
                    continue;

                try readVertexOutput(data, output, rt, location, component, component_result);
            }
        }

        try readActiveInterfaceOutputs(data, output, rt, entry);

        try rt.flushDescriptorSets(data.allocator);
    }
}

fn readActiveInterfaceOutputs(data: RunData, output: *Renderer.Vertex, rt: *spv.Runtime, entry: spv.SpvWord) !void {
    if (entry >= rt.mod.entry_points.items.len)
        return;

    for (rt.mod.entry_points.items[entry].globals) |global| {
        if (global >= rt.results.len)
            continue;

        const variable = switch (rt.results[global].variant orelse continue) {
            .Variable => |v| v,
            else => continue,
        };
        if (variable.storage_class != .Output)
            continue;

        var location: ?usize = null;
        var component: usize = 0;
        for (rt.results[global].decorations.items) |decoration| switch (decoration.rtype) {
            .Location => location = decoration.literal_1,
            .Component => component = decoration.literal_1,
            else => {},
        };

        const type_word = pointerTargetType(rt, variable.type_word) orelse continue;
        if (rt.results[type_word].variant) |type_variant| switch (type_variant) {
            .Type => |t| switch (t) {
                .Structure => |structure| {
                    const base_location = location orelse continue;
                    for (structure.members_type_word, 0..) |_, member_index| {
                        const member_location = interfaceMemberLocation(rt, type_word, base_location, @intCast(member_index));
                        if (member_location >= spv.SPIRV_MAX_OUTPUT_LOCATIONS)
                            continue;
                        if (output.outputs[member_location][component] != null)
                            continue;
                        if (accessChainToMember(rt, global, @intCast(member_index))) |member_word| {
                            try readVertexOutput(data, output, rt, member_location, component, member_word);
                        }
                    }
                    continue;
                },
                else => {},
            },
            else => {},
        };

        const target_location = location orelse continue;
        if (target_location >= spv.SPIRV_MAX_OUTPUT_LOCATIONS or component >= 4)
            continue;
        if (output.outputs[target_location][component] != null)
            continue;

        try readVertexOutput(data, output, rt, target_location, component, global);
    }
}

fn readVertexOutput(data: RunData, output: *Renderer.Vertex, rt: *spv.Runtime, location: usize, component: usize, result_word: spv.SpvWord) !void {
    const memory_size = try rt.getResultMemorySize(result_word);
    const interpolation_type = vertexOutputInterpolationType(data, rt, location, component, result_word);

    output.outputs[location][component] = .{
        .interpolation_type = interpolation_type,
        .blob = data.allocator.alloc(u8, memory_size + INTERFACE_BLOB_PADDING) catch return VkError.OutOfDeviceMemory,
        .size = memory_size,
    };
    @memset(output.outputs[location][component].?.blob, 0);
    try rt.readOutput(output.outputs[location][component].?.blob, result_word);
}

fn vertexOutputInterpolationType(data: RunData, rt: *spv.Runtime, location: usize, component: usize, result_word: spv.SpvWord) Renderer.InterpolationType {
    const result_is_integer = resultIsInteger(rt, result_word);

    const fragment_input_is_flat = fragmentInputHasDecoration(data, location, component, .Flat);
    const fragment_input_is_noperspective = fragmentInputHasDecoration(data, location, component, .NoPerspective);

    if (fragment_input_is_flat or result_is_integer)
        return .flat;
    if (fragment_input_is_noperspective)
        return .noperspective;
    return .smooth;
}

fn fragmentInputHasDecoration(data: RunData, location: usize, component: usize, decoration: anytype) bool {
    const fragment_shader = data.pipeline.stages.getPtr(.fragment) orelse return false;
    const fragment_rt = &fragment_shader.runtimes[0].rt;

    if (fragment_rt.getResultByLocationComponent(@intCast(location), @intCast(component), .input)) |input_word| {
        if (fragment_rt.hasResultDecoration(input_word, decoration))
            return true;

        if (input_word < fragment_rt.results.len) {
            const input = fragment_rt.results[input_word];
            if (input.variant) |variant| switch (variant) {
                .AccessChain => |access_chain| {
                    const member_index = firstConstantAccessIndex(fragment_rt, access_chain.indexes) orelse return false;
                    if (interfaceMemberHasDecoration(fragment_rt, access_chain.base, member_index, decoration))
                        return true;
                },
                else => {},
            };
        }
    } else |_| {}

    return interfaceLocationMemberHasDecoration(fragment_rt, location, decoration);
}

fn interfaceLocationMemberHasDecoration(rt: *const spv.Runtime, location: usize, decoration: anytype) bool {
    for (rt.results, 0..) |result, id| {
        const variant = result.variant orelse continue;
        const variable = switch (variant) {
            .Variable => |v| v,
            else => continue,
        };
        if (variable.storage_class != .Input)
            continue;

        const type_word = pointerTargetType(rt, variable.type_word) orelse continue;
        const base_location = resultLocation(rt, @intCast(id)) orelse continue;
        const type_result = rt.results[type_word];
        const type_variant = type_result.variant orelse continue;
        switch (type_variant) {
            .Type => |t| switch (t) {
                .Structure => |structure| {
                    for (structure.members_type_word, 0..) |_, member_index| {
                        if (interfaceMemberLocation(rt, type_word, base_location, @intCast(member_index)) == location) {
                            if (interfaceMemberHasDecoration(rt, @intCast(id), @intCast(member_index), decoration))
                                return true;
                        }
                    }
                },
                else => {},
            },
            else => {},
        }
    }

    return false;
}

fn resultLocation(rt: *const spv.Runtime, result_word: spv.SpvWord) ?usize {
    if (result_word >= rt.results.len)
        return null;

    for (rt.results[result_word].decorations.items) |decoration| {
        if (decoration.rtype == .Location)
            return decoration.literal_1;
    }
    return null;
}

fn interfaceMemberLocation(rt: *const spv.Runtime, type_word: spv.SpvWord, base_location: usize, member_index: spv.SpvWord) usize {
    if (type_word < rt.results.len) {
        for (rt.results[type_word].decorations.items) |decoration| {
            if (decoration.rtype == .Location and decoration.index == member_index)
                return decoration.literal_1;
        }
    }
    return base_location + @as(usize, @intCast(member_index));
}

fn interfaceMemberHasDecoration(rt: *const spv.Runtime, variable_word: spv.SpvWord, member_index: spv.SpvWord, decoration: anytype) bool {
    if (variable_word >= rt.results.len)
        return false;

    const variable = switch (rt.results[variable_word].variant orelse return false) {
        .Variable => |v| v,
        else => return false,
    };

    const type_word = pointerTargetType(rt, variable.type_word) orelse return false;
    const type_result = rt.results[type_word];
    const type_variant = type_result.variant orelse return false;
    switch (type_variant) {
        .Type => |t| switch (t) {
            .Structure => {
                for (type_result.decorations.items) |member_decoration| {
                    if (member_decoration.index == member_index and member_decoration.rtype == decoration)
                        return true;
                }
            },
            else => {},
        },
        else => {},
    }

    return false;
}

fn accessChainToMember(rt: *const spv.Runtime, base_word: spv.SpvWord, member_index: spv.SpvWord) ?spv.SpvWord {
    for (rt.results, 0..) |result, id| {
        const access_chain = switch (result.variant orelse continue) {
            .AccessChain => |a| a,
            else => continue,
        };
        if (access_chain.base != base_word)
            continue;
        if (firstConstantAccessIndex(rt, access_chain.indexes) == member_index)
            return @intCast(id);
    }
    return null;
}

fn pointerTargetType(rt: *const spv.Runtime, type_word: spv.SpvWord) ?spv.SpvWord {
    if (type_word >= rt.results.len)
        return null;

    const type_variant = rt.results[type_word].variant orelse return null;
    return switch (type_variant) {
        .Type => |t| switch (t) {
            .Pointer => |ptr| ptr.target,
            else => type_word,
        },
        else => null,
    };
}

fn firstConstantAccessIndex(rt: *const spv.Runtime, indexes: []const spv.SpvWord) ?spv.SpvWord {
    if (indexes.len == 0)
        return null;

    const index_word = indexes[0];
    if (index_word >= rt.results.len)
        return null;

    const value = rt.results[index_word].getConstValue() catch return null;
    return switch (value.*) {
        .Int => |int| switch (int.bit_count) {
            8 => if (int.is_signed) @intCast(int.value.sint8) else @intCast(int.value.uint8),
            16 => if (int.is_signed) @intCast(int.value.sint16) else @intCast(int.value.uint16),
            32 => if (int.is_signed) @intCast(int.value.sint32) else @intCast(int.value.uint32),
            64 => if (int.is_signed) @intCast(int.value.sint64) else @intCast(int.value.uint64),
            else => null,
        },
        else => null,
    };
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
        SpvRuntimeError.InvalidSpirV, SpvRuntimeError.NotFound => {},
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

fn resultIsInteger(rt: *spv.Runtime, result_word: spv.SpvWord) bool {
    const value = (rt.results[result_word].getConstValue() catch return false);
    return valueIsInteger(value);
}

fn valueIsInteger(value: anytype) bool {
    return switch (value.*) {
        .Int,
        .Vector2i32,
        .Vector3i32,
        .Vector4i32,
        .Vector2u32,
        .Vector3u32,
        .Vector4u32,
        => true,
        .Vector,
        .Matrix,
        => |values| values.len != 0 and valueIsInteger(&values[0]),
        .Array => |array| array.values.len != 0 and valueIsInteger(&array.values[0]),
        else => false,
    };
}

fn setupBuiltins(rt: *spv.Runtime, allocator: std.mem.Allocator, vertex_index_u32: u32, instance_index: usize) !void {
    const instance_index_u32: u32 = @intCast(instance_index);

    rt.writeBuiltIn(allocator, std.mem.asBytes(&vertex_index_u32), .VertexIndex) catch |err| switch (err) {
        SpvRuntimeError.NotFound => {},
        else => return err,
    };
    rt.writeBuiltIn(allocator, std.mem.asBytes(&instance_index_u32), .InstanceIndex) catch |err| switch (err) {
        SpvRuntimeError.NotFound => {},
        else => return err,
    };
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
                try rt.writeInput(allocator, expanded_slice[raw_offset .. raw_offset + input_memory_size], result_word);
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

            try rt.writeInput(allocator, input, result_word);
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
