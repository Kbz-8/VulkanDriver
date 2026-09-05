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

const physical_flag_count = 4;

pub fn run(allocator: std.mem.Allocator, program: *program_ir.Program) Error!void {
    if (!program.properties.block_parameters_lowered)
        return Error.BlockParametersNotLowered;

    if (!program.properties.parallel_copies_lowered)
        return Error.ParallelCopiesNotLowered;

    if (program.properties.flags_allocated)
        return;

    validator.validate(program) catch return Error.InvalidProgram;

    const allocations = try allocator.alloc(?operand.PhysicalFlag, program.virtual_flags.entries.items.len);
    defer allocator.free(allocations);
    @memset(allocations, null);

    var occupied: [physical_flag_count]bool = @splat(false);
    try visitProgramFlags(program, allocations, &occupied, false);

    try allocateLiveFlags(allocator, program, allocations, occupied);

    try visitProgramFlags(program, allocations, &occupied, true);
    program.properties.flags_allocated = true;
    validator.validate(program) catch return Error.InvalidProgram;
}

fn addUse(live: []bool, flag: operand.FlagRef) void {
    switch (flag) {
        .virtual => |id| live[id.index()] = true,
        .physical => {},
    }
}

fn interfere(graph: []bool, count: usize, a: usize, b: usize) void {
    if (a == b) return;
    graph[a * count + b] = true;
    graph[b * count + a] = true;
}

fn addLiveInterference(graph: []bool, live: []const bool) void {
    for (live, 0..) |a_live, a| {
        if (!a_live) continue;
        for (live[0..a], 0..) |b_live, b| {
            if (b_live) interfere(graph, live.len, a, b);
        }
    }
}

fn mergeSuccessor(live: []bool, live_in: []const bool, edge: instruction.Edge) void {
    const successor = live_in[edge.target.index() * live.len ..][0..live.len];
    for (live, successor) |*value, incoming| value.* = value.* or incoming;
    for (edge.arguments) |argument| switch (argument) {
        .source => {},
        .predicate => |value| switch (value) {
            .constant => {},
            .dynamic => |predicate| addUse(live, predicate.flag),
        },
    };
}

fn scanBlock(program: *const program_ir.Program, block: instruction.Block, live_in: []const bool, live: []bool, graph: ?[]bool) void {
    @memset(live, false);
    switch (block.terminator.?) {
        .jump => |edge| mergeSuccessor(live, live_in, edge),
        .conditional_branch => |branch| {
            mergeSuccessor(live, live_in, branch.true_edge);
            mergeSuccessor(live, live_in, branch.false_edge);
            addUse(live, branch.predicate.flag);
        },
        .end_thread, .@"unreachable" => {},
    }
    if (graph) |edges| addLiveInterference(edges, live);
    var index = block.instructions.items.len;
    while (index > 0) {
        index -= 1;
        const inst = program.instructions.get(block.instructions.items[index]).?;
        if (inst.operation == .compare) {
            switch (inst.operation.compare.destination) {
                .virtual => |destination| {
                    if (graph) |edges| {
                        for (live, 0..) |is_live, other| {
                            if (is_live) interfere(edges, live.len, destination.index(), other);
                        }
                        // Keep a compare's predicate distinct from its destination.
                        if (inst.predicate) |predicate| switch (predicate.flag) {
                            .virtual => |source| interfere(edges, live.len, destination.index(), source.index()),
                            .physical => {},
                        };
                    }
                    // A predicated write preserves the old value on inactive lanes.
                    if (inst.predicate == null) live[destination.index()] = false;
                },
                .physical => {},
            }
        }
        if (inst.predicate) |predicate| addUse(live, predicate.flag);
        if (graph) |edges| addLiveInterference(edges, live);
    }
}

