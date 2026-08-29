const std = @import("std");
const device = @import("../device.zig");
const Builder = @import("../ir/Builder.zig");
const ids = @import("../ir/id.zig");
const instruction = @import("../ir/instruction.zig");
const operand = @import("../ir/operand.zig");
const program_ir = @import("../ir/program.zig");
const pseudo = @import("../ir/pseudo.zig");
const validator = @import("../ir/validator.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidProgram,
};

const EmittedInstruction = struct {
    predicate: ?operand.Predicate = null,
    operation: instruction.Operation,
};

const FlagValue = union(enum) {
    constant: bool,
    snapshot: ids.VirtualRegisterId,
};

const FlagWrite = struct {
    destination: ids.VirtualFlagId,
    value: FlagValue,
};

pub fn run(allocator: std.mem.Allocator, program: *program_ir.Program) Error!void {
    validator.validate(program) catch return Error.InvalidProgram;
    if (program.properties.parallel_copies_lowered)
        return;

    var builder = Builder.init(program);
    for (program.blocks.entries.items, 0..) |entry, block_index| {
        _ = entry orelse continue;
        const block_id = ids.BlockId.fromIndex(block_index);
        var instruction_index: usize = 0;

        while (true) {
            const block = program.blocks.get(block_id) orelse return Error.InvalidProgram;
            if (instruction_index >= block.instructions.items.len)
                break;

            const instruction_id = block.instructions.items[instruction_index];
            const inst = program.instructions.get(instruction_id) orelse return Error.InvalidProgram;
            const parallel_copy = switch (inst.operation) {
                .parallel_copy => |copy| copy,
                else => {
                    instruction_index += 1;
                    continue;
                },
            };
            if (inst.predicate != null)
                return Error.InvalidProgram;
            const execution_size = inst.execution_size;

            var emitted: std.ArrayList(EmittedInstruction) = .empty;
            defer emitted.deinit(allocator);
            try lowerParallelCopy(allocator, &builder, execution_size, parallel_copy, &emitted);

            if (emitted.items.len == 0) {
                const mutable_block = program.blocks.getMut(block_id) orelse return Error.InvalidProgram;
                const removed_id = mutable_block.instructions.orderedRemove(instruction_index);
                if (removed_id != instruction_id or !program.instructions.remove(instruction_id))
                    return Error.InvalidProgram;
                continue;
            }

            builder.replaceOperation(instruction_id, emitted.items[0].operation) catch |err|
                return mapBuilderError(err);
            const replacement = program.instructions.getMut(instruction_id) orelse return Error.InvalidProgram;
            replacement.predicate = emitted.items[0].predicate;

            for (emitted.items[1..], 1..) |item, offset| {
                _ = builder.insertInstruction(
                    block_id,
                    instruction_index + offset,
                    execution_size,
                    item.predicate,
                    item.operation,
                ) catch |err| return mapBuilderError(err);
            }
            instruction_index += emitted.items.len;
        }
    }

    program.properties.parallel_copies_lowered = true;
    validator.validate(program) catch return Error.InvalidProgram;
}

fn lowerParallelCopy(
    allocator: std.mem.Allocator,
    builder: *Builder,
    execution_size: device.ExecutionSize,
    copy: pseudo.ParallelCopy,
    emitted: *std.ArrayList(EmittedInstruction),
) Error!void {
    var pending_registers: std.ArrayList(pseudo.RegisterCopy) = .empty;
    defer pending_registers.deinit(allocator);
    for (copy.register_copies) |item| {
        if (!isRegisterIdentity(item, execution_size))
            try pending_registers.append(allocator, item);
    }

    var flag_writes: std.ArrayList(FlagWrite) = .empty;
    defer flag_writes.deinit(allocator);
    try snapshotFlagSources(allocator, builder, execution_size, copy.flag_copies, emitted, &flag_writes);
    try scheduleRegisterCopies(allocator, builder, execution_size, &pending_registers, emitted);
    try emitFlagWrites(allocator, execution_size, flag_writes.items, emitted);
}

