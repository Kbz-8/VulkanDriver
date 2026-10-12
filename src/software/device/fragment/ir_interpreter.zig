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
    input_ns: u64 = 0,
    shader_ns: u64 = 0,
    output_ns: u64 = 0,
    coverage_ns: u64 = 0,
    depth_ns: u64 = 0,
    interpolation_ns: u64 = 0,
    target_output_ns: u64 = 0,
    invocations: u64 = 0,
    instructions: u64 = 0,
    fast_path_instructions: u64 = 0,
    waves: u64 = 0,
    full_waves: u64 = 0,

    pub fn release(self: *Worker) void {
        if (comptime base.config.soft_profile) {
            Renderer.DrawProfile.add(&self.draw_call.profile.fragment_input_ns, self.input_ns);
            Renderer.DrawProfile.add(&self.draw_call.profile.fragment_shader_ns, self.shader_ns);
            Renderer.DrawProfile.add(&self.draw_call.profile.fragment_output_ns, self.output_ns);
            Renderer.DrawProfile.add(&self.draw_call.profile.raster_coverage_ns, self.coverage_ns);
            Renderer.DrawProfile.add(&self.draw_call.profile.raster_depth_ns, self.depth_ns);
            Renderer.DrawProfile.add(&self.draw_call.profile.raster_interpolation_ns, self.interpolation_ns);
            Renderer.DrawProfile.add(&self.draw_call.profile.raster_target_output_ns, self.target_output_ns);
            Renderer.DrawProfile.add(&self.draw_call.profile.fragment_invocations, self.invocations);
            Renderer.DrawProfile.add(&self.draw_call.profile.fragment_instructions, self.instructions);
            Renderer.DrawProfile.add(&self.draw_call.profile.fragment_fast_path_instructions, self.fast_path_instructions);
            Renderer.DrawProfile.add(&self.draw_call.profile.fragment_waves, self.waves);
            Renderer.DrawProfile.add(&self.draw_call.profile.fragment_full_waves, self.full_waves);
        }
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

pub const WaveInvocation = struct {
    position: base.zm.F32x4,
    inputs: common.FragmentInputs,
};

pub const WaveResult = struct {
    outputs: rasterizer_common.FragmentWaveOutputs,
    output_components: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]u4,
    depths: @Vector(Runtime.lane_count, f32),
    depth_mask: Runtime.LaneMask,
    returned_mask: Runtime.LaneMask,
    discarded_mask: Runtime.LaneMask,

    pub fn laneResult(self: *const WaveResult, lane: usize) common.InvocationResult {
        var result = emptyInvocationResult();
        for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
            for (0..4) |component| {
                const component_bit = @as(u4, 1) << @intCast(component);
                if ((self.output_components[location] & component_bit) == 0)
                    continue;
                const component_lanes: [Runtime.lane_count]u32 = @bitCast(self.outputs[location][component]);
                const word = component_lanes[lane];
                const offset = component * @sizeOf(u32);
                @memcpy(result.outputs[location][offset..][0..@sizeOf(u32)], std.mem.asBytes(&word));
            }
        }
        const bit = @as(Runtime.LaneMask, 1) << @intCast(lane);
        if ((self.depth_mask & bit) != 0) {
            const depth_lanes: [Runtime.lane_count]f32 = @bitCast(self.depths);
            result.depth = depth_lanes[lane];
        }
        return result;
    }
};

pub fn shaderWave(worker: *Worker, invocations: *const [Runtime.lane_count]WaveInvocation, mask: Runtime.LaneMask) SpvRuntimeError!WaveResult {
    return shaderWaveMasked(worker, invocations, mask, mask);
}

