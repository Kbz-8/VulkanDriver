const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const shader_ir = @import("shader_ir");

const Program = @import("../../interpreter/Program.zig");
const Runtime = @import("../../interpreter/Runtime.zig");
const SoftPipeline = @import("../../SoftPipeline.zig");
const Renderer = @import("../Renderer.zig");
const ExecutionDevice = @import("../Device.zig");
const SoftImageView = @import("../../SoftImageView.zig");
const SoftSampler = @import("../../SoftSampler.zig");
const blitter = @import("../blitter.zig");
const RunData = @import("dispatcher.zig").RunData;

const VkError = base.VkError;
const ir = shader_ir.ir;

pub fn run(data: RunData) VkError!void {
    const allocator = data.allocator;
    const pipeline = data.pipeline;
    const shader = pipeline.stages.getPtrAssertContains(.vertex);
    const batch_id = data.batch_id;
    const batch_size = data.batch_size;
    const vertex_count = data.vertex_count;
    const invocation_indices = data.invocation_indices;
    const invocation_count = if (invocation_indices) |items| items.len else vertex_count;
    const first_vertex = data.first_vertex;
    const first_instance = data.first_instance;
    const indices = data.indices;
    const primitive_restart = data.primitive_restart;
    const instance_index = data.instance_index;
    const draw_call = data.draw_call;
    if (batch_id >= shader.runtimes.len or batch_size == 0)
        return VkError.InvalidPipelineDrv;

    const slot = &shader.runtimes[batch_id];
    const io = draw_call.renderer.device.interface.io();
    slot.mutex.lock(io) catch return VkError.DeviceLost;
    defer slot.mutex.unlock(io);

    var input_ns: u64 = 0;
    var shader_ns: u64 = 0;
    var output_ns: u64 = 0;
    var invocations: u64 = 0;
    var instructions: u64 = 0;
    var fast_path_instructions: u64 = 0;
    var waves: u64 = 0;
    var full_waves: u64 = 0;
    defer if (comptime base.config.soft_profile) {
        Renderer.DrawProfile.add(&draw_call.profile.vertex_input_ns, input_ns);
        Renderer.DrawProfile.add(&draw_call.profile.vertex_shader_ns, shader_ns);
        Renderer.DrawProfile.add(&draw_call.profile.vertex_output_ns, output_ns);
        Renderer.DrawProfile.add(&draw_call.profile.vertex_invocations, invocations);
        Renderer.DrawProfile.add(&draw_call.profile.vertex_instructions, instructions);
        Renderer.DrawProfile.add(&draw_call.profile.vertex_fast_path_instructions, fast_path_instructions);
        Renderer.DrawProfile.add(&draw_call.profile.vertex_waves, waves);
        Renderer.DrawProfile.add(&draw_call.profile.vertex_full_waves, full_waves);
    };

    const resource_buffers = allocator.alloc(?[]u8, shader.program.resources.len) catch return VkError.OutOfDeviceMemory;
    defer allocator.free(resource_buffers);
    @memset(resource_buffers, null);

    for (shader.program.resources, resource_buffers) |optional_resource, *buffer| {
        const resource = optional_resource orelse continue;
        if (resource.kind == .storage_buffer or resource.kind == .uniform_buffer)
            buffer.* = try ExecutionDevice.mapBuffer(draw_call.renderer.state, resource.set, resource.binding, resource.array_element);
    }

    const resource_images = allocator.alloc(?*SoftImageView, shader.program.resources.len) catch return VkError.OutOfDeviceMemory;
    defer allocator.free(resource_images);
    @memset(resource_images, null);

    for (shader.program.resources, resource_images) |optional_resource, *image| {
        const resource = optional_resource orelse continue;
        image.* = switch (resource.kind) {
            .sampled_image => try ExecutionDevice.mapSampledImage(draw_call.renderer.state, resource.set, resource.binding, resource.array_element),
            .storage_image => try ExecutionDevice.mapStorageImage(draw_call.renderer.state, resource.set, resource.binding, resource.array_element),
            else => null,
        };
    }

    const resource_samplers = allocator.alloc(?*SoftSampler, shader.program.resources.len) catch return VkError.OutOfDeviceMemory;
    defer allocator.free(resource_samplers);
    @memset(resource_samplers, null);

    for (shader.program.resources, resource_samplers) |optional_resource, *sampler| {
        const resource = optional_resource orelse continue;
        if (resource.kind == .sampler)
            sampler.* = try ExecutionDevice.mapSampler(draw_call.renderer.state, resource.set, resource.binding, resource.array_element);
    }

    const wave_stride = std.math.mul(usize, batch_size, Runtime.lane_count) catch return VkError.ValidationFailed;
    var wave_base = std.math.mul(usize, batch_id, Runtime.lane_count) catch return VkError.ValidationFailed;
    while (wave_base < invocation_count) : (wave_base += wave_stride) {
        var mask: Runtime.LaneMask = 0;
        for (0..Runtime.lane_count) |lane| {
            const work_index = wave_base + lane;
            if (work_index >= invocation_count)
                continue;
            const invocation_index = if (invocation_indices) |items| items[work_index] else work_index;

            const output = &draw_call.vertices[(instance_index * vertex_count) + invocation_index];
            if (primitive_restart) |restart| {
                if (restart[invocation_index]) {
                    output.primitive_restart = true;
                    continue;
                }
            }
            mask |= @as(Runtime.LaneMask, 1) << @intCast(lane);
        }
        if (mask == 0)
            continue;

        slot.runtime.resetWave(&shader.program, mask, mask);
        const input_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(io, .real) else undefined;
        for (0..Runtime.lane_count) |lane| {
            const bit = @as(Runtime.LaneMask, 1) << @intCast(lane);
            if ((mask & bit) == 0)
                continue;
            const work_index = wave_base + lane;
            const invocation_index = if (invocation_indices) |items| items[work_index] else work_index;
            const vertex_index: u32 = if (indices) |draw_indices| draw_indices[invocation_index] else @intCast(first_vertex + invocation_index);
            try populateInputsLane(
                &slot.runtime,
                &shader.program,
                lane,
                pipeline,
                draw_call,
                vertex_index,
                @intCast(first_instance + instance_index),
            );
        }
        if (comptime base.config.soft_profile)
            input_ns += Renderer.profileElapsedNs(input_timer, io);

        const shader_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(io, .real) else undefined;
        const outcome = slot.runtime.runWave(&shader.program, .{
            .resource_buffers = resource_buffers,
            .resource_images = resource_images,
            .resource_samplers = resource_samplers,
            .push_constants = draw_call.renderer.state.push_constant_blob[0..],
        }) catch return VkError.Unknown;
        if (outcome.barrier_mask != 0)
            return VkError.Unknown;

        if (comptime base.config.soft_profile) {
            shader_ns += Renderer.profileElapsedNs(shader_timer, io);
            invocations += @popCount(mask);
            instructions += slot.runtime.executedSteps();
            fast_path_instructions += slot.runtime.fastPathExecutedSteps();
            waves += 1;
            if (mask == Runtime.full_lane_mask)
                full_waves += 1;
        }

        const output_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(io, .real) else undefined;
        for (0..Runtime.lane_count) |lane| {
            const bit = @as(Runtime.LaneMask, 1) << @intCast(lane);
            if ((outcome.returned_mask & bit) == 0)
                continue;
            const work_index = wave_base + lane;
            const invocation_index = if (invocation_indices) |items| items[work_index] else work_index;
            const output = &draw_call.vertices[(instance_index * vertex_count) + invocation_index];
            try collectOutputsLane(&slot.runtime, &shader.program, lane, output);
        }
        if (comptime base.config.soft_profile)
            output_ns += Renderer.profileElapsedNs(output_timer, io);
    }
}

