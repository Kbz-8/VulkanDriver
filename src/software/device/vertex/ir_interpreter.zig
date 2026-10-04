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

    var invocation_index = batch_id;
    while (invocation_index < vertex_count) : (invocation_index += batch_size) {
        const output = &draw_call.vertices[(instance_index * vertex_count) + invocation_index];
        if (primitive_restart) |restart| {
            if (restart[invocation_index]) {
                output.primitive_restart = true;
                continue;
            }
        }

        slot.runtime.resetInvocation(&shader.program);
        const vertex_index: u32 = if (indices) |draw_indices| draw_indices[invocation_index] else @intCast(first_vertex + invocation_index);
        try populateInputs(
            &slot.runtime,
            &shader.program,
            pipeline,
            draw_call,
            vertex_index,
            @intCast(first_instance + instance_index),
        );
        const outcome = slot.runtime.run(&shader.program, .{
            .resource_buffers = resource_buffers,
            .resource_images = resource_images,
            .resource_samplers = resource_samplers,
            .push_constants = draw_call.renderer.state.push_constant_blob[0..],
        }) catch return VkError.Unknown;
        if (outcome == .discarded)
            continue;
        try collectOutputs(&slot.runtime, &shader.program, output);
    }
}

fn populateInputs(runtime: anytype, program: *const Program, pipeline: *SoftPipeline, draw_call: *Renderer.DrawCall, vertex_index: u32, instance_index: u32) VkError!void {
    for (program.interfaces, 0..) |optional_binding, index| {
        const binding = optional_binding orelse continue;
        if (binding.direction != .input)
            continue;

        const variable = ir.id.InterfaceVariableId.fromIndex(index);
        var values: [4]u32 = @splat(0);
        switch (binding.semantic) {
            .builtin => |builtin| values[0] = switch (builtin) {
                .vertex_index => vertex_index,
                .instance_index => instance_index,
                else => return VkError.InvalidPipelineDrv,
            },
            .location => |location| {
                const attribute = findAttribute(
                    pipeline.interface.mode.graphics.input_assembly.attribute_description orelse &.{},
                    location.location,
                ) orelse {
                    runtime.writeInput(program, variable, values[0..binding.span.components]) catch return VkError.Unknown;
                    continue;
                };

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

                values = if (base.format.isUnnormalizedInteger(attribute.format))
                    blitter.readInt4(robust_bytes[0..input_size], attribute.format)
                else
                    @bitCast(blitter.readFloat4(robust_bytes[0..input_size], attribute.format));

                const first_component: usize = location.component;
                const end_component = first_component + binding.span.components;
                runtime.writeInput(program, variable, values[first_component..end_component]) catch return VkError.Unknown;
                continue;
            },
        }
        runtime.writeInput(program, variable, values[0..binding.span.components]) catch return VkError.Unknown;
    }
}

fn collectOutputs(runtime: anytype, program: *const Program, output: *Renderer.Vertex) VkError!void {
    for (program.interfaces, 0..) |optional_binding, index| {
        const binding = optional_binding orelse continue;

        if (binding.direction != .output)
            continue;

        const variable = ir.id.InterfaceVariableId.fromIndex(index);
        var values: [4]u32 = @splat(0);
        runtime.readOutput(program, variable, values[0..binding.span.components]) catch return VkError.Unknown;
        switch (binding.semantic) {
            .builtin => |builtin| switch (builtin) {
                .position => @memcpy(std.mem.asBytes(&output.position), std.mem.asBytes(&values)),
                .point_size => output.point_size = @bitCast(values[0]),
                else => return VkError.InvalidPipelineDrv,
            },
            .location => |location| {
                const first_component: usize = location.component;
                const end_component = first_component + binding.span.components;
                if (location.location >= output.packed_outputs.len or end_component > output.packed_outputs[0].len)
                    return VkError.ValidationFailed;

                const interpolation_type: Renderer.InterpolationType = switch (binding.span.kind) {
                    .signed_integer, .unsigned_integer, .boolean => .flat,
                    .floating => .smooth,
                };
                for (values[0..binding.span.components], first_component..) |word, component| {
                    output.packed_outputs[location.location][component] = .{
                        .word = word,
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

    try collectOutputs(&runtime, &program, &output);

    try std.testing.expectEqual(@as(base.zm.F32x4, @bitCast(position_values)), output.position);
    try std.testing.expectEqual(expected_point_size, output.point_size);
    for (position_values, 0..) |value, component| {
        const packed_output = output.packed_outputs[2][component].?;
        try std.testing.expectEqual(@as(u32, @bitCast(value)), packed_output.word);
        try std.testing.expectEqual(Renderer.InterpolationType.smooth, packed_output.interpolation_type);
    }
}
