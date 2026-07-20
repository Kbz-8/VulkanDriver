const std = @import("std");
const ids = @import("id.zig");
const module_ir = @import("module.zig");
const Builder = @import("Builder.zig");

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
    const old_value = self.module.values.get(old) orelse return error.InvalidValue;
    const replacement_value = self.module.values.get(replacement) orelse return error.InvalidValue;

    if (old_value.type != replacement_value.type)
        return error.TypeMismatch;

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
    const instruction = self.module.instructions.get(instruction_id) orelse return error.InvalidInstruction;

    if (instruction.operation.hasSideEffects())
        return error.SideEffectingInstruction;

    if (instruction.result) |result| {
        if (self.countUses(result) != 0)
            return error.ResultStillUsed;
    }

    const block = self.module.blocks.getMut(instruction.parent_block) orelse return error.InvalidBlock;
    var owned_index: ?usize = null;

    for (block.instructions.items, 0..) |candidate, index| {
        if (candidate == instruction_id) {
            owned_index = index;
            break;
        }
    }

    _ = block.instructions.orderedRemove(owned_index orelse return error.InstructionNotOwnedByBlock);
    if (instruction.result) |result|
        _ = self.module.values.remove(result);
    _ = self.module.instructions.remove(instruction_id);
}

pub fn redirectEdges(
    self: *Self,
    source: ids.BlockId,
    old_target: ids.BlockId,
    new_target: ids.BlockId,
    new_arguments: []const ids.ValueId,
) Error!usize {
    const source_block = self.module.blocks.get(source) orelse return error.InvalidBlock;
    const target_block = self.module.blocks.get(new_target) orelse return error.InvalidBlock;

    if (source_block.parent_function != target_block.parent_function)
        return error.InvalidFunction;

    try self.validateArguments(target_block, new_arguments);

    const mutable_source = self.module.blocks.getMut(source).?;
    const terminator = if (mutable_source.terminator) |*value| value else return error.InvalidBlock;

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

pub fn addBlockParameter(
    self: *Self,
    block_id: ids.BlockId,
    ty: ids.TypeId,
    name: ?[]const u8,
    incoming: []const IncomingValue,
) Error!ids.ValueId {
    const block = self.module.blocks.get(block_id) orelse return error.InvalidBlock;
    const function = self.module.functions.get(block.parent_function) orelse return error.InvalidFunction;

    for (incoming) |item| {
        const value = self.module.values.get(item.value) orelse return error.InvalidValue;

        if (value.type != ty)
            return error.TypeMismatch;

        if (!functionHasEdgeTo(self.module, function, item.predecessor, block_id))
            return error.UnexpectedIncomingValue;
    }
    for (function.blocks.items) |predecessor| {
        const edge_count = countEdgesTo(self.module.blocks.get(predecessor).?, block_id);
        if (edge_count != 0 and findIncoming(incoming, predecessor) == null)
            return error.MissingIncomingValue;
    }

    var builder = Builder.init(self.module);
    const parameter = try builder.addBlockParameter(block_id, ty, name);

    for (function.blocks.items) |predecessor| {
        const incoming_value = findIncoming(incoming, predecessor) orelse continue;
        try self.appendArgumentToEdges(predecessor, block_id, incoming_value);
    }

    return parameter;
}

pub fn removeBlockParameter(
    self: *Self,
    block_id: ids.BlockId,
    parameter_index: usize,
    replacement: ids.ValueId,
) Error!void {
    const block = self.module.blocks.get(block_id) orelse return error.InvalidBlock;
    if (parameter_index >= block.parameters.items.len) return error.InvalidParameterIndex;
    const parameter = block.parameters.items[parameter_index];
    if (parameter == replacement) return error.InvalidValue;
    _ = try self.replaceAllUses(parameter, replacement);

    const function = self.module.functions.get(block.parent_function) orelse return error.InvalidFunction;
    for (function.blocks.items) |predecessor| {
        try self.removeArgumentFromEdges(predecessor, block_id, parameter_index);
    }

    const mutable_block = self.module.blocks.getMut(block_id).?;
    _ = mutable_block.parameters.orderedRemove(parameter_index);

    for (mutable_block.parameters.items[parameter_index..], parameter_index..) |value_id, index| {
        const value = self.module.values.getMut(value_id) orelse return error.InvalidValue;
        value.definition.block_parameter.index = @intCast(index);
    }

    _ = self.module.values.remove(parameter);
}

fn validateArguments(self: *const Self, target: *const module_ir.Block, arguments: []const ids.ValueId) Error!void {
    if (arguments.len != target.parameters.items.len) return error.TypeMismatch;
    for (arguments, target.parameters.items) |argument, parameter| {
        const argument_value = self.module.values.get(argument) orelse return error.InvalidValue;
        const parameter_value = self.module.values.get(parameter) orelse return error.InvalidValue;
        if (argument_value.type != parameter_value.type) return error.TypeMismatch;
    }
}

fn redirectOne(
    self: *Self,
    edge: *module_ir.Edge,
    old_target: ids.BlockId,
    new_target: ids.BlockId,
    arguments: []const ids.ValueId,
) !bool {
    if (edge.target != old_target)
        return false;

    edge.target = new_target;
    edge.arguments = try self.module.allocator().dupe(ids.ValueId, arguments);
    return true;
}

fn appendArgumentToEdges(self: *Self, predecessor: ids.BlockId, target: ids.BlockId, value: ids.ValueId) !void {
    const block = self.module.blocks.getMut(predecessor) orelse return error.InvalidBlock;
    const terminator = if (block.terminator) |*item| item else return error.InvalidBlock;

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
    const block = self.module.blocks.getMut(predecessor) orelse return error.InvalidBlock;
    const terminator = if (block.terminator) |*item| item else return error.InvalidBlock;

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
        return error.InvalidParameterIndex;

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

fn functionHasEdgeTo(
    module: *const module_ir.Module,
    function: *const module_ir.Function,
    predecessor: ids.BlockId,
    target: ids.BlockId,
) bool {
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
