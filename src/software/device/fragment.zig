const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;
const spv = @import("spv");

const VertexInterpolationLocation = @import("rasterizer/common.zig").VertexInterpolationLocation;

const Renderer = @import("Renderer.zig");
const SoftImage = @import("../SoftImage.zig");

const VkError = base.VkError;
const SpvRuntimeError = spv.Runtime.RuntimeError;
const INTERFACE_BLOB_PADDING = @sizeOf(zm.F32x4);

pub const InvocationResult = struct {
    outputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(zm.F32x4)]u8,
    depth: ?f32,
    sample_mask: ?vk.SampleMask,
};

pub const DerivativeInputs = struct {
    dx: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation,
    dy: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation,
};

pub fn shaderInvocation(
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    batch_id: usize,
    position: zm.F32x4,
    point_coord: ?@Vector(2, f32),
    sample_id: ?u32,
    front_face: bool,
    inputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation,
    derivative_inputs: ?DerivativeInputs,
) SpvRuntimeError!InvocationResult {
    var fragment_inputs = inputs;
    errdefer freeOwnedInputs(allocator, fragment_inputs);

    const derivatives = derivative_inputs;
    errdefer if (derivatives) |owned_derivatives| {
        freeOwnedInputs(allocator, owned_derivatives.dx);
        freeOwnedInputs(allocator, owned_derivatives.dy);
    };

    const io = draw_call.renderer.device.interface.io();

    const pipeline = draw_call.renderer.state.pipeline orelse return undefined;

    const shader = pipeline.stages.getPtr(.fragment) orelse return undefined;
    const runtime = &shader.runtimes[batch_id];
    const mutex = &runtime.mutex;
    const rt = &runtime.rt;

    mutex.lock(io) catch return SpvRuntimeError.Unknown;
    defer mutex.unlock(io);

    rt.resetInvocation(allocator);
    try rt.populatePushConstants(draw_call.renderer.state.push_constant_blob[0..]);
    rt.writeBuiltIn(allocator, std.mem.asBytes(&position), .FragCoord) catch |err| switch (err) {
        SpvRuntimeError.NotFound => {},
        else => return err,
    };
    if (point_coord) |coord| {
        rt.writeBuiltIn(allocator, std.mem.asBytes(&coord), .PointCoord) catch |err| switch (err) {
            SpvRuntimeError.NotFound => {},
            else => return err,
        };
    }
    if (sample_id) |id| {
        const sample_id_i32: i32 = @intCast(id);
        rt.writeBuiltIn(allocator, std.mem.asBytes(&sample_id_i32), .SampleId) catch |err| switch (err) {
            SpvRuntimeError.NotFound => {},
            else => return err,
        };
    }
    rt.writeBuiltIn(allocator, std.mem.asBytes(&front_face), .FrontFacing) catch |err| switch (err) {
        SpvRuntimeError.NotFound => {},
        else => return err,
    };

    const SoftPipeline = @import("../SoftPipeline.zig");
    const previous_fragment_coord = SoftPipeline.current_fragment_coord;
    SoftPipeline.current_fragment_coord = .{
        .x = @intFromFloat(position[0]),
        .y = @intFromFloat(position[1]),
        .z = 0,
    };
    defer SoftPipeline.current_fragment_coord = previous_fragment_coord;

    const entry = try rt.getEntryPointByName(shader.entry);

    for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
        for (0..4) |component| {
            var input = fragment_inputs[location][component];
            const result_word = rt.getResultByLocationComponent(@intCast(location), @intCast(component), .input) catch |err| switch (err) {
                SpvRuntimeError.NotFound => {
                    if (input.blob.len != 0) {
                        rt.writeInputLocation(input.blob, @intCast(location)) catch |write_err| switch (write_err) {
                            SpvRuntimeError.NotFound => {},
                            else => return write_err,
                        };
                    }
                    continue;
                },
                else => return err,
            };

            const has_result_value = rt.results[result_word].variant != null;
            const memory_size = if (has_result_value)
                try rt.getResultMemorySize(result_word)
            else if (input.blob.len == 0)
                try rt.getInputLocationMemorySize(@intCast(location))
            else
                input.blob.len;
            if (input.blob.len == 0) {
                const zeroes = allocator.alloc(u8, memory_size + INTERFACE_BLOB_PADDING) catch return SpvRuntimeError.OutOfMemory;
                @memset(zeroes, 0);
                fragment_inputs[location][component] = .{
                    .blob = zeroes,
                    .size = memory_size,
                    .free_responsability = true,
                };
                input = fragment_inputs[location][component];
            }

            if (input.blob.len != 0) {
                if (!has_result_value or input.blob.len < memory_size)
                    try rt.writeInputLocation(input.blob, @intCast(location))
                else
                    try rt.writeInput(allocator, input.blob, result_word);
                if (derivatives) |derivative| {
                    const dx = derivative.dx[location][component];
                    const dy = derivative.dy[location][component];
                    if (dx.blob.len != 0 and dy.blob.len != 0) {
                        try rt.setDerivativeFromMemory(allocator, result_word, dx.blob, dy.blob);
                    }
                }
            }
        }
    }

    rt.callEntryPoint(allocator, entry) catch |err| switch (err) {
        // Some errors can be safely ignored
        SpvRuntimeError.OutOfBounds => {},
        SpvRuntimeError.Killed => {
            try rt.flushDescriptorSets(allocator);
            return SpvRuntimeError.Killed;
        },
        else => return err,
    };

    var outputs = std.mem.zeroes([spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(zm.F32x4)]u8);

    for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
        var has_split_components = false;
        for (1..4) |component| {
            _ = rt.getResultByLocationComponent(@intCast(location), @intCast(component), .output) catch |err| switch (err) {
                SpvRuntimeError.NotFound => continue,
                else => return err,
            };
            has_split_components = true;
            break;
        }

        if (has_split_components) {
            for (0..4) |component| {
                const result_word = rt.getResultByLocationComponent(@intCast(location), @intCast(component), .output) catch |err| switch (err) {
                    SpvRuntimeError.NotFound => continue,
                    else => return err,
                };
                try readFragmentOutput(allocator, rt, &outputs, location, component, result_word);
            }
            continue;
        }

        const result_word = rt.getResultByLocation(@intCast(location), .output) catch |err| switch (err) {
            SpvRuntimeError.NotFound => continue,
            else => return err,
        };
        try readFragmentOutput(allocator, rt, &outputs, location, 0, result_word);
    }

    var depth: ?f32 = null;
    var frag_depth: f32 = undefined;
    if (rt.readBuiltIn(std.mem.asBytes(&frag_depth), .FragDepth)) {
        depth = frag_depth;
    } else |err| switch (err) {
        SpvRuntimeError.InvalidSpirV, SpvRuntimeError.NotFound => {},
        else => return err,
    }

    var sample_mask: ?vk.SampleMask = null;
    var frag_sample_mask: [1]vk.SampleMask = undefined;
    if (rt.readBuiltIn(std.mem.asBytes(&frag_sample_mask), .SampleMask)) {
        sample_mask = frag_sample_mask[0];
    } else |err| switch (err) {
        SpvRuntimeError.InvalidSpirV, SpvRuntimeError.NotFound => {},
        else => return err,
    }

    try rt.flushDescriptorSets(allocator);
    freeOwnedInputs(allocator, fragment_inputs);
    if (derivatives) |owned_derivatives| {
        freeOwnedInputs(allocator, owned_derivatives.dx);
        freeOwnedInputs(allocator, owned_derivatives.dy);
    }

    return .{
        .outputs = outputs,
        .depth = depth,
        .sample_mask = sample_mask,
    };
}