fn scheduleRegisterCopies(
    allocator: std.mem.Allocator,
    builder: *Builder,
    execution_size: device.ExecutionSize,
    pending: *std.ArrayList(pseudo.RegisterCopy),
    emitted: *std.ArrayList(EmittedInstruction),
) Error!void {
    while (pending.items.len != 0) {
        if (findReadyCopy(pending.items)) |ready_index| {
            const ready = pending.orderedRemove(ready_index);
            try emitted.append(allocator, .{ .operation = .{ .move = .{
                .destination = ready.destination,
                .source = ready.source,
            } } });
            continue;
        }

        const cycle_copy = &pending.items[0];
        const destination_id = destinationVirtualRegister(cycle_copy.destination) orelse
            return Error.InvalidProgram;
        const destination_register = builder.program.virtual_registers.get(destination_id) orelse
            return Error.InvalidProgram;
        const temporary = builder.addVirtualRegister(.{
            .size_bytes = destination_register.size_bytes,
            .alignment_bytes = destination_register.alignment_bytes,
            .element_type = destination_register.element_type,
            .lane_count = destination_register.lane_count,
            .class = .temporary,
            .spillable = destination_register.spillable,
        }) catch |err| return mapBuilderError(err);

        var temporary_destination = cycle_copy.destination;
        temporary_destination.register = .{ .virtual = temporary };
        try emitted.append(allocator, .{ .operation = .{ .move = .{
            .destination = temporary_destination,
            .source = cycle_copy.source,
        } } });

        cycle_copy.source = .{
            .register = .{ .virtual = temporary },
            .type = cycle_copy.source.type,
            .region = operand.Region.contiguous(execution_size),
        };
    }
}

fn findReadyCopy(pending: []const pseudo.RegisterCopy) ?usize {
    for (pending, 0..) |candidate, candidate_index| {
        const destination_id = destinationVirtualRegister(candidate.destination) orelse continue;
        var destination_is_source = false;
        for (pending, 0..) |other, other_index| {
            if (candidate_index == other_index)
                continue;
            switch (other.source.register) {
                .virtual => |source_id| if (source_id == destination_id) {
                    destination_is_source = true;
                    break;
                },
                else => {},
            }
        }
        if (!destination_is_source)
            return candidate_index;
    }
    return null;
}

fn snapshotFlagSources(
    allocator: std.mem.Allocator,
    builder: *Builder,
    execution_size: device.ExecutionSize,
    copies: []const pseudo.FlagCopy,
    emitted: *std.ArrayList(EmittedInstruction),
    writes: *std.ArrayList(FlagWrite),
) Error!void {
    for (copies) |copy| {
        if (isFlagIdentity(copy))
            continue;

        const value: FlagValue = switch (copy.source) {
            .constant => |constant| .{ .constant = constant },
            .dynamic => |predicate| value: {
                const temporary = builder.addVirtualRegister(.{
                    .size_bytes = @as(u32, @intFromEnum(execution_size)) * @sizeOf(u32),
                    .alignment_bytes = builder.program.device_info.grf_size_bytes,
                    .element_type = .u32,
                    .lane_count = @intFromEnum(execution_size),
                    .class = .temporary,
                }) catch |err| return mapBuilderError(err);
                const destination: operand.Destination = .{
                    .register = .{ .virtual = temporary },
                    .type = .u32,
                };
                try emitted.append(allocator, .{ .operation = .{ .move = .{
                    .destination = destination,
                    .source = immediateU32(0),
                } } });
                try emitted.append(allocator, .{
                    .predicate = predicate,
                    .operation = .{ .move = .{
                        .destination = destination,
                        .source = immediateU32(1),
                    } },
                });
                break :value .{ .snapshot = temporary };
            },
        };
        try writes.append(allocator, .{
            .destination = copy.destination,
            .value = value,
        });
    }
}

fn emitFlagWrites(
    allocator: std.mem.Allocator,
    execution_size: device.ExecutionSize,
    writes: []const FlagWrite,
    emitted: *std.ArrayList(EmittedInstruction),
) Error!void {
    for (writes) |write| {
        const value = switch (write.value) {
            .constant => |constant| immediateU32(@intFromBool(constant)),
            .snapshot => |temporary| operand.Source{
                .register = .{ .virtual = temporary },
                .type = .u32,
                .region = operand.Region.contiguous(execution_size),
            },
        };
        try emitted.append(allocator, .{ .operation = .{ .compare = .{
            .opcode = .not_equal,
            .destination = .{ .virtual = write.destination },
            .lhs = value,
            .rhs = immediateU32(0),
        } } });
    }
}

