const std = @import("std");

const ids = @import("../../ir/id.zig");
const instruction = @import("../../ir/instruction.zig");
const operand = @import("../../ir/operand.zig");
const program_ir = @import("../../ir/program.zig");

pub const Error = std.mem.Allocator.Error || error{
    BlockParametersNotLowered,
    ParallelCopiesNotLowered,
    InvalidProgram,
    OutOfRegisters,
};

pub fn run(allocator: std.mem.Allocator, program: *program_ir.Program) Error!void {
    if (!program.properties.block_parameters_lowered)
        return error.BlockParametersNotLowered;
    if (!program.properties.parallel_copies_lowered)
        return error.ParallelCopiesNotLowered;
    if (program.properties.registers_allocated)
        return;

    const grf_size = program.device_info.grf_size_bytes;
    if (grf_size == 0)
        return error.InvalidProgram;

    const allocations = try allocator.alloc(?operand.PhysicalGrf, program.virtual_registers.entries.items.len);
    defer allocator.free(allocations);
    @memset(allocations, null);

    var next_byte: usize = @as(usize, program.program_data.payload_grf_count) * grf_size;
    next_byte = try reserveExistingPhysicalRegisters(program, next_byte, grf_size);
    const capacity: usize = @as(usize, program.device_info.grf_count) * grf_size;

    for (program.virtual_registers.entries.items, 0..) |entry, index| {
        const register = entry orelse continue;
        const start = std.mem.alignForward(usize, next_byte, register.alignment_bytes);
        const end = std.math.add(usize, start, register.size_bytes) catch return error.OutOfRegisters;
        if (end > capacity)
            return error.OutOfRegisters;

        allocations[index] = .{
            .number = @intCast(start / grf_size),
            .byte_offset = @intCast(start % grf_size),
        };
        next_byte = end;
    }

    try rewriteProgram(program, allocations);
    program.program_data.total_grf_count = @intCast(std.math.divCeil(usize, next_byte, grf_size) catch return error.InvalidProgram);
    program.properties.registers_allocated = true;
}

fn reserveExistingPhysicalRegisters(program: *const program_ir.Program, initial: usize, grf_size: usize) Error!usize {
    var next_byte = initial;
    if (program.payload.header_grf) |header|
        reservePhysical(&next_byte, header, grf_size);

    for (program.instructions.entries.items) |entry| {
        const inst = entry orelse continue;
        switch (inst.operation) {
            .load_global_invocation_id => |op| reserveRegister(&next_byte, op.destination.register, grf_size),
            .load_buffer => |op| {
                reserveRegister(&next_byte, op.destination.register, grf_size);
                reserveRegister(&next_byte, op.byte_offset.register, grf_size);
            },
            .store_buffer => |op| {
                reserveRegister(&next_byte, op.byte_offset.register, grf_size);
                reserveRegister(&next_byte, op.source.register, grf_size);
            },
            .surface_read => |op| {
                reserveRegister(&next_byte, op.destination.register, grf_size);
                reserveRegister(&next_byte, op.address.register, grf_size);
            },
            .surface_write => |op| {
                reserveRegister(&next_byte, op.address.register, grf_size);
                reserveRegister(&next_byte, op.data.register, grf_size);
            },
            .move => |op| {
                reserveRegister(&next_byte, op.destination.register, grf_size);
                reserveRegister(&next_byte, op.source.register, grf_size);
            },
            .binary => |op| {
                reserveRegister(&next_byte, op.destination.register, grf_size);
                reserveRegister(&next_byte, op.lhs.register, grf_size);
                reserveRegister(&next_byte, op.rhs.register, grf_size);
            },
            .compare => |op| {
                reserveRegister(&next_byte, op.lhs.register, grf_size);
                reserveRegister(&next_byte, op.rhs.register, grf_size);
            },
            .parallel_copy => return error.ParallelCopiesNotLowered,
        }
    }
    return next_byte;
}

fn reserveRegister(next_byte: *usize, register: operand.RegisterRef, grf_size: usize) void {
    switch (register) {
        .physical_grf => |physical| reservePhysical(next_byte, physical, grf_size),
        else => {},
    }
}

fn reservePhysical(next_byte: *usize, physical: operand.PhysicalGrf, grf_size: usize) void {
    const end = (@as(usize, physical.number) + 1) * grf_size;
    next_byte.* = @max(next_byte.*, end);
}

