const std = @import("std");
const shader_ir = @import("shader_ir");

const bc = @import("../bytecode.zig");
const Program = @import("../Program.zig");
const Runtime = @import("../Runtime.zig");

const ids = shader_ir.ir.id;

fn reg(index: u16) bc.Register {
    return @enumFromInt(index);
}

fn makeProgram(
    register_count: usize,
    code: []const bc.Instruction,
    initializers: []const Program.RegisterInit,
    resources: []const ?Program.ResourceBinding,
    descriptor_arrays: []const Program.DescriptorArray,
) Program {
    return .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .stage = .compute,
        .uses_atomics = false,
        .uses_control_barriers = false,
        .workgroup_memory_size = 0,
        .entry_pc = 0,
        .register_count = register_count,
        .scratch_count = 0,
        .array_lengths = &.{},
        .descriptor_arrays = descriptor_arrays,
        .image_sampler_pairs = &.{},
        .code = code,
        .edges = &.{},
        .copies = &.{},
        .branches = &.{},
        .initializers = initializers,
        .interfaces = &.{},
        .resources = resources,
        .workgroup_variables = &.{},
    };
}

test "[interpreter] push constant load is bounds-checked little-endian" {
    const code = [_]bc.Instruction{
        .{ .opcode = .load_push_constant, .components = 2, .a = reg(1), .b = reg(0) },
        .{ .opcode = .store_buffer, .components = 2, .a = reg(1), .b = reg(3), .immediate = 0 },
        .{ .opcode = .return_void },
    };
    const initializers = [_]Program.RegisterInit{
        .{ .register = reg(0), .value = 1 },
        .{ .register = reg(3), .value = 0 },
    };
    const resources = [_]?Program.ResourceBinding{
        .{ .kind = .storage_buffer, .set = 0, .binding = 0, .array_element = 0 },
    };

    var program = makeProgram(4, &code, &initializers, &resources, &.{});
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    const push_constants = [_]u8{ 0xff, 0x78, 0x56, 0x34, 0x12, 0xef, 0xcd, 0xab, 0x90 };
    var destination = [_]u8{0xcc} ** 8;
    const resource_buffers = [_]?[]u8{destination[0..]};

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{
        .push_constants = &push_constants,
        .resource_buffers = &resource_buffers,
    }));
    try std.testing.expectEqualSlices(u8, push_constants[1..9], &destination);

    runtime.resetInvocation(&program);
    @memset(&destination, 0xcc);
    try std.testing.expectError(Runtime.RuntimeError.BufferOutOfBounds, runtime.run(&program, .{
        .push_constants = push_constants[0..8],
        .resource_buffers = &resource_buffers,
    }));
    try std.testing.expectEqualSlices(u8, &([_]u8{0xcc} ** 8), &destination);
}

const dynamic_code = [_]bc.Instruction{
    .{ .opcode = .load_buffer, .a = reg(2), .b = reg(1), .c = reg(0), .immediate = 0 },
    .{ .opcode = .store_buffer, .a = reg(2), .b = reg(1), .c = reg(0), .immediate = 1 },
    .{ .opcode = .return_void },
};

const dynamic_resources = [_]?Program.ResourceBinding{
    .{ .kind = .storage_buffer, .set = 0, .binding = 4, .array_element = 0 },
    .{ .kind = .storage_buffer, .set = 1, .binding = 7, .array_element = 1 },
    .{ .kind = .storage_buffer, .set = 0, .binding = 4, .array_element = 1 },
    .{ .kind = .storage_buffer, .set = 1, .binding = 7, .array_element = 0 },
};

const source_candidates = [_]Program.DescriptorCandidate{
    .{ .array_element = 0, .resource = ids.ResourceId.fromIndex(0) },
    .{ .array_element = 1, .resource = ids.ResourceId.fromIndex(2) },
};

const destination_candidates = [_]Program.DescriptorCandidate{
    .{ .array_element = 0, .resource = ids.ResourceId.fromIndex(3) },
    .{ .array_element = 1, .resource = ids.ResourceId.fromIndex(1) },
};

const dynamic_descriptor_arrays = [_]Program.DescriptorArray{
    .{ .candidates = &source_candidates },
    .{ .candidates = &destination_candidates },
};

fn makeDynamicProgram(array_element: u32) Program {
    const initializers = struct {
        const zero = [_]Program.RegisterInit{
            .{ .register = reg(0), .value = 0 },
            .{ .register = reg(1), .value = 0 },
        };
        const one = [_]Program.RegisterInit{
            .{ .register = reg(0), .value = 1 },
            .{ .register = reg(1), .value = 0 },
        };
        const two = [_]Program.RegisterInit{
            .{ .register = reg(0), .value = 2 },
            .{ .register = reg(1), .value = 0 },
        };
    };

    const selected = switch (array_element) {
        0 => &initializers.zero,
        1 => &initializers.one,
        else => &initializers.two,
    };
    return makeProgram(3, &dynamic_code, selected, &dynamic_resources, &dynamic_descriptor_arrays);
}

test "[interpreter] dynamic buffer load and store select explicit array elements" {
    var program = makeDynamicProgram(1);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    var source = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    var destination = [_]u8{0} ** 4;
    const resource_buffers = [_]?[]u8{
        null,
        destination[0..],
        source[0..],
        null,
    };

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{
        .resource_buffers = &resource_buffers,
    }));
    try std.testing.expectEqualSlices(u8, &source, &destination);
}

test "[interpreter] dynamic buffer access fails only when selected descriptor is null" {
    var program = makeDynamicProgram(1);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    var destination = [_]u8{0} ** 4;
    const resource_buffers = [_]?[]u8{
        null,
        destination[0..],
        null,
        null,
    };

    try std.testing.expectError(Runtime.RuntimeError.ResourceNotBound, runtime.run(&program, .{
        .resource_buffers = &resource_buffers,
    }));
}

test "[interpreter] dynamic buffer descriptor index rejects missing array element" {
    var program = makeDynamicProgram(2);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    try std.testing.expectError(Runtime.RuntimeError.InvalidResource, runtime.run(&program, .{}));
}