fn isRegisterIdentity(copy: pseudo.RegisterCopy, execution_size: device.ExecutionSize) bool {
    const destination_id = destinationVirtualRegister(copy.destination) orelse return false;
    const source_id = switch (copy.source.register) {
        .virtual => |id| id,
        else => return false,
    };
    if (destination_id != source_id or copy.source.negate or copy.source.absolute)
        return false;

    const contiguous = operand.Region.contiguous(execution_size);
    return copy.destination.type == copy.source.type and
        copy.destination.region.byte_offset == contiguous.byte_offset and
        copy.destination.region.horizontal_stride == 1 and
        copy.source.region.byte_offset == contiguous.byte_offset and
        copy.source.region.vertical_stride == contiguous.vertical_stride and
        copy.source.region.width == contiguous.width and
        copy.source.region.horizontal_stride == contiguous.horizontal_stride;
}

fn isFlagIdentity(copy: pseudo.FlagCopy) bool {
    return switch (copy.source) {
        .constant => false,
        .dynamic => |predicate| !predicate.inverse and switch (predicate.flag) {
            .virtual => |source| source == copy.destination,
            .physical => false,
        },
    };
}

fn destinationVirtualRegister(destination: operand.Destination) ?ids.VirtualRegisterId {
    return switch (destination.register) {
        .virtual => |id| id,
        else => null,
    };
}

fn immediateU32(value: u32) operand.Source {
    return .{
        .register = .{ .immediate = .{ .u32 = value } },
        .type = .u32,
        .region = operand.Region.broadcast(),
    };
}

fn mapBuilderError(err: anyerror) Error {
    return switch (err) {
        Error.OutOfMemory => Error.OutOfMemory,
        else => Error.InvalidProgram,
    };
}

const test_device_info: device.DeviceInfo = .{
    .generation = .gen9,
    .platform = .skylake,
    .pci_device_id = 0x1912,
    .grf_count = 128,
};

fn addTestRegister(builder: *Builder) !ids.VirtualRegisterId {
    return builder.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
    });
}

fn testDestination(register: ids.VirtualRegisterId) operand.Destination {
    return .{
        .register = .{ .virtual = register },
        .type = .u32,
    };
}

fn testSource(register: ids.VirtualRegisterId) operand.Source {
    return .{
        .register = .{ .virtual = register },
        .type = .u32,
        .region = operand.Region.contiguous(.simd8),
    };
}

test "[intel] parallel copies: lower independent copies" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device_info, .simd8);
    defer program.deinit();
    var builder = Builder.init(&program);

    const source_a = try addTestRegister(&builder);
    const source_b = try addTestRegister(&builder);
    const destination_a = try addTestRegister(&builder);
    const destination_b = try addTestRegister(&builder);
    const entry = try builder.addBlock("entry");
    const copies = [_]pseudo.RegisterCopy{
        .{ .destination = testDestination(destination_a), .source = testSource(source_a) },
        .{ .destination = testDestination(destination_b), .source = testSource(source_b) },
    };
    _ = try builder.appendInstruction(entry, .simd8, null, .{ .parallel_copy = .{
        .register_copies = &copies,
        .flag_copies = &.{},
    } });
    try builder.setTerminator(entry, .end_thread);

    try validator.validate(&program);
    try run(std.testing.allocator, &program);
    try validator.validate(&program);

    try std.testing.expect(program.properties.parallel_copies_lowered);
    const instructions = program.blocks.get(entry).?.instructions.items;
    try std.testing.expectEqual(@as(usize, 2), instructions.len);
    const first = program.instructions.get(instructions[0]).?;
    const second = program.instructions.get(instructions[1]).?;
    try std.testing.expect(first.operation == .move);
    try std.testing.expect(second.operation == .move);
    try std.testing.expectEqual(destination_a, first.operation.move.destination.register.virtual);
    try std.testing.expectEqual(source_a, first.operation.move.source.register.virtual);
    try std.testing.expectEqual(destination_b, second.operation.move.destination.register.virtual);
    try std.testing.expectEqual(source_b, second.operation.move.source.register.virtual);
}

