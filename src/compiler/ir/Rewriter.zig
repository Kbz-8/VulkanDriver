const std = @import("std");
const ids = @import("id.zig");
const module_ir = @import("module.zig");
const Builder = @import("Builder.zig");
const validator = @import("validator/validator.zig");

const Self = @This();

pub const Error = std.mem.Allocator.Error || error{
    InvalidValue,
    InvalidInstruction,
    InvalidBlock,
    InvalidFunction,
    TypeMismatch,
    ResultStillUsed,
    SideEffectingInstruction,
    InstructionNotOwnedByBlock,
    InvalidParameterIndex,
    MissingIncomingValue,
    UnexpectedIncomingValue,
};

pub const IncomingValue = struct {
    predecessor: ids.BlockId,
    value: ids.ValueId,
};

const UseCountContext = struct {
    needle: ids.ValueId,
    count: usize = 0,
};

module: *module_ir.Module,

pub fn init(module: *module_ir.Module) Self {
    return .{ .module = module };
}

pub fn countUses(self: *const Self, value: ids.ValueId) usize {
    var context: UseCountContext = .{ .needle = value };
    for (self.module.instructions.entries.items) |entry| {
        const instruction = entry orelse continue;
        instruction.operation.visitValueUses(&context, countUse);
    }

    for (self.module.blocks.entries.items) |entry| {
        const block = entry orelse continue;
        if (block.terminator) |terminator|
            module_ir.visitTerminatorValueUses(terminator, &context, countUse);
    }

    return context.count;
}

pub fn replaceAllUses(self: *Self, old: ids.ValueId, replacement: ids.ValueId) Error!usize {
    const old_value = self.module.values.get(old) orelse return Error.InvalidValue;
    const replacement_value = self.module.values.get(replacement) orelse return Error.InvalidValue;

    if (old_value.type != replacement_value.type)
        return Error.TypeMismatch;

    if (old == replacement)
        return 0;

    var count: usize = 0;
    for (self.module.instructions.entries.items) |*entry| {
        const instruction = if (entry.*) |*value| value else continue;
        count += try instruction.operation.replaceValueUses(self.module.allocator(), old, replacement);
    }

    for (self.module.blocks.entries.items) |*entry| {
        const block = if (entry.*) |*value| value else continue;
        if (block.terminator) |*terminator|
            count += try module_ir.replaceTerminatorValueUses(self.module.allocator(), terminator, old, replacement);
    }

    return count;
}

pub fn eraseInstruction(self: *Self, instruction_id: ids.InstructionId) Error!void {
    const instruction = self.module.instructions.get(instruction_id) orelse return Error.InvalidInstruction;

    if (instruction.operation.hasSideEffects())
        return Error.SideEffectingInstruction;

    if (instruction.result) |result| {
        if (self.countUses(result) != 0)
            return Error.ResultStillUsed;
    }

    const block = self.module.blocks.getMut(instruction.parent_block) orelse return Error.InvalidBlock;
    var owned_index: ?usize = null;

    for (block.instructions.items, 0..) |candidate, index| {
        if (candidate == instruction_id) {
            owned_index = index;
            break;
        }
    }

    _ = block.instructions.orderedRemove(owned_index orelse return Error.InstructionNotOwnedByBlock);
    if (instruction.result) |result|
        _ = self.module.values.remove(result);
    _ = self.module.instructions.remove(instruction_id);
}

pub fn redirectEdges(self: *Self, source: ids.BlockId, old_target: ids.BlockId, new_target: ids.BlockId, new_arguments: []const ids.ValueId) Error!usize {
    const source_block = self.module.blocks.get(source) orelse return Error.InvalidBlock;
    const target_block = self.module.blocks.get(new_target) orelse return Error.InvalidBlock;

    if (source_block.parent_function != target_block.parent_function)
        return Error.InvalidFunction;

    try self.validateArguments(target_block, new_arguments);

    const mutable_source = self.module.blocks.getMut(source).?;
    const terminator = if (mutable_source.terminator) |*value| value else return Error.InvalidBlock;

    var count: usize = 0;

    switch (terminator.*) {
        .branch => |*edge| {
            if (try self.redirectOne(edge, old_target, new_target, new_arguments))
                count += 1;
        },
        .conditional_branch => |*branch| {
            if (try self.redirectOne(&branch.true_edge, old_target, new_target, new_arguments))
                count += 1;

            if (try self.redirectOne(&branch.false_edge, old_target, new_target, new_arguments))
                count += 1;
        },
        else => {},
    }

    return count;
}

