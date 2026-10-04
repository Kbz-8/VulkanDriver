const std = @import("std");
const base = @import("base");
const spv = @import("spv");
const shader_ir = @import("shader_ir");

const ExecutionDevice = @import("../Device.zig");
const Renderer = @import("../Renderer.zig");
const Program = @import("../../interpreter/Program.zig");
const Runtime = @import("../../interpreter/Runtime.zig");
const Shader = @import("../../interpreter/Shader.zig");
const SoftImageView = @import("../../SoftImageView.zig");
const SoftSampler = @import("../../SoftSampler.zig");
const common = @import("dispatcher.zig");
const rasterizer_common = @import("../rasterizer/common.zig");
const VkError = base.VkError;
const SpvRuntimeError = common.SpvRuntimeError;
const InterfaceVariableId = shader_ir.ir.id.InterfaceVariableId;

pub fn prepareDraw(allocator: std.mem.Allocator, draw_call: *Renderer.DrawCall) VkError!void {
    const state = draw_call.renderer.state;
    const pipeline = state.pipeline orelse return VkError.InvalidPipelineDrv;
    const shader = pipeline.stages.getPtr(.fragment) orelse return;
    const program = &shader.program;
    if (program.stage != .fragment or program.uses_control_barriers or program.workgroup_memory_size != 0)
        return VkError.ValidationFailed;

    const buffers = allocator.alloc(?[]u8, program.resources.len) catch return VkError.OutOfDeviceMemory;
    errdefer allocator.free(buffers);
    @memset(buffers, null);

    const images = allocator.alloc(?*SoftImageView, program.resources.len) catch return VkError.OutOfDeviceMemory;
    errdefer allocator.free(images);
    @memset(images, null);

    const samplers = allocator.alloc(?*SoftSampler, program.resources.len) catch return VkError.OutOfDeviceMemory;
    errdefer allocator.free(samplers);
    @memset(samplers, null);

    for (program.resources, buffers, images, samplers) |optional_resource, *buffer, *image, *sampler| {
        const resource = optional_resource orelse continue;
        switch (resource.kind) {
            .uniform_buffer, .storage_buffer => buffer.* = try ExecutionDevice.mapBuffer(state, resource.set, resource.binding, resource.array_element),
            .sampled_image => image.* = try ExecutionDevice.mapSampledImage(state, resource.set, resource.binding, resource.array_element),
            .storage_image => image.* = try ExecutionDevice.mapStorageImage(state, resource.set, resource.binding, resource.array_element),
            .sampler => sampler.* = try ExecutionDevice.mapSampler(state, resource.set, resource.binding, resource.array_element),
        }
    }

    draw_call.fragment_resources = .{
        .buffers = buffers,
        .images = images,
        .samplers = samplers,
    };
}

pub fn finishDraw(allocator: std.mem.Allocator, draw_call: *Renderer.DrawCall) void {
    const resources = &draw_call.fragment_resources;
    if (resources.buffers.len != 0)
        allocator.free(resources.buffers);
    if (resources.images.len != 0)
        allocator.free(resources.images);
    if (resources.samplers.len != 0)
        allocator.free(resources.samplers);
    resources.* = .{};
}

pub const Worker = struct {
    draw_call: *Renderer.DrawCall,
    program: *const Program,
    slot: *Shader.RuntimeSlot,
    io: std.Io,

    pub fn release(self: *Worker) void {
        self.slot.mutex.unlock(self.io);
    }
};

pub fn acquireWorker(draw_call: *Renderer.DrawCall, batch_id: usize) VkError!Worker {
    const pipeline = draw_call.renderer.state.pipeline orelse return VkError.InvalidPipelineDrv;
    const shader = pipeline.stages.getPtr(.fragment) orelse return VkError.InvalidPipelineDrv;
    if (batch_id >= shader.runtimes.len)
        return VkError.InvalidPipelineDrv;

    const io = draw_call.renderer.device.interface.io();
    const slot = &shader.runtimes[batch_id];
    slot.mutex.lock(io) catch return VkError.DeviceLost;
    return .{
        .draw_call = draw_call,
        .program = &shader.program,
        .slot = slot,
        .io = io,
    };
}