test "[intel] parallel copies: remove identity copies" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device_info, .simd8);
    defer program.deinit();
    var builder = Builder.init(&program);

    const register = try addTestRegister(&builder);
    const entry = try builder.addBlock("entry");
    const copies = [_]pseudo.RegisterCopy{.{
        .destination = testDestination(register),
        .source = testSource(register),
    }};
    const copy_id = try builder.appendInstruction(entry, .simd8, null, .{ .parallel_copy = .{
        .register_copies = &copies,
        .flag_copies = &.{},
    } });
    try builder.setTerminator(entry, .end_thread);

    try validator.validate(&program);
    try run(std.testing.allocator, &program);
    try validator.validate(&program);

    try std.testing.expect(program.properties.parallel_copies_lowered);
    try std.testing.expectEqual(@as(usize, 0), program.blocks.get(entry).?.instructions.items.len);
    try std.testing.expect(program.instructions.get(copy_id) == null);
}

test "[intel] parallel copies: break a two-register cycle" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device_info, .simd8);
    defer program.deinit();
    var builder = Builder.init(&program);

    const register_a = try addTestRegister(&builder);
    const register_b = try addTestRegister(&builder);
    const entry = try builder.addBlock("entry");
    const copies = [_]pseudo.RegisterCopy{
        .{ .destination = testDestination(register_a), .source = testSource(register_b) },
        .{ .destination = testDestination(register_b), .source = testSource(register_a) },
    };
    _ = try builder.appendInstruction(entry, .simd8, null, .{ .parallel_copy = .{
        .register_copies = &copies,
        .flag_copies = &.{},
    } });
    try builder.setTerminator(entry, .end_thread);

    try validator.validate(&program);
    try run(std.testing.allocator, &program);
    try validator.validate(&program);

    const instructions = program.blocks.get(entry).?.instructions.items;
    try std.testing.expectEqual(@as(usize, 3), instructions.len);
    const snapshot = program.instructions.get(instructions[0]).?.operation.move;
    const restore_b = program.instructions.get(instructions[1]).?.operation.move;
    const restore_a = program.instructions.get(instructions[2]).?.operation.move;
    const temporary = snapshot.destination.register.virtual;

    try std.testing.expect(temporary != register_a and temporary != register_b);
    try std.testing.expectEqual(register_b, snapshot.source.register.virtual);
    try std.testing.expectEqual(register_b, restore_b.destination.register.virtual);
    try std.testing.expectEqual(register_a, restore_b.source.register.virtual);
    try std.testing.expectEqual(register_a, restore_a.destination.register.virtual);
    try std.testing.expectEqual(temporary, restore_a.source.register.virtual);
    try std.testing.expectEqual(operand.RegisterClass.temporary, program.virtual_registers.get(temporary).?.class);
}

test "[intel] parallel copies: snapshot flag cycles" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device_info, .simd8);
    defer program.deinit();
    var builder = Builder.init(&program);

    const flag_a = try builder.addVirtualFlag(.{});
    const flag_b = try builder.addVirtualFlag(.{});
    const entry = try builder.addBlock("entry");
    const copies = [_]pseudo.FlagCopy{
        .{ .destination = flag_a, .source = .{ .dynamic = .{ .flag = .{ .virtual = flag_b } } } },
        .{ .destination = flag_b, .source = .{ .dynamic = .{ .flag = .{ .virtual = flag_a } } } },
    };
    _ = try builder.appendInstruction(entry, .simd8, null, .{ .parallel_copy = .{
        .register_copies = &.{},
        .flag_copies = &copies,
    } });
    try builder.setTerminator(entry, .end_thread);

    try validator.validate(&program);
    try run(std.testing.allocator, &program);
    try validator.validate(&program);

    const instructions = program.blocks.get(entry).?.instructions.items;
    try std.testing.expectEqual(@as(usize, 6), instructions.len);
    for (instructions[0..4]) |instruction_id|
        try std.testing.expect(program.instructions.get(instruction_id).?.operation == .move);
    try std.testing.expect(program.instructions.get(instructions[4]).?.operation == .compare);
    try std.testing.expect(program.instructions.get(instructions[5]).?.operation == .compare);
    try std.testing.expectEqual(flag_a, program.instructions.get(instructions[4]).?.operation.compare.destination.virtual);
    try std.testing.expectEqual(flag_b, program.instructions.get(instructions[5]).?.operation.compare.destination.virtual);
}
