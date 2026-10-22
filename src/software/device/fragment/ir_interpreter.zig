const std = @import("std");
const base = @import("base");
const spv = @import("spv");
const shader_ir = @import("shader_ir");

const ExecutionDevice = @import("../Device.zig");
const Renderer = @import("../Renderer.zig");
const Program = @import("../../interpreter/Program.zig");
const Runtime = @import("../../interpreter/Runtime.zig");
const Shader = @import("../../interpreter/Shader.zig");
const SoftBufferView = @import("../../SoftBufferView.zig");
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
            // Texel-buffer bindings have a per-worker lifetime, separate from image views
            .uniform_texel_buffer, .storage_texel_buffer => {},
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
    resource_texel_buffers: []?*SoftBufferView = &.{},
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
        if (self.resource_texel_buffers.len != 0)
            self.draw_call.renderer.device.interface.device_allocator.allocator().free(self.resource_texel_buffers);
        self.resource_texel_buffers = &.{};
        self.slot.mutex.unlock(self.io);
    }
};

pub fn acquireWorker(draw_call: *Renderer.DrawCall, batch_id: usize) VkError!Worker {
    const pipeline = draw_call.renderer.state.pipeline orelse return VkError.InvalidPipelineDrv;
    const shader = pipeline.stages.getPtr(.fragment) orelse return VkError.InvalidPipelineDrv;
    if (batch_id >= shader.runtimes.len)
        return VkError.InvalidPipelineDrv;

    const allocator = draw_call.renderer.device.interface.device_allocator.allocator();
    const resource_texel_buffers = allocator.alloc(?*SoftBufferView, shader.program.resources.len) catch return VkError.OutOfDeviceMemory;
    errdefer allocator.free(resource_texel_buffers);
    @memset(resource_texel_buffers, null);

    for (shader.program.resources, resource_texel_buffers) |optional_resource, *buffer_view| {
        const resource = optional_resource orelse continue;
        if (resource.kind == .uniform_texel_buffer or resource.kind == .storage_texel_buffer)
            buffer_view.* = try ExecutionDevice.mapTexelBuffer(draw_call.renderer.state, resource.set, resource.binding, resource.array_element);
    }

    const io = draw_call.renderer.device.interface.io();
    const slot = &shader.runtimes[batch_id];
    slot.mutex.lock(io) catch return VkError.DeviceLost;
    return .{
        .draw_call = draw_call,
        .program = &shader.program,
        .slot = slot,
        .io = io,
        .resource_texel_buffers = resource_texel_buffers,
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

pub fn shaderWaveMasked(worker: *Worker, invocations: *const [Runtime.lane_count]WaveInvocation, execution_mask: Runtime.LaneMask, mask: Runtime.LaneMask) SpvRuntimeError!WaveResult {
    const draw_call = worker.draw_call;
    const state = draw_call.renderer.state;
    const program = worker.program;
    const runtime = &worker.slot.runtime;
    runtime.resetWave(program, execution_mask, mask);

    const resources = draw_call.fragment_resources;
    if (resources.buffers.len != program.resources.len or
        worker.resource_texel_buffers.len != program.resources.len or
        resources.images.len != program.resources.len or
        resources.samplers.len != program.resources.len)
        return SpvRuntimeError.InvalidSpirV;

    // SAFETY: only read when soft_profile is enabled at comptime, which also initializes the timer
    const input_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(worker.io, .real) else undefined;
    for (0..Runtime.lane_count) |lane| {
        const bit = @as(Runtime.LaneMask, 1) << @intCast(lane);
        if ((execution_mask & bit) != 0)
            try writeInputsLane(program, runtime, lane, invocations[lane].position, invocations[lane].inputs);
    }
    if (comptime base.config.soft_profile)
        worker.input_ns += Renderer.profileElapsedNs(input_timer, worker.io);

    // SAFETY: only read when soft_profile is enabled at comptime, which also initializes the timer
    const shader_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(worker.io, .real) else undefined;
    const outcome = runtime.runWave(program, .{
        .resource_buffers = resources.buffers,
        .resource_texel_buffers = worker.resource_texel_buffers,
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

    // SAFETY: only read when soft_profile is enabled at comptime, which also initializes the timer
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
    outputs: rasterizer_common.FragmentWaveOutputs,
    output_components: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]u4 = @splat(0),
    depths: @Vector(Runtime.lane_count, f32) = @splat(0.0),
    depth_mask: Runtime.LaneMask = 0,
};

fn readOutputsWave(program: *const Program, runtime: *const Runtime) SpvRuntimeError!WaveOutputs {
    // SAFETY: each output vector is initialized before its output_components bit is set; consumers only read marked components
    var result: WaveOutputs = .{ .outputs = undefined };
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