pub fn shaderInvocation(
    worker: *Worker,
    position: base.zm.F32x4,
    point_coord: ?@Vector(2, f32),
    sample_id: ?u32,
    front_face: bool,
    inputs: common.FragmentInputs,
    derivative_inputs: ?common.DerivativeInputs,
) SpvRuntimeError!common.InvocationResult {
    // The current IR has no derivative instructions or point/sample/facing builtins.
    _ = point_coord;
    _ = sample_id;
    _ = front_face;
    _ = derivative_inputs;

    const draw_call = worker.draw_call;
    const state = draw_call.renderer.state;
    const program = worker.program;
    const runtime = &worker.slot.runtime;
    runtime.resetInvocation(program);

    const resources = draw_call.fragment_resources;
    if (resources.buffers.len != program.resources.len or resources.images.len != program.resources.len or resources.samplers.len != program.resources.len)
        return SpvRuntimeError.InvalidSpirV;

    try writeInputs(program, runtime, position, inputs);
    switch (runtime.run(program, .{
        .resource_buffers = resources.buffers,
        .resource_images = resources.images,
        .resource_samplers = resources.samplers,
        .push_constants = state.push_constant_blob[0..],
    }) catch |err| return mapError(err)) {
        .returned => {},
        .discarded => return SpvRuntimeError.Killed,
        .barrier => return SpvRuntimeError.InvalidSpirV,
    }
    return readOutputs(program, runtime);
}

fn writeInputs(
    program: *const Program,
    runtime: *Runtime,
    position: base.zm.F32x4,
    inputs: common.FragmentInputs,
) SpvRuntimeError!void {
    for (program.interfaces, 0..) |optional_binding, index| {
        const binding = optional_binding orelse continue;
        if (binding.direction != .input)
            continue;
        var words: [4]u32 = @splat(0);
        if (binding.span.components == 0 or binding.span.components > words.len)
            return SpvRuntimeError.InvalidSpirV;
        const values = words[0..binding.span.components];
        switch (binding.semantic) {
            .location => |location| {
                try validateLocation(binding);
                for (values, 0..) |*value, component|
                    value.* = inputs.word(location.location, @as(usize, location.component) + component);
            },
            .builtin => |builtin| switch (builtin) {
                .frag_coord => {
                    if (binding.span.kind != .floating or values.len != 4)
                        return SpvRuntimeError.InvalidSpirV;
                    inline for (0..4) |component|
                        values[component] = @bitCast(position[component]);
                },
                else => return SpvRuntimeError.InvalidSpirV,
            },
        }
        runtime.writeInput(program, InterfaceVariableId.fromIndex(index), values) catch |err| return mapError(err);
    }
}

fn readOutputs(program: *const Program, runtime: *const Runtime) SpvRuntimeError!common.InvocationResult {
    var result: common.InvocationResult = .{
        .outputs = std.mem.zeroes(@FieldType(common.InvocationResult, "outputs")),
        .depth = null,
        // SampleMask is not represented by the current IR builtin enum.
        .sample_mask = null,
    };
    for (program.interfaces, 0..) |optional_binding, index| {
        const binding = optional_binding orelse continue;
        if (binding.direction != .output)
            continue;
        var words: [4]u32 = undefined;
        if (binding.span.components == 0 or binding.span.components > words.len)
            return SpvRuntimeError.InvalidSpirV;
        const values = words[0..binding.span.components];
        runtime.readOutput(program, InterfaceVariableId.fromIndex(index), values) catch |err| return mapError(err);
        switch (binding.semantic) {
            .location => |location| {
                try validateLocation(binding);
                const offset = @as(usize, location.component) * @sizeOf(u32);
                const bytes = std.mem.sliceAsBytes(values);
                @memcpy(result.outputs[location.location][offset..][0..bytes.len], bytes);
            },
            .builtin => |builtin| switch (builtin) {
                .frag_depth => {
                    if (binding.span.kind != .floating or values.len != 1)
                        return SpvRuntimeError.InvalidSpirV;
                    result.depth = @bitCast(values[0]);
                },
                else => return SpvRuntimeError.InvalidSpirV,
            },
        }
    }
    return result;
}

