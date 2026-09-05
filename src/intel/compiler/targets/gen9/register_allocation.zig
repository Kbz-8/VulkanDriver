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
        return Error.BlockParametersNotLowered;

    if (!program.properties.parallel_copies_lowered)
        return Error.ParallelCopiesNotLowered;

    if (program.properties.registers_allocated)
        return;

    const grf_size: usize = program.device_info.grf_size_bytes;
    if (grf_size == 0 or grf_size > 256 or !std.math.isPowerOfTwo(grf_size))
        return Error.InvalidProgram;

    const capacity = @as(usize, program.device_info.grf_count) * grf_size;
    const count = program.virtual_registers.entries.items.len;
    const block_count = program.blocks.entries.items.len;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const scratch = arena.allocator();
    const allocations = try scratch.alloc(?operand.PhysicalGrf, count);
    @memset(allocations, null);

    const fixed = try scratch.alloc(bool, capacity);
    @memset(fixed, false);

    const alignments = try scratch.alloc(usize, count);
    for (program.virtual_registers.entries.items, 0..) |entry, index| {
        const register = entry orelse continue;
        if (register.size_bytes == 0 or !std.math.isPowerOfTwo(register.alignment_bytes))
            return Error.InvalidProgram;
        alignments[index] = register.alignment_bytes;
    }

    var analysis = Analysis{ .program = program, .fixed = fixed, .alignments = alignments, .grf_size = grf_size };
    const payload_end = @as(usize, program.program_data.payload_grf_count) * grf_size;

    if (payload_end > capacity)
        return Error.OutOfRegisters;

    @memset(fixed[0..payload_end], true);

    if (program.payload.header_grf) |header|
        try analysis.reserve(header, 0, grf_size);

    const accesses = try scratch.alloc(Access, program.instructions.entries.items.len);
    for (program.instructions.entries.items, 0..) |entry, index| {
        accesses[index] = if (entry) |inst| try analysis.instructionAccess(inst) else .{};
    }

    const matrix_size = std.math.mul(usize, block_count, count) catch return Error.OutOfMemory;
    const live_in = try scratch.alloc(bool, matrix_size);
    @memset(live_in, false);

    const live = try scratch.alloc(bool, count);
    const graph_size = std.math.mul(usize, count, count) catch return Error.OutOfMemory;
    var graph = try std.DynamicBitSetUnmanaged.initEmpty(scratch, graph_size);

    var changed = true;
    while (changed) {
        changed = false;
        var block_index = block_count;
        while (block_index != 0) {
            block_index -= 1;
            const block = program.blocks.entries.items[block_index] orelse continue;
            try successorLive(program, block, live_in, live);
            var position = block.instructions.items.len;

            while (position != 0) {
                position -= 1;
                const id = block.instructions.items[position];
                const inst = program.instructions.get(id) orelse return Error.InvalidProgram;

                if (inst.parent_block.index() != block_index)
                    return Error.InvalidProgram;

                accesses[id.index()].transfer(live);
            }

            const input = live_in[block_index * count ..][0..count];

            if (!std.mem.eql(bool, input, live)) {
                @memcpy(input, live);
                changed = true;
            }
        }
    }

    for (program.blocks.entries.items) |entry| {
        const block = entry orelse continue;
        try successorLive(program, block, live_in, live);
        addClique(&graph, live);
        var position = block.instructions.items.len;
        while (position != 0) {
            position -= 1;
            const access = accesses[block.instructions.items[position].index()];

            for (access.uses[0..access.use_count]) |use|
                live[use] = true;

            if (access.definition) |definition|
                live[definition] = true;

            addClique(&graph, live);
            access.transfer(live);
        }
    }

    var high_water = payload_end;
    for (fixed, 0..) |reserved, byte| {
        if (reserved)
            high_water = byte + 1;
    }

    for (program.virtual_registers.entries.items, 0..) |entry, index| {
        const register = entry orelse continue;
        const size: usize = register.size_bytes;

        if (size > capacity)
            return Error.OutOfRegisters;

        var start: usize = 0;
        while (true) : (start += alignments[index]) {
            if (start > capacity - size)
                return Error.OutOfRegisters;

            const end = start + size;
            if (std.mem.indexOfScalar(bool, fixed[start..end], true) != null)
                continue;

            var conflict = false;
            for (allocations[0..index], 0..) |allocated, other| {
                const physical = allocated orelse continue;

                if (!graph.isSet(index * count + other))
                    continue;

                const other_start = @as(usize, physical.number) * grf_size + physical.byte_offset;
                const other_end = other_start + program.virtual_registers.entries.items[other].?.size_bytes;

                if (start < other_end and other_start < end) {
                    conflict = true;
                    break;
                }
            }

            if (conflict)
                continue;
            allocations[index] = .{ .number = @intCast(start / grf_size), .byte_offset = @intCast(start % grf_size) };
            high_water = @max(high_water, end);

            break;
        }
    }

    try rewriteProgram(program, allocations);
    program.program_data.total_grf_count = @intCast(std.math.divCeil(usize, high_water, grf_size) catch return Error.InvalidProgram);
    program.properties.registers_allocated = true;
}