fn rewriteProgram(program: *program_ir.Program, allocations: []const ?operand.PhysicalGrf) Error!void {
    for (program.instructions.entries.items) |*entry| {
        const inst = if (entry.*) |*value| value else continue;
        switch (inst.operation) {
            .load_global_invocation_id => |*op| try rewriteDestination(program, &op.destination, allocations),
            .load_buffer => |*op| {
                try rewriteDestination(program, &op.destination, allocations);
                try rewriteSource(program, &op.byte_offset, allocations);
            },
            .store_buffer => |*op| {
                try rewriteSource(program, &op.byte_offset, allocations);
                try rewriteSource(program, &op.source, allocations);
            },
            .surface_read => |*op| {
                try rewriteDestination(program, &op.destination, allocations);
                try rewriteSource(program, &op.address, allocations);
            },
            .surface_write => |*op| {
                try rewriteSource(program, &op.address, allocations);
                try rewriteSource(program, &op.data, allocations);
            },
            .move => |*op| {
                try rewriteDestination(program, &op.destination, allocations);
                try rewriteSource(program, &op.source, allocations);
            },
            .binary => |*op| {
                try rewriteDestination(program, &op.destination, allocations);
                try rewriteSource(program, &op.lhs, allocations);
                try rewriteSource(program, &op.rhs, allocations);
            },
            .compare => |*op| {
                try rewriteSource(program, &op.lhs, allocations);
                try rewriteSource(program, &op.rhs, allocations);
            },
            .parallel_copy => return error.ParallelCopiesNotLowered,
        }
    }

    for (program.blocks.entries.items) |*entry| {
        const block = if (entry.*) |*value| value else continue;
        if (block.parameters.items.len != 0)
            return error.BlockParametersNotLowered;
        const terminator = if (block.terminator) |*value| value else return error.InvalidProgram;
        switch (terminator.*) {
            .jump => |*edge| try rewriteEdge(program, edge, allocations),
            .conditional_branch => |*branch| {
                try rewriteEdge(program, &branch.true_edge, allocations);
                try rewriteEdge(program, &branch.false_edge, allocations);
            },
            .end_thread, .@"unreachable" => {},
        }
    }
}

fn rewriteEdge(program: *const program_ir.Program, edge: *instruction.Edge, allocations: []const ?operand.PhysicalGrf) Error!void {
    for (@constCast(edge.arguments)) |*argument| switch (argument.*) {
        .source => |*edge_source| try rewriteSource(program, edge_source, allocations),
        .predicate => {},
    };
}

fn rewriteSource(program: *const program_ir.Program, value: *operand.Source, allocations: []const ?operand.PhysicalGrf) Error!void {
    try rewriteRegister(program, &value.register, allocations);
}

fn rewriteDestination(program: *const program_ir.Program, destination: *operand.Destination, allocations: []const ?operand.PhysicalGrf) Error!void {
    try rewriteRegister(program, &destination.register, allocations);
}

fn rewriteRegister(program: *const program_ir.Program, register: *operand.RegisterRef, allocations: []const ?operand.PhysicalGrf) Error!void {
    const virtual = switch (register.*) {
        .virtual => |value| value,
        else => return,
    };
    if (!program.virtual_registers.isLive(virtual) or virtual.index() >= allocations.len)
        return error.InvalidProgram;
    const physical = allocations[virtual.index()] orelse return error.InvalidProgram;
    register.* = .{ .physical_grf = physical };
}

const test_device = @import("../../device.zig").DeviceInfo{
    .generation = .gen9,
    .platform = .skylake,
    .pci_device_id = 0x1912,
    .grf_count = 128,
};

fn addRegister(program: *program_ir.Program, size: u32, alignment: u16) !ids.VirtualRegisterId {
    return program.addVirtualRegister(.{
        .size_bytes = size,
        .alignment_bytes = alignment,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
    });
}

fn source(register: ids.VirtualRegisterId) operand.Source {
    return .{
        .register = .{ .virtual = register },
        .type = .u32,
        .region = operand.Region.contiguous(.simd8),
    };
}

fn markPrerequisites(program: *program_ir.Program) void {
    program.properties.block_parameters_lowered = true;
    program.properties.parallel_copies_lowered = true;
}

test "[gen9] register allocation: assign non-overlapping physical GRFs" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();
    program.program_data.payload_grf_count = 1;

    const first = try addRegister(&program, 32, 32);
    const second = try addRegister(&program, 64, 32);
    const entry = try program.addBlock("entry");
    const move = try program.appendInstruction(entry, .simd8, null, .{ .move = .{
        .destination = .{ .register = .{ .virtual = second }, .type = .u32 },
        .source = source(first),
    } });
    try program.setTerminator(entry, .end_thread);
    markPrerequisites(&program);

    try run(std.testing.allocator, &program);

    const operation = program.instructions.get(move).?.operation.move;
    try std.testing.expectEqual(operand.PhysicalGrf{ .number = 1 }, operation.source.register.physical_grf);
    try std.testing.expectEqual(operand.PhysicalGrf{ .number = 2 }, operation.destination.register.physical_grf);
    try std.testing.expectEqual(@as(u16, 4), program.program_data.total_grf_count);
    try std.testing.expect(program.properties.registers_allocated);
}

test "[gen9] register allocation: report GRF exhaustion" {
    var limited_device = test_device;
    limited_device.grf_count = 2;
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, limited_device, .simd8);
    defer program.deinit();

    _ = try addRegister(&program, 96, 32);
    const entry = try program.addBlock("entry");
    try program.setTerminator(entry, .end_thread);
    markPrerequisites(&program);

    try std.testing.expectError(error.OutOfRegisters, run(std.testing.allocator, &program));
    try std.testing.expect(!program.properties.registers_allocated);
}