fn validateLocation(binding: Program.InterfaceBinding) SpvRuntimeError!void {
    const location = binding.semantic.location;
    if (location.location >= spv.SPIRV_MAX_OUTPUT_LOCATIONS or location.index != 0 or
        @as(usize, location.component) + binding.span.components > 4)
        return SpvRuntimeError.InvalidSpirV;
}

fn mapError(err: anyerror) SpvRuntimeError {
    return switch (err) {
        error.OutOfMemory, error.OutOfDeviceMemory, error.OutOfHostMemory => SpvRuntimeError.OutOfMemory,
        error.BufferOutOfBounds => SpvRuntimeError.OutOfBounds,
        error.DeviceLost => SpvRuntimeError.Unknown,
        else => SpvRuntimeError.InvalidSpirV,
    };
}

fn emptyTestVertex() Renderer.Vertex {
    return .{
        .primitive_restart = false,
        .position = base.zm.f32x4(0.0, 0.0, 0.0, 1.0),
        .point_size = 1.0,
    };
}

fn setTestOutput(vertex: *Renderer.Vertex, location: usize, component: usize, word: u32, interpolation_type: Renderer.InterpolationType) void {
    vertex.packed_outputs[location][component] = .{
        .word = word,
        .interpolation_type = interpolation_type,
        .centroid = false,
    };
}

test "fragment IR executes varyings, FragCoord and FragDepth" {
    const ir = shader_ir.ir;
    var module = ir.module.Module.init(std.testing.allocator, .fragment);
    defer module.deinit();
    var builder = ir.Builder.init(&module);
    const void_type = try builder.internType(.void);
    const float_type = try builder.internType(.{ .floating = .{ .bits = 32 } });
    const vector_type = try builder.internType(.{ .vector = .{ .element_type = float_type, .length = 4 } });
    const varying = try builder.addInterfaceVariable(vector_type, .input, .{ .location = .{ .location = 2 } }, "varying");
    const scalar = try builder.addInterfaceVariable(float_type, .input, .{ .location = .{ .location = 4, .component = 2 } }, "scalar");
    const coord = try builder.addInterfaceVariable(vector_type, .input, .{ .builtin = .frag_coord }, "coord");
    const color = try builder.addInterfaceVariable(vector_type, .output, .{ .location = .{ .location = 1 } }, "color");
    const coord_color = try builder.addInterfaceVariable(vector_type, .output, .{ .location = .{ .location = 3 } }, "coord_color");
    const scalar_color = try builder.addInterfaceVariable(float_type, .output, .{ .location = .{ .location = 0, .component = 1 } }, "scalar_color");
    const depth = try builder.addInterfaceVariable(float_type, .output, .{ .builtin = .frag_depth }, "depth");
    const function = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(function);
    const block = try builder.addBlock(function, "entry");
    const varying_value = (try builder.appendInstruction(block, vector_type, .{ .load_interface = .{ .variable = varying } }, null)).?;
    const scalar_value = (try builder.appendInstruction(block, float_type, .{ .load_interface = .{ .variable = scalar } }, null)).?;
    const coord_value = (try builder.appendInstruction(block, vector_type, .{ .load_interface = .{ .variable = coord } }, null)).?;
    const depth_value = (try builder.appendInstruction(block, float_type, .{ .composite_extract = .{ .composite = coord_value, .indices = &.{2} } }, null)).?;
    _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = color, .value = varying_value } }, null);
    _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = coord_color, .value = coord_value } }, null);
    _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = scalar_color, .value = scalar_value } }, null);
    _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = depth, .value = depth_value } }, null);
    try builder.setTerminator(block, .return_void);

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    var v0 = emptyTestVertex();
    var v1 = emptyTestVertex();
    var v2 = emptyTestVertex();
    const varying_data = [4]f32{ 0.25, -0.5, 0.75, 1.0 };
    const scalar_data: f32 = 0.625;
    for (varying_data, 0..) |value, component| {
        const word: u32 = @bitCast(value);
        setTestOutput(&v0, 2, component, word, .smooth);
        setTestOutput(&v1, 2, component, word, .smooth);
        setTestOutput(&v2, 2, component, word, .smooth);
    }
    const scalar_word: u32 = @bitCast(scalar_data);
    setTestOutput(&v0, 4, 2, scalar_word, .smooth);
    setTestOutput(&v1, 4, 2, scalar_word, .smooth);
    setTestOutput(&v2, 4, 2, scalar_word, .smooth);
    const inputs = try rasterizer_common.interpolateVertexOutputs(std.testing.allocator, &v0, &v1, &v2, &v0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0);

    for (0..2) |invocation| {
        const position = if (invocation == 0) base.zm.f32x4(12.5, 34.5, 0.375, 0.5) else base.zm.f32x4(4.5, 8.5, 0.875, 1.0);
        runtime.resetInvocation(&program);
        try writeInputs(&program, &runtime, position, inputs);
        try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
        const result = try readOutputs(&program, &runtime);
        var expected = std.mem.zeroes(@FieldType(common.InvocationResult, "outputs"));
        if (invocation == 0) {
            @memcpy(&expected[1], std.mem.asBytes(&varying_data));
            @memcpy(expected[0][4..8], std.mem.asBytes(&scalar_data));
        }
        @memcpy(&expected[3], std.mem.asBytes(&position));
        try std.testing.expectEqualDeep(expected, result.outputs);
        try std.testing.expectEqual(@as(?f32, position[2]), result.depth);
        try std.testing.expectEqual(@as(?@import("vulkan").SampleMask, null), result.sample_mask);
        v0.packed_outputs = @splat(@splat(null));
        v1.packed_outputs = @splat(@splat(null));
        v2.packed_outputs = @splat(@splat(null));
    }
}