const Access = struct {
    uses: [3]usize = undefined,
    use_count: usize = 0,
    definition: ?usize = null,
    full_overwrite: bool = false,

    fn use(self: *Access, index: usize) void {
        self.uses[self.use_count] = index;
        self.use_count += 1;
    }

    fn transfer(self: Access, live: []bool) void {
        if (self.definition) |definition|
            live[definition] = !self.full_overwrite;

        for (self.uses[0..self.use_count]) |index|
            live[index] = true;
    }
};

const Analysis = struct {
    program: *const program_ir.Program,
    fixed: []bool,
    alignments: []usize,
    grf_size: usize,

    fn reserve(self: *Analysis, physical: operand.PhysicalGrf, offset: usize, size: usize) Error!void {
        if (physical.byte_offset >= self.grf_size)
            return Error.InvalidProgram;

        const start = @as(usize, physical.number) * self.grf_size + physical.byte_offset + offset;

        if (start > self.fixed.len or size > self.fixed.len - start)
            return Error.InvalidProgram;

        @memset(self.fixed[start..][0..size], true);
    }

    fn register(self: *Analysis, ref: operand.RegisterRef, offset: usize, size: usize) Error!?usize {
        switch (ref) {
            .virtual => |id| {
                const value = self.program.virtual_registers.get(id) orelse return Error.InvalidProgram;

                if (offset > value.size_bytes or size > value.size_bytes - offset)
                    return Error.InvalidProgram;

                return id.index();
            },
            .physical_grf => |physical| try self.reserve(physical, offset, size),
            else => {},
        }
        return null;
    }

    fn read(self: *Analysis, access: *Access, value: operand.Source, lanes: usize) Error!void {
        const region = value.region;

        if (region.width == 0)
            return Error.InvalidProgram;

        var last: usize = 0;
        for (0..lanes) |lane| {
            last = @max(last, (lane / region.width) * region.vertical_stride + (lane % region.width) * region.horizontal_stride);
        }

        if (try self.register(value.register, region.byte_offset, (last + 1) * value.type.sizeBytes())) |index|
            access.use(index);
    }

    fn write(self: *Analysis, access: *Access, value: operand.Destination, lanes: usize, predicated: bool) Error!void {
        const size = ((lanes - 1) * value.region.horizontal_stride + 1) * value.type.sizeBytes();

        if (try self.register(value.register, value.region.byte_offset, size)) |index| {
            access.definition = index;
            access.full_overwrite = !predicated and value.region.byte_offset == 0 and
                (lanes == 1 or value.region.horizontal_stride == 1) and
                size == self.program.virtual_registers.entries.items[index].?.size_bytes;
        }
    }

    fn span(self: *Analysis, access: *Access, value: operand.RegisterSpan, destination: bool, predicated: bool) Error!void {
        if (value.register_count == 0)
            return Error.InvalidProgram;

        const size = @as(usize, value.register_count) * self.grf_size;
        if (try self.register(value.base, 0, size)) |index| {
            self.alignments[index] = @max(self.alignments[index], self.grf_size);
            if (destination) {
                access.definition = index;
                access.full_overwrite = !predicated and size == self.program.virtual_registers.entries.items[index].?.size_bytes;
            } else access.use(index);
        }
    }

    fn instructionAccess(self: *Analysis, inst: instruction.Instruction) Error!Access {
        var access = Access{};
        const lanes: usize = @intFromEnum(inst.execution_size);
        const predicated = inst.predicate != null;
        switch (inst.operation) {
            .load_global_invocation_id, .load_num_workgroups => |op| try self.write(&access, op.destination, lanes, predicated),
            inline .load_buffer, .array_length => |op| {
                try self.write(&access, op.destination, lanes, predicated);
                try self.read(&access, op.byte_offset, lanes);
            },
            .store_buffer => |op| {
                try self.read(&access, op.byte_offset, lanes);
                try self.read(&access, op.source, lanes);
            },
            .surface_read => |op| {
                try self.write(&access, op.destination, lanes, predicated);
                try self.read(&access, op.address, lanes);
            },
            .surface_write => |op| {
                try self.read(&access, op.address, lanes);
                try self.read(&access, op.data, lanes);
            },
            .surface_message => |op| {
                try self.span(&access, op.payload, false, predicated);
                if (op.response) |response| try self.span(&access, response, true, predicated);
            },
            .move => |op| {
                try self.write(&access, op.destination, lanes, predicated);
                try self.read(&access, op.source, lanes);
            },
            inline .binary, .math => |op| {
                try self.write(&access, op.destination, lanes, predicated);
                try self.read(&access, op.lhs, lanes);
                try self.read(&access, op.rhs, lanes);
            },
            .compare => |op| {
                try self.read(&access, op.lhs, lanes);
                try self.read(&access, op.rhs, lanes);
            },
            .parallel_copy => return Error.ParallelCopiesNotLowered,
        }
        return access;
    }
};