fn shaderWaveMasked(worker: *Worker, invocations: *const [Runtime.lane_count]WaveInvocation, execution_mask: Runtime.LaneMask, mask: Runtime.LaneMask) SpvRuntimeError!WaveResult {
    const draw_call = worker.draw_call;
    const state = draw_call.renderer.state;
    const program = worker.program;
    const runtime = &worker.slot.runtime;
    runtime.resetWave(program, execution_mask, mask);

    const resources = draw_call.fragment_resources;
    if (resources.buffers.len != program.resources.len or resources.images.len != program.resources.len or resources.samplers.len != program.resources.len)
        return SpvRuntimeError.InvalidSpirV;

    const input_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(worker.io, .real) else undefined;
    for (0..Runtime.lane_count) |lane| {
        const bit = @as(Runtime.LaneMask, 1) << @intCast(lane);
        if ((execution_mask & bit) != 0)
            try writeInputsLane(program, runtime, lane, invocations[lane].position, invocations[lane].inputs);
    }
    if (comptime base.config.soft_profile)
        worker.input_ns += Renderer.profileElapsedNs(input_timer, worker.io);

    const shader_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(worker.io, .real) else undefined;
    const outcome = runtime.runWave(program, .{
        .resource_buffers = resources.buffers,
        .resource_images = resources.images,
        .resource_samplers = resources.samplers,
        .push_constants = state.push_constant_blob[0..],
    }) catch |err| return mapError(err);

    if (comptime base.config.soft_profile) {
        worker.shader_ns += Renderer.profileElapsedNs(shader_timer, worker.io);
        worker.invocations += @popCount(mask);
        worker.instructions += runtime.executedSteps();
        worker.fast_path_instructions += runtime.fastPathExecutedSteps();
        worker.waves += 1;
        if (mask == Runtime.full_lane_mask)
            worker.full_waves += 1;
    }
    if (outcome.barrier_mask != 0)
        return SpvRuntimeError.InvalidSpirV;

    const output_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(worker.io, .real) else undefined;
    const results = try readOutputsWave(program, runtime);
    if (comptime base.config.soft_profile)
        worker.output_ns += Renderer.profileElapsedNs(output_timer, worker.io);

    return .{
        .outputs = results.outputs,
        .output_components = results.output_components,
        .depths = results.depths,
        .depth_mask = results.depth_mask & mask,
        .returned_mask = outcome.returned_mask & mask,
        .discarded_mask = outcome.discarded_mask & mask,
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
    // Point/sample/facing builtins are not yet represented by the IR.
    _ = point_coord;
    _ = sample_id;
    _ = front_face;
    var invocations: [Runtime.lane_count]WaveInvocation = undefined;
    var lane: u2 = 0;
    var execution_mask: Runtime.LaneMask = 1;
    if (worker.program.uses_derivatives) {
        const helpers = derivative_inputs orelse return SpvRuntimeError.InvalidSpirV;
        const quad_inputs = helpers.quad_inputs orelse return SpvRuntimeError.InvalidSpirV;
        const quad_positions = helpers.quad_positions orelse return SpvRuntimeError.InvalidSpirV;
        lane = helpers.quad_lane;
        for (invocations[0..4], quad_inputs, quad_positions) |*invocation, helper_inputs, helper_position|
            invocation.* = .{ .position = helper_position, .inputs = helper_inputs };
        execution_mask = 0b1111;
    }
    invocations[lane] = .{ .position = position, .inputs = inputs };
    const observable_mask = @as(Runtime.LaneMask, 1) << lane;
    const result = try shaderWaveMasked(worker, &invocations, execution_mask, observable_mask);
    if ((result.discarded_mask & observable_mask) != 0)
        return SpvRuntimeError.Killed;
    if ((result.returned_mask & observable_mask) == 0)
        return SpvRuntimeError.InvalidSpirV;
    return result.laneResult(lane);
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
        var words: [255]u32 = @splat(0);
        if (binding.span.components == 0 or binding.span.components > words.len)
            return SpvRuntimeError.InvalidSpirV;
        const values = words[0..binding.span.components];
        switch (binding.semantic) {
            .location => {
                try validateLocation(binding);
                for (values, binding.words) |*value, word|
                    value.* = inputs.word(word.location, word.component);
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
        var words: [255]u32 = undefined;
        if (binding.span.components == 0 or binding.span.components > words.len)
            return SpvRuntimeError.InvalidSpirV;
        const values = words[0..binding.span.components];
        runtime.readOutput(program, InterfaceVariableId.fromIndex(index), values) catch |err| return mapError(err);
        switch (binding.semantic) {
            .location => {
                try validateLocation(binding);
                for (values, binding.words) |value, word| {
                    const offset = @as(usize, word.component) * @sizeOf(u32);
                    @memcpy(result.outputs[word.location][offset..][0..4], std.mem.asBytes(&value));
                }
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

fn writeInputsLane(
    program: *const Program,
    runtime: *Runtime,
    lane: usize,
    position: base.zm.F32x4,
    inputs: common.FragmentInputs,
) SpvRuntimeError!void {
    for (program.interfaces, 0..) |optional_binding, index| {
        const binding = optional_binding orelse continue;
        if (binding.direction != .input)
            continue;
        var words: [255]u32 = @splat(0);
        if (binding.span.components == 0 or binding.span.components > words.len)
            return SpvRuntimeError.InvalidSpirV;
        const values = words[0..binding.span.components];
        switch (binding.semantic) {
            .location => {
                try validateLocation(binding);
                for (values, binding.words) |*value, word|
                    value.* = inputs.word(word.location, word.component);
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
        runtime.writeInputLane(program, lane, InterfaceVariableId.fromIndex(index), values) catch |err| return mapError(err);
    }
}

const WaveOutputs = struct {
    outputs: rasterizer_common.FragmentWaveOutputs = undefined,
    output_components: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]u4 = @splat(0),
    depths: @Vector(Runtime.lane_count, f32) = @splat(0.0),
    depth_mask: Runtime.LaneMask = 0,
};

fn readOutputsWave(program: *const Program, runtime: *const Runtime) SpvRuntimeError!WaveOutputs {
    var result: WaveOutputs = .{};
    for (program.interfaces, 0..) |optional_binding, index| {
        const binding = optional_binding orelse continue;
        if (binding.direction != .output)
            continue;
        if (binding.span.components == 0)
            return SpvRuntimeError.InvalidSpirV;
        const variable = InterfaceVariableId.fromIndex(index);
        switch (binding.semantic) {
            .location => {
                try validateLocation(binding);
                for (binding.words, 0..) |word, component| {
                    result.outputs[word.location][word.component] =
                        runtime.readOutputVector(program, variable, component) catch |err| return mapError(err);
                    result.output_components[word.location] |= @as(u4, 1) << @intCast(word.component);
                }
            },
            .builtin => |builtin| switch (builtin) {
                .frag_depth => {
                    if (binding.span.kind != .floating or binding.span.components != 1)
                        return SpvRuntimeError.InvalidSpirV;
                    result.depths = @bitCast(runtime.readOutputVector(program, variable, 0) catch |err| return mapError(err));
                    result.depth_mask = Runtime.full_lane_mask;
                },
                else => return SpvRuntimeError.InvalidSpirV,
            },
        }
    }
    return result;
}

test "fragment IR invocation evaluates nonlinear FragCoord with helpers and masks their outputs" {
    if (comptime !base.config.soft_ir_interpreter) return;
    const ir = shader_ir.ir;
    var module = ir.module.Module.init(std.testing.allocator, .fragment);
    defer module.deinit();
    var builder = ir.Builder.init(&module);
    const void_type = try builder.internType(.void);
    const float_type = try builder.internType(.{ .floating = .{ .bits = 32 } });
    const vector_type = try builder.internType(.{ .vector = .{ .element_type = float_type, .length = 4 } });
    const coord = try builder.addInterfaceVariable(vector_type, .input, .{ .builtin = .frag_coord }, null);
    const color = try builder.addInterfaceVariable(vector_type, .output, .{ .location = .{ .location = 0 } }, null);
    const depth = try builder.addInterfaceVariable(float_type, .output, .{ .builtin = .frag_depth }, null);
    const function = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(function);
    const block = try builder.addBlock(function, "entry");
    const value = (try builder.appendInstruction(block, vector_type, .{ .load_interface = .{ .variable = coord } }, null)).?;
    const squared = (try builder.appendInstruction(block, vector_type, .{ .binary = .{ .opcode = .float_multiply, .lhs = value, .rhs = value } }, null)).?;
    const width = (try builder.appendInstruction(block, vector_type, .{ .unary = .{ .opcode = .fwidth, .operand = squared } }, null)).?;
    const z = (try builder.appendInstruction(block, float_type, .{ .composite_extract = .{ .composite = value, .indices = &.{2} } }, null)).?;
    _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = color, .value = width } }, null);
    _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = depth, .value = z } }, null);
    try builder.setTerminator(block, .return_void);
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var slot: Shader.RuntimeSlot = .{ .runtime = try Runtime.init(std.testing.allocator, &program) };
    defer slot.runtime.deinit();
    // This execution path only needs push constants and the mapped resource lists.
    var state: ExecutionDevice.PipelineState = undefined;
    state.push_constant_blob = @splat(0);
    var renderer: Renderer = undefined;
    renderer.state = &state;
    var draw_call: Renderer.DrawCall = undefined;
    draw_call.renderer = &renderer;
    draw_call.fragment_resources = .{};
    var worker: Worker = .{ .draw_call = &draw_call, .program = &program, .slot = &slot, .io = std.testing.io };
    var vertex = emptyTestVertex();
    const inputs = try rasterizer_common.interpolateVertexOutputs(std.testing.allocator, &vertex, &vertex, &vertex, &vertex, 1, 0, 0, 1, 0, 0);
    for (0..4) |lane| {
        const position = base.zm.f32x4(@as(f32, @floatFromInt(lane & 1)) + 0.5, @as(f32, @floatFromInt(lane >> 1)) + 0.5, 0.25, 1);
        const helpers = common.constantQuadHelpers(&worker, position, inputs).?;
        const result = try shaderInvocation(&worker, position, null, null, true, inputs, helpers);
        const expected = [4]f32{ 2, 2, 0, 0 };
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected), &result.outputs[0]);
        try std.testing.expectEqual(@as(?f32, 0.25), result.depth);
        var invocations: [Runtime.lane_count]WaveInvocation = undefined;
        for (invocations[0..4], helpers.quad_positions.?) |*invocation, helper_position|
            invocation.* = .{ .position = helper_position, .inputs = inputs };
        const mask = @as(Runtime.LaneMask, 1) << @intCast(lane);
        const wave = try shaderWaveMasked(&worker, &invocations, 0b1111, mask);
        try std.testing.expectEqual(mask, wave.returned_mask);
        try std.testing.expectEqual(mask, wave.depth_mask);
        try std.testing.expectEqual(@as(Runtime.LaneMask, 0), wave.discarded_mask);
    }
    try std.testing.expectError(SpvRuntimeError.InvalidSpirV, shaderInvocation(&worker, base.zm.f32x4(0.5, 0.5, 0.25, 1), null, null, true, inputs, null));
}

