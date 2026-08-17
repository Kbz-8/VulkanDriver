const std = @import("std");

const ids = @import("../../ir/id.zig");
const instruction = @import("../../ir/instruction.zig");
const operand = @import("../../ir/operand.zig");
const program_ir = @import("../../ir/program.zig");
const pseudo = @import("../../ir/pseudo.zig");
const validator = @import("validator.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidProgram,
    BlockParametersNotLowered,
    ParallelCopiesNotLowered,
    OutOfFlagRegisters,
};

const physical_flag_count = 2;

pub fn run(allocator: std.mem.Allocator, program: *program_ir.Program) Error!void {
    if (!program.properties.block_parameters_lowered)
        return error.BlockParametersNotLowered;

    if (!program.properties.parallel_copies_lowered)
        return error.ParallelCopiesNotLowered;

    if (program.properties.flags_allocated)
        return;

    validator.validate(program) catch return error.InvalidProgram;

    const allocations = try allocator.alloc(?operand.PhysicalFlag, program.virtual_flags.entries.items.len);
    defer allocator.free(allocations);
    @memset(allocations, null);

    var occupied: [physical_flag_count]bool = @splat(false);
    try visitProgramFlags(program, allocations, &occupied, false);

    for (allocations) |*allocation| {
        const marker = allocation.* orelse continue;
        if (marker.subregister != std.math.maxInt(u8))
            return error.InvalidProgram;

        const subregister = std.mem.indexOfScalar(bool, &occupied, false) orelse return error.OutOfFlagRegisters;

        allocation.* = .{
            .register = 0,
            .subregister = @intCast(subregister),
        };
        occupied[subregister] = true;
    }

    try visitProgramFlags(program, allocations, &occupied, true);
    program.properties.flags_allocated = true;
    validator.validate(program) catch return error.InvalidProgram;
}

fn visitProgramFlags(
    program: *program_ir.Program,
    allocations: []?operand.PhysicalFlag,
    occupied: *[physical_flag_count]bool,
    rewrite: bool,
) Error!void {
    for (program.instructions.entries.items, 0..) |entry, instruction_index| {
        _ = entry orelse continue;
        const inst = program.instructions.getMut(ids.InstructionId.fromIndex(instruction_index)) orelse
            return error.InvalidProgram;

        if (inst.predicate) |*predicate|
            try visitFlagRef(program, &predicate.flag, allocations, occupied, rewrite);

        switch (inst.operation) {
            .compare => |*compare| try visitFlagRef(program, &compare.destination, allocations, occupied, rewrite),
            .parallel_copy => return error.ParallelCopiesNotLowered,
            else => {},
        }
    }

    for (program.blocks.entries.items, 0..) |entry, block_index| {
        _ = entry orelse continue;
        const block = program.blocks.getMut(ids.BlockId.fromIndex(block_index)) orelse
            return error.InvalidProgram;
        const terminator = if (block.terminator) |*value| value else return error.InvalidProgram;

        switch (terminator.*) {
            .jump => |*edge| try visitEdge(program, edge, allocations, occupied, rewrite),
            .conditional_branch => |*branch| {
                try visitFlagRef(program, &branch.predicate.flag, allocations, occupied, rewrite);
                try visitEdge(program, &branch.true_edge, allocations, occupied, rewrite);
                try visitEdge(program, &branch.false_edge, allocations, occupied, rewrite);
            },
            .end_thread, .@"unreachable" => {},
        }
    }
}

fn visitEdge(
    program: *const program_ir.Program,
    edge: *instruction.Edge,
    allocations: []?operand.PhysicalFlag,
    occupied: *[physical_flag_count]bool,
    rewrite: bool,
) Error!void {
    for (@constCast(edge.arguments)) |*argument| switch (argument.*) {
        .source => {},
        .predicate => |*value| try visitPredicateValue(program, value, allocations, occupied, rewrite),
    };
}

fn visitPredicateValue(
    program: *const program_ir.Program,
    value: *pseudo.PredicateValue,
    allocations: []?operand.PhysicalFlag,
    occupied: *[physical_flag_count]bool,
    rewrite: bool,
) Error!void {
    switch (value.*) {
        .constant => {},
        .dynamic => |*predicate| try visitFlagRef(program, &predicate.flag, allocations, occupied, rewrite),
    }
}