fn readFragmentOutput(
    allocator: std.mem.Allocator,
    rt: anytype,
    outputs: *[spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(zm.F32x4)]u8,
    location: usize,
    component: usize,
    result_word: spv.SpvWord,
) SpvRuntimeError!void {
    const value = try rt.results[result_word].getConstValue();
    switch (value.*) {
        .Array => |array| {
            for (array.values, 0..) |element, element_index| {
                const target_location = location + element_index;
                if (target_location >= outputs.len)
                    return SpvRuntimeError.OutOfBounds;

                const memory_size = try element.getPlainMemorySize();
                const output = allocator.alloc(u8, memory_size + INTERFACE_BLOB_PADDING) catch return SpvRuntimeError.OutOfMemory;
                defer allocator.free(output);
                @memset(output, 0);

                _ = try element.read(output);
                try copyFragmentOutputBytes(outputs, output[0..memory_size], target_location, component);
            }
            return;
        },
        else => {},
    }

    const memory_size = try rt.getResultMemorySize(result_word);
    if (memory_size <= INTERFACE_BLOB_PADDING) {
        var output = std.mem.zeroes([INTERFACE_BLOB_PADDING]u8);
        try rt.readOutput(output[0..memory_size], result_word);
        try copyFragmentOutputBytes(outputs, output[0..memory_size], location, component);
        return;
    }

    const output = allocator.alloc(u8, memory_size + INTERFACE_BLOB_PADDING) catch return SpvRuntimeError.OutOfMemory;
    defer allocator.free(output);
    @memset(output, 0);

    try rt.readOutput(output[0..memory_size], result_word);
    try copyFragmentOutputBytes(outputs, output[0..memory_size], location, component);
}

fn copyFragmentOutputBytes(
    outputs: *[spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(zm.F32x4)]u8,
    output: []const u8,
    location: usize,
    component: usize,
) SpvRuntimeError!void {
    const memory_size = output.len;
    const offset = component * @sizeOf(f32);
    const location_size = @sizeOf(zm.F32x4);
    const direct_capacity = location_size - offset;

    if (memory_size <= direct_capacity) {
        @memcpy(outputs[location][offset .. offset + memory_size], output);
        return;
    }

    var source_offset: usize = 0;
    var target_location = location;
    var target_offset = offset;
    while (source_offset < memory_size and target_location < outputs.len) {
        const copy_size = @min(memory_size - source_offset, location_size - target_offset);
        @memcpy(
            outputs[target_location][target_offset .. target_offset + copy_size],
            output[source_offset .. source_offset + copy_size],
        );
        source_offset += copy_size;
        target_location += 1;
        target_offset = 0;
    }

    if (source_offset != memory_size)
        return SpvRuntimeError.OutOfBounds;
}

fn freeOwnedInputs(allocator: std.mem.Allocator, inputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation) void {
    for (inputs) |location| {
        for (location) |input| {
            if (input.free_responsability)
                allocator.free(input.blob);
        }
    }
}