fn emptyInvocationResult() common.InvocationResult {
    return .{
        .outputs = std.mem.zeroes(@FieldType(common.InvocationResult, "outputs")),
        .depth = null,
        .sample_mask = null,
    };
}

fn validateLocation(binding: Program.InterfaceBinding) SpvRuntimeError!void {
    if (!binding.validLocation())
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

test "fragment aggregate inputs interpolate and outputs scatter in scalar and wave paths" {
    const ir = shader_ir.ir;
    var module = ir.module.Module.init(std.testing.allocator, .fragment);
    defer module.deinit();
    var builder = ir.Builder.init(&module);
    const void_type = try builder.internType(.void);
    const float = try builder.internType(.{ .floating = .{ .bits = 32 } });
    const vec2 = try builder.internType(.{ .vector = .{ .element_type = float, .length = 2 } });
    const vec4 = try builder.internType(.{ .vector = .{ .element_type = float, .length = 4 } });
    const array = try builder.internType(.{ .array = .{ .element_type = vec4, .length = 3 } });
    const array2 = try builder.internType(.{ .array = .{ .element_type = vec2, .length = 2 } });
    const matrix = try builder.internType(.{ .matrix = .{ .element_type = vec2, .column_count = 3 } });
    const types = [_]ir.id.TypeId{ array, array2, matrix };
    var inputs_ids: [3]ir.id.InterfaceVariableId = undefined;
    var outputs_ids: [3]ir.id.InterfaceVariableId = undefined;
    for (types, 0..) |ty, i| {
        const first: u32 = @intCast(i * 4);
        const component: u8 = if (i == 0) 0 else 2;
        inputs_ids[i] = try builder.addInterfaceVariable(ty, .input, .{ .location = .{ .location = first, .component = component } }, null);
        outputs_ids[i] = try builder.addInterfaceVariable(ty, .output, .{ .location = .{ .location = first, .component = component } }, null);
    }
    const function = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(function);
    const block = try builder.addBlock(function, "entry");
    for (types, inputs_ids, outputs_ids) |ty, input, output| {
        const value = (try builder.appendInstruction(block, ty, .{ .load_interface = .{ .variable = input } }, null)).?;
        _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = output, .value = value } }, null);
    }
    try builder.setTerminator(block, .return_void);
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    var vertices = [_]Renderer.Vertex{ emptyTestVertex(), emptyTestVertex(), emptyTestVertex() };
    for (outputs_ids) |output| {
        for (program.interfaceBinding(output).?.words, 0..) |word, i| {
            for (&vertices, 0..) |*vertex, v| {
                const value: f32 = @floatFromInt(i + v * 4);
                setTestOutput(vertex, word.location, word.component, @bitCast(value), .smooth);
            }
        }
    }
    const inputs = try rasterizer_common.interpolateVertexOutputs(std.testing.allocator, &vertices[0], &vertices[1], &vertices[2], &vertices[0], 0.25, 0.25, 0.5, 0.25, 0.25, 0.5);
    runtime.resetInvocation(&program);
    try writeInputs(&program, &runtime, @splat(0), inputs);
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    const scalar = try readOutputs(&program, &runtime);
    runtime.resetWave(&program, Runtime.full_lane_mask, Runtime.full_lane_mask);
    for (0..Runtime.lane_count) |lane| try writeInputsLane(&program, &runtime, lane, @splat(0), inputs);
    _ = try runtime.runWave(&program, .{});
    const wave = try readOutputsWave(&program, &runtime);
    for (outputs_ids) |output| {
        for (program.interfaceBinding(output).?.words, 0..) |word, i| {
            const expected: f32 = @as(f32, @floatFromInt(i)) + 5.0;
            const offset = @as(usize, word.component) * 4;
            try std.testing.expectEqual(@as(u32, @bitCast(expected)), std.mem.bytesToValue(u32, scalar.outputs[word.location][offset..][0..4]));
            try std.testing.expect(wave.output_components[word.location] & (@as(u4, 1) << @intCast(word.component)) != 0);
            inline for (0..Runtime.lane_count) |lane| try std.testing.expectEqual(@as(u32, @bitCast(expected)), wave.outputs[word.location][word.component][lane]);
        }
    }
}
