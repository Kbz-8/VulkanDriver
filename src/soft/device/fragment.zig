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

pub const DerivativeInputs = struct {
    dx: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation,
    dy: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation,
};

pub fn shaderInvocation(
    allocator: std.mem.Allocator,
    draw_call: *Renderer.DrawCall,
    batch_id: usize,
    position: zm.F32x4,
    front_face: bool,
    inputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation,
    derivative_inputs: ?DerivativeInputs,
) SpvRuntimeError![spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(zm.F32x4)]u8 {
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
    rt.writeBuiltIn(std.mem.asBytes(&position), .FragCoord) catch |err| switch (err) {
        SpvRuntimeError.NotFound => {},
        else => return err,
    };
    rt.writeBuiltIn(std.mem.asBytes(&front_face), .FrontFacing) catch |err| switch (err) {
        SpvRuntimeError.NotFound => {},
        else => return err,
    };

    const entry = try rt.getEntryPointByName(shader.entry);

    for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
        for (0..4) |component| {
            const result_word = rt.getResultByLocationComponent(@intCast(location), @intCast(component), .input) catch |err| switch (err) {
                SpvRuntimeError.NotFound => continue,
                else => return err,
            };

            var input = fragment_inputs[location][component];
            if (input.blob.len == 0) {
                const memory_size = try rt.getResultMemorySize(result_word);
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
                try rt.writeInput(input.blob, result_word);
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
            freeOwnedInputs(allocator, fragment_inputs);
            return undefined; // FIXME
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

    try rt.flushDescriptorSets(allocator);
    freeOwnedInputs(allocator, fragment_inputs);
    if (derivatives) |owned_derivatives| {
        freeOwnedInputs(allocator, owned_derivatives.dx);
        freeOwnedInputs(allocator, owned_derivatives.dy);
    }

    return outputs;
}

fn readFragmentOutput(
    allocator: std.mem.Allocator,
    rt: anytype,
    outputs: *[spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(zm.F32x4)]u8,
    location: usize,
    component: usize,
    result_word: spv.SpvWord,
) SpvRuntimeError!void {
    const memory_size = try rt.getResultMemorySize(result_word);
    const offset = component * @sizeOf(f32);
    const location_size = @sizeOf(zm.F32x4);
    const direct_capacity = location_size - offset;

    if (memory_size <= direct_capacity) {
        try rt.readOutput(outputs[location][offset .. offset + memory_size], result_word);
        return;
    }

    const output = allocator.alloc(u8, memory_size + INTERFACE_BLOB_PADDING) catch return SpvRuntimeError.OutOfMemory;
    defer allocator.free(output);
    @memset(output, 0);

    try rt.readOutput(output, result_word);

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