fn populateInputsLane(runtime: *Runtime, program: *const Program, lane: usize, pipeline: *SoftPipeline, draw_call: *Renderer.DrawCall, vertex_index: u32, instance_index: u32) VkError!void {
    for (program.interfaces, 0..) |optional_binding, index| {
        const binding = optional_binding orelse continue;
        if (binding.direction != .input)
            continue;

        const variable = ir.id.InterfaceVariableId.fromIndex(index);
        var values: [255]u32 = @splat(0);
        switch (binding.semantic) {
            .builtin => |builtin| values[0] = switch (builtin) {
                .vertex_index => vertex_index,
                .instance_index => instance_index,
                else => return VkError.InvalidPipelineDrv,
            },
            .location => {
                if (!binding.validLocation()) return VkError.ValidationFailed;
                var cached_location: ?u32 = null;
                var attribute_words: [4]u32 = @splat(0);
                for (binding.words, 0..) |word, word_index| {
                    if (cached_location == null or cached_location.? != word.location) {
                        cached_location = word.location;
                        attribute_words = @splat(0);
                        const attribute = findAttribute(
                            pipeline.interface.mode.graphics.input_assembly.attribute_description orelse &.{},
                            word.location,
                        ) orelse continue;

                        const binding_description = findBinding(
                            pipeline.interface.mode.graphics.input_assembly.binding_description orelse return VkError.ValidationFailed,
                            attribute.binding,
                        ) orelse return VkError.ValidationFailed;

                        const vertex_buffer = draw_call.renderer.state.data.graphics.vertex_buffers[attribute.binding];
                        const buffer = vertex_buffer.buffer;
                        const memory = buffer.interface.memory orelse return VkError.InvalidDeviceMemoryDrv;
                        const input_index = switch (binding_description.input_rate) {
                            .vertex => @as(usize, vertex_index),
                            .instance => @as(usize, instance_index),
                            else => return VkError.ValidationFailed,
                        };

                        const offset = buffer.interface.offset + vertex_buffer.offset + binding_description.stride * input_index + attribute.offset;
                        const input_size = base.format.texelSize(attribute.format);
                        var robust_bytes: [64]u8 = @splat(0);
                        if (input_size > robust_bytes.len)
                            return VkError.Unknown;

                        if (offset < memory.size) {
                            const available = @min(input_size, @as(usize, @intCast(memory.size - offset)));
                            const mapped = memory.map(offset, available) catch &.{};
                            @memcpy(robust_bytes[0..mapped.len], mapped);
                        }

                        attribute_words = if (base.format.isUnnormalizedInteger(attribute.format))
                            blitter.readInt4(robust_bytes[0..input_size], attribute.format)
                        else
                            @bitCast(blitter.readFloat4(robust_bytes[0..input_size], attribute.format));
                    }
                    values[word_index] = attribute_words[word.component];
                }
            },
        }
        runtime.writeInputLane(program, lane, variable, values[0..binding.span.components]) catch return VkError.Unknown;
    }
}