fn mergeEdge(program: *const program_ir.Program, edge: instruction.Edge, live_in: []const bool, live: []bool) Error!void {
    if (!program.blocks.isLive(edge.target))
        return Error.InvalidProgram;

    if (edge.arguments.len != 0)
        return Error.BlockParametersNotLowered;

    const successor = live_in[edge.target.index() * live.len ..][0..live.len];
    for (live, successor) |*value, incoming|
        value.* = value.* or incoming;
}

fn successorLive(program: *const program_ir.Program, block: instruction.Block, live_in: []const bool, live: []bool) Error!void {
    if (block.parameters.items.len != 0)
        return Error.BlockParametersNotLowered;

    @memset(live, false);
    switch (block.terminator orelse return Error.InvalidProgram) {
        .jump => |edge| try mergeEdge(program, edge, live_in, live),
        .conditional_branch => |branch| {
            try mergeEdge(program, branch.true_edge, live_in, live);
            try mergeEdge(program, branch.false_edge, live_in, live);
        },
        .end_thread, .@"unreachable" => {},
    }
}

fn addClique(graph: *std.DynamicBitSetUnmanaged, live: []const bool) void {
    for (live, 0..) |active, index| {
        if (!active) continue;
        for (live[0..index], 0..) |other_active, other| {
            if (!other_active)
                continue;
            graph.set(index * live.len + other);
            graph.set(other * live.len + index);
        }
    }
}