fn visitFlagRef(
    program: *const program_ir.Program,
    flag: *operand.FlagRef,
    allocations: []?operand.PhysicalFlag,
    occupied: *[physical_flag_count]bool,
    rewrite: bool,
) Error!void {
    switch (flag.*) {
        .virtual => |virtual| {
            if (!program.virtual_flags.isLive(virtual) or virtual.index() >= allocations.len)
                return error.InvalidProgram;

            if (!rewrite) {
                // Mark this virtual flag as referenced without assigning a physical
                // slot until all pre-existing physical references are known.
                if (allocations[virtual.index()] == null)
                    allocations[virtual.index()] = .{ .register = 0, .subregister = std.math.maxInt(u8) };
                return;
            }

            const physical = allocations[virtual.index()] orelse return error.InvalidProgram;
            if (physical.subregister >= physical_flag_count)
                return error.InvalidProgram;
            flag.* = .{ .physical = physical };
        },
        .physical => |physical| {
            if (physical.register != 0 or physical.subregister >= physical_flag_count)
                return error.InvalidProgram;
            occupied[physical.subregister] = true;
        },
    }
}

const test_device = @import("../../device.zig").DeviceInfo{
    .generation = .gen9,
    .platform = .skylake,
    .pci_device_id = 0x1912,
    .grf_count = 128,
};

fn immediateU32(value: u32) operand.Source {
    return .{
        .register = .{ .immediate = .{ .u32 = value } },
        .type = .u32,
        .region = operand.Region.broadcast(),
    };
}

fn markPrerequisites(program: *program_ir.Program) void {
    program.properties.block_parameters_lowered = true;
    program.properties.parallel_copies_lowered = true;
}

test "[gen9] flag allocation: rewrite compares and predicates" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();

    const first = try program.addVirtualFlag(.{ .name = "first" });
    const second = try program.addVirtualFlag(.{ .name = "second" });
    const scratch = try program.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
    });
    const entry = try program.addBlock("entry");
    const taken = try program.addBlock("taken");
    const not_taken = try program.addBlock("not_taken");

    const first_compare = try program.appendInstruction(entry, .simd8, null, .{ .compare = .{
        .opcode = .equal,
        .destination = .{ .virtual = first },
        .lhs = immediateU32(1),
        .rhs = immediateU32(1),
    } });
    const predicated = try program.appendInstruction(entry, .simd8, .{
        .flag = .{ .virtual = first },
    }, .{ .compare = .{
        .opcode = .not_equal,
        .destination = .{ .virtual = second },
        .lhs = .{
            .register = .{ .virtual = scratch },
            .type = .u32,
            .region = operand.Region.contiguous(.simd8),
        },
        .rhs = immediateU32(0),
    } });
    try program.setTerminator(entry, .{ .conditional_branch = .{
        .predicate = .{ .flag = .{ .virtual = second }, .inverse = true },
        .true_edge = .{ .target = taken, .arguments = &.{} },
        .false_edge = .{ .target = not_taken, .arguments = &.{} },
    } });
    try program.setTerminator(taken, .end_thread);
    try program.setTerminator(not_taken, .end_thread);
    markPrerequisites(&program);

    try run(std.testing.allocator, &program);

    try std.testing.expect(program.properties.flags_allocated);
    try std.testing.expectEqual(@as(u8, 0), program.instructions.get(first_compare).?.operation.compare.destination.physical.subregister);
    try std.testing.expectEqual(@as(u8, 0), program.instructions.get(predicated).?.predicate.?.flag.physical.subregister);
    try std.testing.expectEqual(@as(u8, 1), program.instructions.get(predicated).?.operation.compare.destination.physical.subregister);
    const branch = program.blocks.get(entry).?.terminator.?.conditional_branch;
    try std.testing.expect(branch.predicate.inverse);
    try std.testing.expectEqual(@as(u8, 1), branch.predicate.flag.physical.subregister);
}

test "[gen9] flag allocation: report exhaustion without rewriting" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();

    const first = try program.addVirtualFlag(.{});
    const second = try program.addVirtualFlag(.{});
    const third = try program.addVirtualFlag(.{});
    const entry = try program.addBlock("entry");

    const first_compare = try program.appendInstruction(entry, .simd8, null, .{ .compare = .{
        .opcode = .equal,
        .destination = .{ .virtual = first },
        .lhs = immediateU32(0),
        .rhs = immediateU32(0),
    } });
    _ = try program.appendInstruction(entry, .simd8, .{ .flag = .{ .virtual = second } }, .{ .compare = .{
        .opcode = .equal,
        .destination = .{ .virtual = third },
        .lhs = immediateU32(1),
        .rhs = immediateU32(1),
    } });
    try program.setTerminator(entry, .end_thread);
    markPrerequisites(&program);

    try std.testing.expectError(error.OutOfFlagRegisters, run(std.testing.allocator, &program));
    try std.testing.expect(!program.properties.flags_allocated);
    try std.testing.expectEqual(first, program.instructions.get(first_compare).?.operation.compare.destination.virtual);
}