fn allocateLiveFlags(allocator: std.mem.Allocator, program: *const program_ir.Program, allocations: []?operand.PhysicalFlag, occupied: [physical_flag_count]bool) Error!void {
    const count = allocations.len;
    const live_in = try allocator.alloc(bool, program.blocks.entries.items.len * count);
    defer allocator.free(live_in);
    @memset(live_in, false);
    const live = try allocator.alloc(bool, count);
    defer allocator.free(live);

    var changed = true;
    while (changed) {
        changed = false;
        for (program.blocks.entries.items, 0..) |entry, block_index| {
            const block = entry orelse continue;
            scanBlock(program, block, live_in, live, null);
            const incoming = live_in[block_index * count ..][0..count];
            if (!std.mem.eql(bool, incoming, live)) {
                @memcpy(incoming, live);
                changed = true;
            }
        }
    }

    const graph = try allocator.alloc(bool, count * count);
    defer allocator.free(graph);
    @memset(graph, false);
    for (program.blocks.entries.items) |entry| {
        const block = entry orelse continue;
        scanBlock(program, block, live_in, live, graph);
    }

    var available: [physical_flag_count]u8 = undefined;
    var available_count: usize = 0;
    for (occupied, 0..) |reserved, slot| {
        if (reserved) continue;
        available[available_count] = @intCast(slot);
        available_count += 1;
    }

    const colors = try allocator.alloc(?u8, count);
    defer allocator.free(colors);
    @memset(colors, null);

    while (true) {
        var selected: ?usize = null;
        var best_saturation: usize = 0;
        var best_degree: usize = 0;
        var selected_used: [physical_flag_count]bool = @splat(false);
        for (allocations, 0..) |allocation, candidate| {
            if (allocation == null or colors[candidate] != null) continue;
            var used: [physical_flag_count]bool = @splat(false);
            var degree: usize = 0;
            for (graph[candidate * count ..][0..count], 0..) |adjacent, other| {
                if (!adjacent) continue;
                degree += 1;
                if (colors[other]) |color| used[color] = true;
            }
            const saturation = std.mem.count(bool, &used, &.{true});
            if (selected == null or saturation > best_saturation or
                (saturation == best_saturation and degree > best_degree))
            {
                selected = candidate;
                best_saturation = saturation;
                best_degree = degree;
                selected_used = used;
            }
        }
        const current = selected orelse break;
        const color = std.mem.indexOfScalar(bool, selected_used[0..available_count], false) orelse return Error.OutOfFlagRegisters;
        colors[current] = @intCast(color);
    }

    for (allocations, colors) |*allocation, color| {
        if (color) |value| allocation.* = .{
            .register = available[value] / 2,
            .subregister = available[value] % 2,
        };
    }
}

fn visitProgramFlags(program: *program_ir.Program, allocations: []?operand.PhysicalFlag, occupied: *[physical_flag_count]bool, rewrite: bool) Error!void {
    for (program.instructions.entries.items, 0..) |entry, instruction_index| {
        _ = entry orelse continue;
        const inst = program.instructions.getMut(ids.InstructionId.fromIndex(instruction_index)) orelse
            return Error.InvalidProgram;

        if (inst.predicate) |*predicate|
            try visitFlagRef(program, &predicate.flag, allocations, occupied, rewrite);

        switch (inst.operation) {
            .compare => |*compare| try visitFlagRef(program, &compare.destination, allocations, occupied, rewrite),
            .parallel_copy => return Error.ParallelCopiesNotLowered,
            else => {},
        }
    }

    for (program.blocks.entries.items, 0..) |entry, block_index| {
        _ = entry orelse continue;
        const block = program.blocks.getMut(ids.BlockId.fromIndex(block_index)) orelse
            return Error.InvalidProgram;
        const terminator = if (block.terminator) |*value| value else return Error.InvalidProgram;

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
                return Error.InvalidProgram;

            if (!rewrite) {
                // Mark this virtual flag as referenced without assigning a physical
                // slot until all pre-existing physical references are known.
                if (allocations[virtual.index()] == null)
                    allocations[virtual.index()] = .{ .register = 0, .subregister = std.math.maxInt(u8) };
                return;
            }

            const physical = allocations[virtual.index()] orelse return Error.InvalidProgram;
            if (physical.register > 1 or physical.subregister > 1)
                return Error.InvalidProgram;
            flag.* = .{ .physical = physical };
        },
        .physical => |physical| {
            if (physical.register > 1 or physical.subregister > 1)
                return Error.InvalidProgram;
            occupied[physical.register * 2 + physical.subregister] = true;
        },
    }
}

fn defineFlag(program: *program_ir.Program, block: ids.BlockId, flag: operand.FlagRef) !ids.InstructionId {
    return program.appendInstruction(block, .simd8, null, .{ .compare = .{
        .opcode = .equal,
        .destination = flag,
        .lhs = immediateU32(0),
        .rhs = immediateU32(0),
    } });
}