fn rewriteProgram(program: *program_ir.Program, allocations: []const ?operand.PhysicalGrf) Error!void {
    for (program.instructions.entries.items) |*entry| {
        const inst = if (entry.*) |*value| value else continue;
        switch (inst.operation) {
            .load_global_invocation_id, .load_num_workgroups => |*op| try rewriteDestination(program, &op.destination, allocations),
            .load_buffer => |*op| {
                try rewriteDestination(program, &op.destination, allocations);
                try rewriteSource(program, &op.byte_offset, allocations);
            },
            .store_buffer => |*op| {
                try rewriteSource(program, &op.byte_offset, allocations);
                try rewriteSource(program, &op.source, allocations);
            },
            .array_length => |*op| {
                try rewriteDestination(program, &op.destination, allocations);
                try rewriteSource(program, &op.byte_offset, allocations);
            },
            .surface_read => |*op| {
                try rewriteDestination(program, &op.destination, allocations);
                try rewriteSource(program, &op.address, allocations);
            },
            .surface_write => |*op| {
                try rewriteSource(program, &op.address, allocations);
                try rewriteSource(program, &op.data, allocations);
            },
            .surface_message => |*op| {
                try rewriteRegister(program, &op.payload.base, allocations);
                if (op.response) |*response|
                    try rewriteRegister(program, &response.base, allocations);
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
            .math => |*op| {
                try rewriteDestination(program, &op.destination, allocations);
                try rewriteSource(program, &op.lhs, allocations);
                try rewriteSource(program, &op.rhs, allocations);
            },
            .parallel_copy => return Error.ParallelCopiesNotLowered,
        }
    }

    for (program.blocks.entries.items) |*entry| {
        const block = if (entry.*) |*value| value else continue;

        if (block.parameters.items.len != 0)
            return Error.BlockParametersNotLowered;

        const terminator = if (block.terminator) |*value| value else return Error.InvalidProgram;

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
        return Error.InvalidProgram;

    const physical = allocations[virtual.index()] orelse return Error.InvalidProgram;
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

fn defineRegister(program: *program_ir.Program, block: ids.BlockId, register: ids.VirtualRegisterId) !ids.InstructionId {
    return program.appendInstruction(block, .simd8, null, .{ .move = .{
        .destination = .{ .register = .{ .virtual = register }, .type = .u32 },
        .source = .{ .register = .{ .immediate = .{ .u32 = 0 } }, .type = .u32, .region = operand.Region.scalar() },
    } });
}

fn useRegister(program: *program_ir.Program, block: ids.BlockId, register: ids.VirtualRegisterId) !void {
    _ = try program.appendInstruction(block, .simd8, null, .{ .move = .{
        .destination = .{ .register = .null, .type = .u32 },
        .source = source(register),
    } });
}

fn assigned(program: *const program_ir.Program, id: ids.InstructionId) operand.PhysicalGrf {
    return program.instructions.get(id).?.operation.move.destination.register.physical_grf;
}

const test_predicate = operand.Predicate{ .flag = .{ .physical = .{} } };

test "[gen9] register allocation: reuse disjoint lifetimes across blocks" {
    var limited_device = test_device;
    limited_device.grf_count = 1;
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, limited_device, .simd8);
    defer program.deinit();
    const first = try addRegister(&program, 32, 32);
    const second = try addRegister(&program, 32, 32);
    const entry = try program.addBlock("entry");
    const next = try program.addBlock("next");
    const a = try defineRegister(&program, entry, first);
    try useRegister(&program, entry, first);
    try program.setTerminator(entry, .{ .jump = .{ .target = next, .arguments = &.{} } });
    const b = try defineRegister(&program, next, second);
    try useRegister(&program, next, second);
    try program.setTerminator(next, .end_thread);
    markPrerequisites(&program);
    try run(std.testing.allocator, &program);
    try std.testing.expectEqual(assigned(&program, a), assigned(&program, b));
    try std.testing.expectEqual(@as(u16, 1), program.program_data.total_grf_count);
}

test "[gen9] register allocation: more virtual registers than GRFs with disjoint lifetimes" {
    var device = test_device;
    device.grf_count = 1;
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, device, .simd8);
    defer program.deinit();
    const entry = try program.addBlock("entry");
    var definitions: [256]ids.InstructionId = undefined;
    for (&definitions) |*definition| {
        const register = try addRegister(&program, 32, 32);
        definition.* = try defineRegister(&program, entry, register);
        try useRegister(&program, entry, register);
    }
    try program.setTerminator(entry, .end_thread);
    markPrerequisites(&program);
    try run(std.testing.allocator, &program);
    for (definitions) |definition|
        try std.testing.expectEqual(operand.PhysicalGrf{ .number = 0 }, assigned(&program, definition));
    try std.testing.expectEqual(@as(u16, 1), program.program_data.total_grf_count);
}

test "[gen9] register allocation: branch union and loop backedge liveness" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();
    const carried = try addRegister(&program, 32, 32);
    const temporary = try addRegister(&program, 32, 32);
    const exit_value = try addRegister(&program, 32, 32);
    const entry = try program.addBlock("entry");
    const loop = try program.addBlock("loop");
    const body = try program.addBlock("body");
    const exit = try program.addBlock("exit");
    const a = try defineRegister(&program, entry, carried);
    const c = try defineRegister(&program, entry, exit_value);
    try program.setTerminator(entry, .{ .jump = .{ .target = loop, .arguments = &.{} } });
    try useRegister(&program, loop, carried);
    try program.setTerminator(loop, .{ .conditional_branch = .{
        .predicate = test_predicate,
        .true_edge = .{ .target = body, .arguments = &.{} },
        .false_edge = .{ .target = exit, .arguments = &.{} },
    } });
    const b = try defineRegister(&program, body, temporary);
    try useRegister(&program, body, temporary);
    try program.setTerminator(body, .{ .jump = .{ .target = loop, .arguments = &.{} } });
    try useRegister(&program, exit, exit_value);
    try program.setTerminator(exit, .end_thread);
    markPrerequisites(&program);
    try run(std.testing.allocator, &program);
    try std.testing.expect(assigned(&program, a).number != assigned(&program, b).number);
    try std.testing.expect(assigned(&program, c).number != assigned(&program, b).number);
    try std.testing.expect(assigned(&program, a).number != assigned(&program, c).number);
    try std.testing.expectEqual(@as(u16, 3), program.program_data.total_grf_count);
}