test "fragment IR execution discards without returning outputs" {
    const ir = shader_ir.ir;
    var module = ir.module.Module.init(std.testing.allocator, .fragment);
    defer module.deinit();
    var builder = ir.Builder.init(&module);
    const void_type = try builder.internType(.void);
    const function = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(function);
    const block = try builder.addBlock(function, "entry");
    try builder.setTerminator(block, .discard);

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    var vertex = emptyTestVertex();
    const inputs = try rasterizer_common.interpolateVertexOutputs(std.testing.allocator, &vertex, &vertex, &vertex, &vertex, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0);
    runtime.resetInvocation(&program);
    try writeInputs(&program, &runtime, base.zm.f32x4(0.5, 0.5, 0.25, 1.0), inputs);
    try std.testing.expectEqual(Runtime.Outcome.discarded, try runtime.run(&program, .{}));
}

test "fragment IR interpolates packed smooth and flat inputs" {
    var v0 = emptyTestVertex();
    var v1 = emptyTestVertex();
    var v2 = emptyTestVertex();
    var provoking = emptyTestVertex();
    setTestOutput(&v0, 1, 2, @bitCast(@as(f32, 1.0)), .smooth);
    setTestOutput(&v1, 1, 2, @bitCast(@as(f32, 3.0)), .smooth);
    setTestOutput(&v2, 1, 2, @bitCast(@as(f32, 5.0)), .smooth);
    setTestOutput(&v0, 3, 1, 10, .flat);
    setTestOutput(&v1, 3, 1, 20, .flat);
    setTestOutput(&v2, 3, 1, 30, .flat);
    setTestOutput(&provoking, 3, 1, 99, .flat);

    const inputs = try rasterizer_common.interpolateVertexOutputs(std.testing.allocator, &v0, &v1, &v2, &provoking, 0.25, 0.25, 0.5, 0.25, 0.25, 0.5);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 3.5))), inputs.word(1, 2));
    try std.testing.expectEqual(@as(u32, 99), inputs.word(3, 1));
    try std.testing.expectEqual(@as(u32, 0), inputs.word(7, 0));
}