fn useFlag(program: *program_ir.Program, block: ids.BlockId, flag: operand.FlagRef) !ids.InstructionId {
    return program.appendInstruction(block, .simd8, .{ .flag = flag }, .{ .move = .{
        .destination = .{ .register = .{ .physical_grf = .{ .number = 10 } }, .type = .u32 },
        .source = immediateU32(0),
    } });
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

test "[gen9] flag allocation: fifth live flag reports exhaustion without rewriting" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();

    const first = try program.addVirtualFlag(.{});
    const second = try program.addVirtualFlag(.{});
    const third = try program.addVirtualFlag(.{});
    const fourth = try program.addVirtualFlag(.{});
    const fifth = try program.addVirtualFlag(.{});
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
    _ = try defineFlag(&program, entry, .{ .virtual = fourth });
    _ = try defineFlag(&program, entry, .{ .virtual = fifth });
    _ = try useFlag(&program, entry, .{ .virtual = fourth });
    _ = try useFlag(&program, entry, .{ .virtual = fifth });
    _ = try useFlag(&program, entry, .{ .virtual = first });
    _ = try useFlag(&program, entry, .{ .virtual = second });
    _ = try useFlag(&program, entry, .{ .virtual = third });
    try program.setTerminator(entry, .end_thread);
    markPrerequisites(&program);

    try std.testing.expectError(Error.OutOfFlagRegisters, run(std.testing.allocator, &program));
    try std.testing.expect(!program.properties.flags_allocated);
    try std.testing.expectEqual(first, program.instructions.get(first_compare).?.operation.compare.destination.virtual);
}

test "[gen9] flag allocation: all four flag halves simultaneously live" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();
    const entry = try program.addBlock("entry");
    var flags: [4]operand.FlagRef = undefined;
    var definitions: [4]ids.InstructionId = undefined;
    var uses: [4]ids.InstructionId = undefined;
    for (&flags, &definitions) |*flag, *definition| {
        flag.* = .{ .virtual = try program.addVirtualFlag(.{}) };
        definition.* = try defineFlag(&program, entry, flag.*);
    }
    for (flags, &uses) |flag, *use| use.* = try useFlag(&program, entry, flag);
    try program.setTerminator(entry, .end_thread);
    markPrerequisites(&program);
    try run(std.testing.allocator, &program);
    var seen: [4]bool = @splat(false);
    for (definitions, uses) |definition, use| {
        const flag = program.instructions.get(definition).?.operation.compare.destination.physical;
        try std.testing.expect(flag.register <= 1 and flag.subregister <= 1);
        const slot = flag.register * 2 + flag.subregister;
        try std.testing.expect(!seen[slot]);
        seen[slot] = true;
        try std.testing.expectEqual(flag, program.instructions.get(use).?.predicate.?.flag.physical);
    }
    try std.testing.expectEqual([_]bool{ true, true, true, true }, seen);
}

test "[gen9] flag allocation: reuse sequential lifetimes" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();
    const entry = try program.addBlock("entry");
    var definitions: [12]ids.InstructionId = undefined;
    for (&definitions) |*definition| {
        const flag: operand.FlagRef = .{ .virtual = try program.addVirtualFlag(.{}) };
        definition.* = try defineFlag(&program, entry, flag);
        _ = try useFlag(&program, entry, flag);
    }
    try program.setTerminator(entry, .end_thread);
    markPrerequisites(&program);
    try run(std.testing.allocator, &program);
    for (definitions) |definition| {
        try std.testing.expectEqual(@as(u8, 0), program.instructions.get(definition).?.operation.compare.destination.physical.subregister);
    }
    try run(std.testing.allocator, &program);
}

test "[gen9] flag allocation: cross block live values and mutually exclusive lifetimes" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();
    const entry = try program.addBlock("entry");
    const left = try program.addBlock("left");
    const right = try program.addBlock("right");
    const merge = try program.addBlock("merge");
    const carried: operand.FlagRef = .{ .virtual = try program.addVirtualFlag(.{}) };
    const definition = try defineFlag(&program, entry, carried);
    try program.setTerminator(entry, .{ .conditional_branch = .{
        .predicate = .{ .flag = carried },
        .true_edge = .{ .target = left, .arguments = &.{} },
        .false_edge = .{ .target = right, .arguments = &.{} },
    } });
    var locals: [2]ids.InstructionId = undefined;
    for ([_]ids.BlockId{ left, right }, &locals) |block, *local| {
        const flag: operand.FlagRef = .{ .virtual = try program.addVirtualFlag(.{}) };
        local.* = try defineFlag(&program, block, flag);
        _ = try useFlag(&program, block, flag);
        try program.setTerminator(block, .{ .jump = .{ .target = merge, .arguments = &.{} } });
    }
    const use = try useFlag(&program, merge, carried);
    try program.setTerminator(merge, .end_thread);
    markPrerequisites(&program);
    try run(std.testing.allocator, &program);
    const physical = program.instructions.get(definition).?.operation.compare.destination.physical;
    try std.testing.expectEqual(physical, program.instructions.get(use).?.predicate.?.flag.physical);
    for (locals) |local| {
        try std.testing.expect(physical.subregister != program.instructions.get(local).?.operation.compare.destination.physical.subregister);
    }
}