test "[gen9] register allocation: only full unpredicated writes kill" {
    for (0..5) |mode| {
        var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
        defer program.deinit();
        const value = try addRegister(&program, 32, 32);
        const temporary = try addRegister(&program, 32, 32);
        const entry = try program.addBlock("entry");
        const a = try defineRegister(&program, entry, value);
        try useRegister(&program, entry, value);
        const b = try defineRegister(&program, entry, temporary);
        try useRegister(&program, entry, temporary);
        _ = try program.appendInstruction(entry, if (mode == 0 or mode == 4) .simd8 else .simd4, if (mode == 4) test_predicate else null, .{ .move = .{
            .destination = .{
                .register = .{ .virtual = value },
                .type = .u32,
                .region = .{ .byte_offset = if (mode == 1) 16 else 0, .horizontal_stride = if (mode == 2) 2 else 1 },
            },
            .source = .{ .register = .{ .immediate = .{ .u32 = 1 } }, .type = .u32, .region = operand.Region.scalar() },
        } });
        try useRegister(&program, entry, value);
        try program.setTerminator(entry, .end_thread);
        markPrerequisites(&program);
        try run(std.testing.allocator, &program);
        try std.testing.expectEqual(mode == 0, assigned(&program, a).number == assigned(&program, b).number);
    }
}

test "[gen9] register allocation: high fixed SEND spans leave usable holes" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();
    program.program_data.payload_grf_count = 1;
    program.payload.header_grf = .{ .number = 0 };
    const large = try addRegister(&program, 119 * 32, 32);
    const small = try addRegister(&program, 3 * 32, 32);
    const entry = try program.addBlock("entry");
    const a = try defineRegister(&program, entry, large);
    const b = try defineRegister(&program, entry, small);
    _ = try program.appendInstruction(entry, .simd8, null, .{ .surface_message = .{
        .kind = .read,
        .binding_table = 0,
        .payload = .{ .base = .{ .physical_grf = .{ .number = 120 } }, .register_count = 2 },
        .response = .{ .base = .{ .physical_grf = .{ .number = 125 } }, .register_count = 3 },
        .data_type = .u32,
    } });
    try useRegister(&program, entry, large);
    try useRegister(&program, entry, small);
    try program.setTerminator(entry, .end_thread);
    markPrerequisites(&program);
    try run(std.testing.allocator, &program);
    try std.testing.expectEqual(@as(u16, 1), assigned(&program, a).number);
    try std.testing.expectEqual(@as(u16, 122), assigned(&program, b).number);
    try std.testing.expectEqual(@as(u16, 128), program.program_data.total_grf_count);
}

test "[gen9] register allocation: full GRF capacity and simultaneous exhaustion" {
    for ([_]usize{ 128, 129 }) |count| {
        var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
        defer program.deinit();
        const entry = try program.addBlock("entry");
        var registers: [129]ids.VirtualRegisterId = undefined;
        var definitions: [129]ids.InstructionId = undefined;
        for (0..count) |index| {
            registers[index] = try addRegister(&program, 32, 32);
            definitions[index] = try defineRegister(&program, entry, registers[index]);
        }
        for (registers[0..count]) |register| try useRegister(&program, entry, register);
        try program.setTerminator(entry, .end_thread);
        markPrerequisites(&program);
        if (count == 129) {
            try std.testing.expectError(Error.OutOfRegisters, run(std.testing.allocator, &program));
            try std.testing.expect(!program.properties.registers_allocated);
            try std.testing.expect(program.instructions.get(definitions[0]).?.operation.move.destination.register == .virtual);
        } else {
            try run(std.testing.allocator, &program);
            for (definitions[0..count], 0..) |definition, index|
                try std.testing.expectEqual(@as(u16, @intCast(index)), assigned(&program, definition).number);
            try std.testing.expectEqual(@as(u16, 128), program.program_data.total_grf_count);
        }
    }
}