fn collectOutputsLane(runtime: *const Runtime, program: *const Program, lane: usize, output: *Renderer.Vertex) VkError!void {
    for (program.interfaces, 0..) |optional_binding, index| {
        const binding = optional_binding orelse continue;

        if (binding.direction != .output)
            continue;
        if (binding.span.kind == .mixed)
            return VkError.InvalidPipelineDrv;

        const variable = ir.id.InterfaceVariableId.fromIndex(index);
        var values: [255]u32 = @splat(0);
        runtime.readOutputLane(program, lane, variable, values[0..binding.span.components]) catch return VkError.Unknown;
        switch (binding.semantic) {
            .builtin => |builtin| switch (builtin) {
                .position => {
                    if (binding.span.components != 4) return VkError.ValidationFailed;
                    @memcpy(std.mem.asBytes(&output.position), std.mem.sliceAsBytes(values[0..4]));
                },
                .point_size => output.point_size = @bitCast(values[0]),
                else => return VkError.InvalidPipelineDrv,
            },
            .location => {
                if (!binding.validLocation()) return VkError.ValidationFailed;

                const interpolation_type: Renderer.InterpolationType = switch (binding.span.kind) {
                    .signed_integer, .unsigned_integer, .boolean => .flat,
                    .floating => .smooth,
                    .mixed => return VkError.InvalidPipelineDrv,
                };
                for (values[0..binding.span.components], binding.words) |value, word| {
                    output.packed_outputs[word.location][word.component] = .{
                        .word = value,
                        .interpolation_type = interpolation_type,
                        .centroid = false,
                    };
                }
            },
        }
    }
}

fn findAttribute(attributes: []const vk.VertexInputAttributeDescription, location: u32) ?vk.VertexInputAttributeDescription {
    for (attributes) |attribute| {
        if (attribute.location == location)
            return attribute;
    }
    return null;
}

fn findBinding(bindings: []const vk.VertexInputBindingDescription, binding: u32) ?vk.VertexInputBindingDescription {
    for (bindings) |description| {
        if (description.binding == binding)
            return description;
    }
    return null;
}