pub fn addBlockParameter(self: *Self, block_id: ids.BlockId, ty: ids.TypeId, name: ?[]const u8, incoming: []const IncomingValue) Error!ids.ValueId {
    const block = self.module.blocks.get(block_id) orelse return Error.InvalidBlock;
    const function = self.module.functions.get(block.parent_function) orelse return Error.InvalidFunction;

    for (incoming) |item| {
        const value = self.module.values.get(item.value) orelse return Error.InvalidValue;

        if (value.type != ty)
            return Error.TypeMismatch;

        if (!functionHasEdgeTo(self.module, function, item.predecessor, block_id))
            return Error.UnexpectedIncomingValue;
    }
    for (function.blocks.items) |predecessor| {
        const edge_count = countEdgesTo(self.module.blocks.get(predecessor).?, block_id);
        if (edge_count != 0 and findIncoming(incoming, predecessor) == null)
            return Error.MissingIncomingValue;
    }

    var builder = Builder.init(self.module);
    const parameter = try builder.addBlockParameter(block_id, ty, name);

    for (function.blocks.items) |predecessor| {
        const incoming_value = findIncoming(incoming, predecessor) orelse continue;
        try self.appendArgumentToEdges(predecessor, block_id, incoming_value);
    }

    return parameter;
}

pub fn removeBlockParameter(self: *Self, block_id: ids.BlockId, parameter_index: usize, replacement: ids.ValueId) Error!void {
    const block = self.module.blocks.get(block_id) orelse return Error.InvalidBlock;
    if (parameter_index >= block.parameters.items.len) return Error.InvalidParameterIndex;
    const parameter = block.parameters.items[parameter_index];
    if (parameter == replacement) return Error.InvalidValue;
    _ = try self.replaceAllUses(parameter, replacement);

    const function = self.module.functions.get(block.parent_function) orelse return Error.InvalidFunction;
    for (function.blocks.items) |predecessor| {
        try self.removeArgumentFromEdges(predecessor, block_id, parameter_index);
    }

    const mutable_block = self.module.blocks.getMut(block_id).?;
    _ = mutable_block.parameters.orderedRemove(parameter_index);

    for (mutable_block.parameters.items[parameter_index..], parameter_index..) |value_id, index| {
        const value = self.module.values.getMut(value_id) orelse return Error.InvalidValue;
        value.definition.block_parameter.index = @intCast(index);
    }

    _ = self.module.values.remove(parameter);
}

fn validateArguments(self: *const Self, target: *const module_ir.Block, arguments: []const ids.ValueId) Error!void {
    if (arguments.len != target.parameters.items.len) return Error.TypeMismatch;
    for (arguments, target.parameters.items) |argument, parameter| {
        const argument_value = self.module.values.get(argument) orelse return Error.InvalidValue;
        const parameter_value = self.module.values.get(parameter) orelse return Error.InvalidValue;
        if (argument_value.type != parameter_value.type) return Error.TypeMismatch;
    }
}

fn redirectOne(self: *Self, edge: *module_ir.Edge, old_target: ids.BlockId, new_target: ids.BlockId, arguments: []const ids.ValueId) !bool {
    if (edge.target != old_target)
        return false;

    edge.target = new_target;
    edge.arguments = try self.module.allocator().dupe(ids.ValueId, arguments);
    return true;
}

fn appendArgumentToEdges(self: *Self, predecessor: ids.BlockId, target: ids.BlockId, value: ids.ValueId) !void {
    const block = self.module.blocks.getMut(predecessor) orelse return Error.InvalidBlock;
    const terminator = if (block.terminator) |*item| item else return Error.InvalidBlock;

    switch (terminator.*) {
        .branch => |*edge| {
            if (edge.target == target)
                try self.appendEdgeArgument(edge, value);
        },
        .conditional_branch => |*branch| {
            if (branch.true_edge.target == target)
                try self.appendEdgeArgument(&branch.true_edge, value);

            if (branch.false_edge.target == target)
                try self.appendEdgeArgument(&branch.false_edge, value);
        },
        else => {},
    }
}

fn appendEdgeArgument(self: *Self, edge: *module_ir.Edge, value: ids.ValueId) !void {
    const arguments = try self.module.allocator().alloc(ids.ValueId, edge.arguments.len + 1);
    @memcpy(arguments[0..edge.arguments.len], edge.arguments);
    arguments[edge.arguments.len] = value;
    edge.arguments = arguments;
}

fn removeArgumentFromEdges(self: *Self, predecessor: ids.BlockId, target: ids.BlockId, index: usize) !void {
    const block = self.module.blocks.getMut(predecessor) orelse return Error.InvalidBlock;
    const terminator = if (block.terminator) |*item| item else return Error.InvalidBlock;

    switch (terminator.*) {
        .branch => |*edge| {
            if (edge.target == target)
                try self.removeEdgeArgument(edge, index);
        },
        .conditional_branch => |*branch| {
            if (branch.true_edge.target == target)
                try self.removeEdgeArgument(&branch.true_edge, index);

            if (branch.false_edge.target == target)
                try self.removeEdgeArgument(&branch.false_edge, index);
        },
        else => {},
    }
}

fn removeEdgeArgument(self: *Self, edge: *module_ir.Edge, index: usize) !void {
    if (index >= edge.arguments.len)
        return Error.InvalidParameterIndex;

    const arguments = try self.module.allocator().alloc(ids.ValueId, edge.arguments.len - 1);
    @memcpy(arguments[0..index], edge.arguments[0..index]);
    @memcpy(arguments[index..], edge.arguments[index + 1 ..]);
    edge.arguments = arguments;
}

