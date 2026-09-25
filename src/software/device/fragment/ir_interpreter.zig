const std = @import("std");
const base = @import("base");
const spv = @import("spv");
const shader_ir = @import("shader_ir");

const ExecutionDevice = @import("../Device.zig");
const Renderer = @import("../Renderer.zig");
const Program = @import("../../interpreter/Program.zig");
const Runtime = @import("../../interpreter/Runtime.zig");
const SoftImageView = @import("../../SoftImageView.zig");
const VertexInterpolationLocation = @import("../rasterizer/common.zig").VertexInterpolationLocation;
const common = @import("dispatcher.zig");
const SpvRuntimeError = common.SpvRuntimeError;
const InterfaceVariableId = shader_ir.ir.id.InterfaceVariableId;

pub fn shaderInvocation(
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    batch_id: usize,
    position: base.zm.F32x4,
    point_coord: ?@Vector(2, f32),
    sample_id: ?u32,
    front_face: bool,
    inputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation,
    derivative_inputs: ?common.DerivativeInputs,
) SpvRuntimeError!common.InvocationResult {
    defer common.freeOwnedInputs(allocator, inputs);
    defer if (derivative_inputs) |derivatives| {
        common.freeOwnedInputs(allocator, derivatives.dx);
        common.freeOwnedInputs(allocator, derivatives.dy);
    };

    // The current IR has no derivative instructions or point/sample/facing builtins.
    _ = point_coord;
    _ = sample_id;
    _ = front_face;

    const state = draw_call.renderer.state;
    const pipeline = state.pipeline orelse return SpvRuntimeError.InvalidSpirV;
    const shader = pipeline.stages.getPtr(.fragment) orelse return SpvRuntimeError.InvalidSpirV;
    if (batch_id >= shader.runtimes.len)
        return SpvRuntimeError.OutOfBounds;
    const program = &shader.program;
    if (program.stage != .fragment or program.uses_control_barriers or program.workgroup_memory_size != 0)
        return SpvRuntimeError.InvalidSpirV;

    const io = draw_call.renderer.device.interface.io();
    const slot = &shader.runtimes[batch_id];
    slot.mutex.lock(io) catch return SpvRuntimeError.Unknown;
    defer slot.mutex.unlock(io);
    const runtime = &slot.runtime;
    runtime.resetInvocation(program);

    const buffers = allocator.alloc(?[]u8, program.resources.len) catch return SpvRuntimeError.OutOfMemory;
    defer allocator.free(buffers);
    @memset(buffers, null);
    const images = allocator.alloc(?*SoftImageView, program.resources.len) catch return SpvRuntimeError.OutOfMemory;
    defer allocator.free(images);
    @memset(images, null);
    for (program.resources, buffers, images) |optional_resource, *buffer, *image| {
        const resource = optional_resource orelse continue;
        switch (resource.kind) {
            .uniform_buffer, .storage_buffer => buffer.* = ExecutionDevice.mapBuffer(state, resource.set, resource.binding, resource.array_element) catch |err| return mapError(err),
            .storage_image => image.* = ExecutionDevice.mapStorageImage(state, resource.set, resource.binding, resource.array_element) catch |err| return mapError(err),
            else => return SpvRuntimeError.InvalidSpirV,
        }
    }
    // RunOptions currently has no push-constant or derivative storage.
    try writeInputs(program, runtime, position, inputs);
    switch (runtime.run(program, .{ .resource_buffers = buffers, .resource_images = images }) catch |err| return mapError(err)) {
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
    inputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation,
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
                try readLocation(inputs[location.location], location.component, values);
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

fn readLocation(location: VertexInterpolationLocation, component: usize, values: []u32) SpvRuntimeError!void {
    // A rasterizer blob starts at its declared component, and can contain a whole
    // vector. Resolve each lane so both packed vectors and split varyings work.
    for (values, component..) |*value, lane| {
        value.* = 0;
        var source_component = lane + 1;
        while (source_component != 0) {
            source_component -= 1;
            const input = location[source_component];
            if (input.size > input.blob.len)
                return SpvRuntimeError.InvalidSpirV;
            const offset = (lane - source_component) * @sizeOf(u32);
            if (offset <= input.size and input.size - offset >= @sizeOf(u32)) {
                value.* = @bitCast(input.blob[offset..][0..4].*);
                break;
            }
        }
    }
}

fn mapError(err: anyerror) SpvRuntimeError {
    return switch (err) {
        error.OutOfMemory, error.OutOfDeviceMemory, error.OutOfHostMemory => SpvRuntimeError.OutOfMemory,
        error.BufferOutOfBounds => SpvRuntimeError.OutOfBounds,
        error.DeviceLost => SpvRuntimeError.Unknown,
        else => SpvRuntimeError.InvalidSpirV,
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
    const empty: @import("../rasterizer/common.zig").VertexInterpolation = .{ .blob = &.{}, .size = 0, .free_responsability = false };
    var inputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation = @splat(@splat(empty));
    const varying_data = [4]f32{ 0.25, -0.5, 0.75, 1.0 };
    const scalar_data: f32 = 0.625;
    inputs[2][0] = .{ .blob = std.mem.asBytes(&varying_data), .size = @sizeOf(@TypeOf(varying_data)), .free_responsability = false };
    inputs[4][2] = .{ .blob = std.mem.asBytes(&scalar_data), .size = @sizeOf(f32), .free_responsability = false };

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
        inputs = @splat(@splat(empty));
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
    const empty: @import("../rasterizer/common.zig").VertexInterpolation = .{ .blob = &.{}, .size = 0, .free_responsability = false };
    runtime.resetInvocation(&program);
    try writeInputs(&program, &runtime, base.zm.f32x4(0.5, 0.5, 0.25, 1.0), @splat(@splat(empty)));
    try std.testing.expectEqual(Runtime.Outcome.discarded, try runtime.run(&program, .{}));
}

test "fragment IR reads packed and component-split locations" {
    const packed_values = [4]u32{ 10, 20, 30, 40 };
    const split: u32 = 99;
    const empty: @import("../rasterizer/common.zig").VertexInterpolation = .{ .blob = &.{}, .size = 0, .free_responsability = false };
    var location: VertexInterpolationLocation = @splat(empty);
    location[0] = .{ .blob = std.mem.asBytes(&packed_values), .size = @sizeOf(@TypeOf(packed_values)), .free_responsability = false };
    location[2] = .{ .blob = std.mem.asBytes(&split), .size = @sizeOf(u32), .free_responsability = false };
    var values: [3]u32 = undefined;
    try readLocation(location, 1, &values);
    try std.testing.expectEqualSlices(u32, &.{ 20, 99, 40 }, &values);
    location = @splat(empty);
    try readLocation(location, 1, &values);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, &values);
}