test "[gen9] flag allocation: loop backedge preserves live flags" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();
    const entry = try program.addBlock("entry");
    const header = try program.addBlock("header");
    const body = try program.addBlock("body");
    const exit = try program.addBlock("exit");
    const carried: operand.FlagRef = .{ .virtual = try program.addVirtualFlag(.{}) };
    const definition = try defineFlag(&program, entry, carried);
    try program.setTerminator(entry, .{ .jump = .{ .target = header, .arguments = &.{} } });
    try program.setTerminator(header, .{ .conditional_branch = .{
        .predicate = .{ .flag = carried },
        .true_edge = .{ .target = body, .arguments = &.{} },
        .false_edge = .{ .target = exit, .arguments = &.{} },
    } });
    var locals: [3]ids.InstructionId = undefined;
    for (&locals) |*local| {
        const flag: operand.FlagRef = .{ .virtual = try program.addVirtualFlag(.{}) };
        local.* = try defineFlag(&program, body, flag);
        _ = try useFlag(&program, body, flag);
    }
    try program.setTerminator(body, .{ .jump = .{ .target = header, .arguments = &.{} } });
    try program.setTerminator(exit, .end_thread);
    markPrerequisites(&program);
    try run(std.testing.allocator, &program);
    const physical = program.instructions.get(definition).?.operation.compare.destination.physical;
    for (locals) |local| {
        try std.testing.expect(physical.subregister != program.instructions.get(local).?.operation.compare.destination.physical.subregister);
    }
}

test "[gen9] flag allocation: predicated definitions preserve old destination lanes" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();
    const entry = try program.addBlock("entry");
    const carried: operand.FlagRef = .{ .virtual = try program.addVirtualFlag(.{}) };
    const temporary: operand.FlagRef = .{ .virtual = try program.addVirtualFlag(.{}) };
    const condition: operand.FlagRef = .{ .virtual = try program.addVirtualFlag(.{}) };
    const original = try defineFlag(&program, entry, carried);
    const clobber = try defineFlag(&program, entry, temporary);
    _ = try defineFlag(&program, entry, condition);
    _ = try program.appendInstruction(entry, .simd8, .{ .flag = condition }, .{ .compare = .{
        .opcode = .equal,
        .destination = carried,
        .lhs = immediateU32(1),
        .rhs = immediateU32(0),
    } });
    _ = try useFlag(&program, entry, carried);
    try program.setTerminator(entry, .end_thread);
    markPrerequisites(&program);
    try run(std.testing.allocator, &program);
    try std.testing.expect(program.instructions.get(original).?.operation.compare.destination.physical.subregister !=
        program.instructions.get(clobber).?.operation.compare.destination.physical.subregister);
}

test "[gen9] flag allocation: reserve explicit physical flags while reusing virtual slots" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();
    const entry = try program.addBlock("entry");
    _ = try defineFlag(&program, entry, .{ .physical = .{ .register = 0, .subregister = 0 } });
    _ = try defineFlag(&program, entry, .{ .physical = .{ .register = 0, .subregister = 1 } });
    _ = try defineFlag(&program, entry, .{ .physical = .{ .register = 1, .subregister = 0 } });
    var definitions: [3]ids.InstructionId = undefined;
    for (&definitions) |*definition| {
        const flag: operand.FlagRef = .{ .virtual = try program.addVirtualFlag(.{}) };
        definition.* = try defineFlag(&program, entry, flag);
        _ = try useFlag(&program, entry, flag);
    }
    try program.setTerminator(entry, .end_thread);
    markPrerequisites(&program);
    try run(std.testing.allocator, &program);
    for (definitions) |definition| {
        try std.testing.expectEqual(operand.PhysicalFlag{ .register = 1, .subregister = 1 }, program.instructions.get(definition).?.operation.compare.destination.physical);
    }
}