fn countUse(context: *UseCountContext, value: ids.ValueId) void {
    if (value == context.needle)
        context.count += 1;
}

fn findIncoming(incoming: []const IncomingValue, predecessor: ids.BlockId) ?ids.ValueId {
    for (incoming) |item| {
        if (item.predecessor == predecessor)
            return item.value;
    }
    return null;
}

fn functionHasEdgeTo(module: *const module_ir.Module, function: *const module_ir.Function, predecessor: ids.BlockId, target: ids.BlockId) bool {
    for (function.blocks.items) |block_id| {
        if (block_id != predecessor)
            continue;
        return countEdgesTo(module.blocks.get(block_id) orelse return false, target) != 0;
    }
    return false;
}

fn countEdgesTo(block: *const module_ir.Block, target: ids.BlockId) usize {
    const terminator = block.terminator orelse return 0;
    return switch (terminator) {
        .branch => |edge| @intFromBool(edge.target == target),
        .conditional_branch => |branch| @intFromBool(branch.true_edge.target == target) + @intFromBool(branch.false_edge.target == target),
        else => 0,
    };
}

test "Rewriter: replace all ID uses, safely erase dead instruction" {
    // shader compute @main
    // {
    //     %0: constant u32 = bits(0x1)
    //     %1: constant u32 = bits(0x2)
    //
    //     fn @main() -> void
    //     {
    //         .entry():
    //             %2: u32 = integer_add %0, %1
    //             %3: u32 = integer_multiply %2, %1
    //             return
    //     }
    // }

    var module = module_ir.Module.init(std.testing.allocator, .compute);
    defer module.deinit();

    var builder = Builder.init(&module);

    const void_type = try builder.internType(.void);
    const u32_type = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });

    const one = try builder.internConstant(u32_type, .{ .integer_bits = 1 });
    const two = try builder.internConstant(u32_type, .{ .integer_bits = 2 });

    const main = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(main);

    const entry = try builder.addBlock(main, "entry");
    const sum = (try builder.appendInstruction(entry, u32_type, .{
        .binary = .{
            .opcode = .integer_add,
            .lhs = one,
            .rhs = two,
        },
    }, null)).?;
    _ = try builder.appendInstruction(entry, u32_type, .{
        .binary = .{
            .opcode = .integer_multiply,
            .lhs = sum,
            .rhs = two,
        },
    }, null);
    try builder.setTerminator(entry, .return_void);

    try validator.validate(&module);

    const sum_instruction = module.values.get(sum).?.definition.instruction;
    var rewriter = Self.init(&module);

    try std.testing.expectEqual(@as(usize, 1), try rewriter.replaceAllUses(sum, one));
    try rewriter.eraseInstruction(sum_instruction);

    try std.testing.expect(module.values.get(sum) == null);
    try std.testing.expect(module.instructions.get(sum_instruction) == null);

    try validator.validate(&module);
}

test "Rewriter: add block parameter and sync branch calls" {
    // shader compute @main
    // {
    //     %0: constant u32 = bits(0x1)
    //
    //     fn @main() -> void
    //     {
    //         .entry():
    //             branch .merge()
    //
    //         .merge():
    //             return
    //
    //         .alternate():
    //             return
    //     }
    // }

    var module = module_ir.Module.init(std.testing.allocator, .compute);
    defer module.deinit();

    var builder = Builder.init(&module);

    const void_type = try builder.internType(.void);
    const u32_type = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });

    const one = try builder.internConstant(u32_type, .{ .integer_bits = 1 });

    const main = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(main);

    const entry = try builder.addBlock(main, "entry");
    const merge = try builder.addBlock(main, "merge");
    const alternate = try builder.addBlock(main, "alternate");

    try builder.setTerminator(entry, .{ .branch = try builder.edge(merge, &.{}) });
    try builder.setTerminator(merge, .return_void);
    try builder.setTerminator(alternate, .return_void);

    var rewriter = Self.init(&module);

    const parameter = try rewriter.addBlockParameter(merge, u32_type, "incoming", &.{
        .{
            .predecessor = entry,
            .value = one,
        },
    });
    const merge_edge = module.blocks.get(entry).?.terminator.?.branch;
    try std.testing.expectEqualSlices(ids.ValueId, &.{one}, merge_edge.arguments);

    _ = try builder.appendInstruction(merge, u32_type, .{
        .binary = .{
            .opcode = .integer_add,
            .lhs = parameter,
            .rhs = one,
        },
    }, null);
    try validator.validate(&module);

    try rewriter.removeBlockParameter(merge, 0, one);

    try std.testing.expectEqual(@as(usize, 0), module.blocks.get(merge).?.parameters.items.len);
    try std.testing.expectEqual(@as(usize, 0), module.blocks.get(entry).?.terminator.?.branch.arguments.len);

    try validator.validate(&module);

    try std.testing.expectEqual(@as(usize, 1), try rewriter.redirectEdges(entry, merge, alternate, &.{}));
    try std.testing.expectEqual(alternate, module.blocks.get(entry).?.terminator.?.branch.target);

    try validator.validate(&module);
}