test "[gen9] register allocation: fixed regions reserve bytes across GRF boundaries" {
    var device = test_device;
    device.grf_count = 3;
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, device, .simd8);
    defer program.deinit();
    program.program_data.payload_grf_count = 1;
    const first = try addRegister(&program, 28, 4);
    const second = try addRegister(&program, 4, 4);
    const entry = try program.addBlock("entry");
    var definitions: [2]ids.InstructionId = undefined;
    for ([_]ids.VirtualRegisterId{ first, second }, 0..) |register, index| {
        definitions[index] = try program.appendInstruction(entry, .simd1, null, .{ .move = .{
            .destination = .{ .register = .{ .virtual = register }, .type = .u32 },
            .source = .{ .register = .{ .immediate = .{ .u32 = 0 } }, .type = .u32, .region = operand.Region.scalar() },
        } });
    }
    _ = try program.appendInstruction(entry, .simd8, null, .{ .move = .{
        .destination = .{ .register = .null, .type = .u32 },
        .source = .{
            .register = .{ .physical_grf = .{ .number = 1, .byte_offset = 4 } },
            .type = .u32,
            .region = .{ .byte_offset = 24, .vertical_stride = 8, .width = 8, .horizontal_stride = 1 },
        },
    } });
    for ([_]ids.VirtualRegisterId{ first, second }) |register| {
        _ = try program.appendInstruction(entry, .simd1, null, .{ .move = .{
            .destination = .{ .register = .null, .type = .u32 },
            .source = .{ .register = .{ .virtual = register }, .type = .u32, .region = operand.Region.scalar() },
        } });
    }
    try program.setTerminator(entry, .end_thread);
    markPrerequisites(&program);
    try run(std.testing.allocator, &program);
    try std.testing.expectEqual(operand.PhysicalGrf{ .number = 1 }, assigned(&program, definitions[0]));
    try std.testing.expectEqual(operand.PhysicalGrf{ .number = 2, .byte_offset = 28 }, assigned(&program, definitions[1]));
    try std.testing.expectEqual(@as(u16, 3), program.program_data.total_grf_count);
}

test "[gen9] register allocation: SEND response overwrite and payload interference" {
    for ([_]bool{ false, true }) |partial| {
        var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
        defer program.deinit();
        const response = try addRegister(&program, 64, 4);
        const temporary = try addRegister(&program, 32, 32);
        const payload = try addRegister(&program, 32, 4);
        const entry = try program.addBlock("entry");
        const a = try defineRegister(&program, entry, response);
        try useRegister(&program, entry, response);
        const b = try defineRegister(&program, entry, temporary);
        try useRegister(&program, entry, temporary);
        const p = try defineRegister(&program, entry, payload);
        const send = try program.appendInstruction(entry, .simd8, null, .{ .surface_message = .{
            .kind = .read,
            .binding_table = 0,
            .payload = .{ .base = .{ .virtual = payload }, .register_count = 1 },
            .response = .{ .base = .{ .virtual = response }, .register_count = if (partial) 1 else 2 },
            .data_type = .u32,
        } });
        try useRegister(&program, entry, response);
        try program.setTerminator(entry, .end_thread);
        markPrerequisites(&program);
        try run(std.testing.allocator, &program);
        try std.testing.expectEqual(!partial, assigned(&program, a).number == assigned(&program, b).number);
        try std.testing.expect(assigned(&program, p).number >= assigned(&program, a).number + 2);
        const message = program.instructions.get(send).?.operation.surface_message;
        try std.testing.expectEqual(assigned(&program, a), message.response.?.base.physical_grf);
        try std.testing.expectEqual(assigned(&program, p), message.payload.base.physical_grf);
        try std.testing.expectEqual(@as(u8, 0), message.payload.base.physical_grf.byte_offset);
    }
}

test "[gen9] register allocation: reject fixed spans beyond capacity before rewriting" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();
    const register = try addRegister(&program, 32, 32);
    const entry = try program.addBlock("entry");
    const definition = try defineRegister(&program, entry, register);
    _ = try program.appendInstruction(entry, .simd8, null, .{ .surface_message = .{
        .kind = .read,
        .binding_table = 0,
        .payload = .{ .base = .{ .physical_grf = .{ .number = 0 } }, .register_count = 1 },
        .response = .{ .base = .{ .physical_grf = .{ .number = 127 } }, .register_count = 2 },
        .data_type = .u32,
    } });
    try program.setTerminator(entry, .end_thread);
    markPrerequisites(&program);
    try std.testing.expectError(Error.InvalidProgram, run(std.testing.allocator, &program));
    try std.testing.expect(!program.properties.registers_allocated);
    try std.testing.expect(program.instructions.get(definition).?.operation.move.destination.register == .virtual);
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

    try std.testing.expectError(Error.OutOfRegisters, run(std.testing.allocator, &program));
    try std.testing.expect(!program.properties.registers_allocated);
}