test "vertex IR collects Position and PointSize outputs" {
    var module = ir.module.Module.init(std.testing.allocator, .vertex);
    defer module.deinit();

    var builder = ir.Builder.init(&module);

    const void_type = try builder.internType(.void);
    const float_type = try builder.internType(.{ .floating = .{ .bits = 32 } });
    const vec4_type = try builder.internType(.{ .vector = .{ .element_type = float_type, .length = 4 } });

    const position = try builder.addInterfaceVariable(vec4_type, .output, .{ .builtin = .position }, "position");
    const point_size = try builder.addInterfaceVariable(float_type, .output, .{ .builtin = .point_size }, "point_size");
    const varying = try builder.addInterfaceVariable(vec4_type, .output, .{ .location = .{ .location = 2 } }, "varying");
    const position_values = [4]f32{ 0.25, -0.5, 0.75, 1.0 };
    var position_elements: [4]ir.id.ValueId = undefined;

    for (position_values, &position_elements) |value, *element|
        element.* = try builder.internConstant(float_type, .{ .float_bits = @as(u32, @bitCast(value)) });

    const function = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(function);

    const block = try builder.addBlock(function, "entry");

    const position_value = (try builder.appendInstruction(block, vec4_type, .{
        .composite_construct = .{ .elements = &position_elements },
    }, null)).?;

    const expected_point_size: f32 = 3.5;
    const point_size_value = try builder.internConstant(float_type, .{ .float_bits = @as(u32, @bitCast(expected_point_size)) });
    _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = position, .value = position_value } }, null);
    _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = point_size, .value = point_size_value } }, null);
    _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = varying, .value = position_value } }, null);
    try builder.setTerminator(block, .return_void);

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();

    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    runtime.resetInvocation(&program);
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));

    var output: Renderer.Vertex = .{
        .primitive_restart = false,
        .position = @splat(0),
        .point_size = 1.0,
    };

    try collectOutputsLane(&runtime, &program, 0, &output);

    try std.testing.expectEqual(@as(base.zm.F32x4, @bitCast(position_values)), output.position);
    try std.testing.expectEqual(expected_point_size, output.point_size);
    for (position_values, 0..) |value, component| {
        const packed_output = output.packed_outputs[2][component].?;
        try std.testing.expectEqual(@as(u32, @bitCast(value)), packed_output.word);
        try std.testing.expectEqual(Renderer.InterpolationType.smooth, packed_output.interpolation_type);
    }
}

test "vertex IR collects every aggregate word with per-location interpolation" {
    var module = ir.module.Module.init(std.testing.allocator, .vertex);
    defer module.deinit();
    var builder = ir.Builder.init(&module);
    const void_type = try builder.internType(.void);
    const float = try builder.internType(.{ .floating = .{ .bits = 32 } });
    const uint = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });
    const vec4 = try builder.internType(.{ .vector = .{ .element_type = float, .length = 4 } });
    const vec2 = try builder.internType(.{ .vector = .{ .element_type = uint, .length = 2 } });
    const array = try builder.internType(.{ .array = .{ .element_type = vec4, .length = 3 } });
    const array2 = try builder.internType(.{ .array = .{ .element_type = vec2, .length = 2 } });
    const input = try builder.addInterfaceVariable(array, .input, .{ .location = .{ .location = 0 } }, null);
    const output = try builder.addInterfaceVariable(array, .output, .{ .location = .{ .location = 2 } }, null);
    const flat_input = try builder.addInterfaceVariable(array2, .input, .{ .location = .{ .location = 4, .component = 2 } }, null);
    const flat_output = try builder.addInterfaceVariable(array2, .output, .{ .location = .{ .location = 6, .component = 2 } }, null);
    const function = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(function);
    const block = try builder.addBlock(function, "entry");
    for ([_]ir.id.TypeId{ array, array2 }, [_]ir.id.InterfaceVariableId{ input, flat_input }, [_]ir.id.InterfaceVariableId{ output, flat_output }) |ty, src, dst| {
        const value = (try builder.appendInstruction(block, ty, .{ .load_interface = .{ .variable = src } }, null)).?;
        _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = dst, .value = value } }, null);
    }
    try builder.setTerminator(block, .return_void);
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    var words: [12]u32 = undefined;
    for (&words, 0..) |*word, i| word.* = @bitCast(@as(f32, @floatFromInt(i + 1)));
    const flat_words = [_]u32{ 11, 22, 33, 44 };
    runtime.resetWave(&program, Runtime.full_lane_mask, Runtime.full_lane_mask);
    for (0..Runtime.lane_count) |lane| {
        try runtime.writeInputLane(&program, lane, input, &words);
        try runtime.writeInputLane(&program, lane, flat_input, &flat_words);
    }
    _ = try runtime.runWave(&program, .{});
    for (0..Runtime.lane_count) |lane| {
        var vertex: Renderer.Vertex = .{ .primitive_restart = false, .position = @splat(0), .point_size = 1 };
        try collectOutputsLane(&runtime, &program, lane, &vertex);
        for (words, 0..) |word, i| {
            const packed_output = vertex.packed_outputs[2 + i / 4][i % 4].?;
            try std.testing.expectEqual(word, packed_output.word);
            try std.testing.expectEqual(Renderer.InterpolationType.smooth, packed_output.interpolation_type);
        }
        for (flat_words, 0..) |word, i| {
            const packed_output = vertex.packed_outputs[6 + i / 2][2 + i % 2].?;
            try std.testing.expectEqual(word, packed_output.word);
            try std.testing.expectEqual(Renderer.InterpolationType.flat, packed_output.interpolation_type);
        }
        try std.testing.expectEqual(@as(?Renderer.PackedVertexOutput, null), vertex.packed_outputs[6][0]);
    }
}
