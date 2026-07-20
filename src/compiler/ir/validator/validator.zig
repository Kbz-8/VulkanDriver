const std = @import("std");
const ids = @import("../id.zig");
const type_ir = @import("../type.zig");
const inst_ir = @import("../instruction.zig");
const module_ir = @import("../module.zig");
const dominance = @import("dominance.zig");

pub const ValidationError = error{
    MissingEntryPoint,
    InvalidEntryPoint,
    InvalidType,
    InvalidConstant,
    InvalidValue,
    InvalidFunction,
    InvalidBlock,
    InvalidInstruction,
    MissingFunctionEntryBlock,
    MissingTerminator,
    EntryBlockHasPredecessor,
    WrongParent,
    WrongDefinition,
    WrongParameterIndex,
    WrongResultPresence,
    WrongOperandType,
    WrongResultType,
    WrongBranchArgumentCount,
    WrongBranchArgumentType,
    CrossFunctionReference,
    WrongReturnType,
    WrongInterfaceDirection,
    InvalidStructuredControl,
    DefinitionDoesNotDominateUse,
};

pub const Error = ValidationError || std.mem.Allocator.Error;

/// Early validator for the foundational IR. It covers object ownership, CFG
/// edges, single definitions, function boundaries, and the currently modeled
/// operation types, and SSA dominance.
pub fn validate(module: *const module_ir.Module) Error!void {
    const entry_point = module.entry_point orelse return error.MissingEntryPoint;
    if (!module.functions.isLive(entry_point))
        return error.InvalidEntryPoint;

    for (module.types.entries.items) |entry| {
        const ty = entry orelse continue;
        try validateType(module, ty);
    }

    for (module.constants.entries.items) |entry| {
        const constant = entry orelse continue;

        if (!module.types.isLive(constant.type))
            return error.InvalidType;

        if (constant.value == .composite) {
            for (constant.value.composite) |element| {
                if (!module.constants.isLive(element))
                    return error.InvalidConstant;
            }
        }
    }

    for (module.values.entries.items, 0..) |entry, value_index| {
        const value = entry orelse continue;

        if (!module.types.isLive(value.type))
            return error.InvalidType;

        const value_id = ids.ValueId.fromIndex(value_index);

        switch (value.definition) {
            .constant => |id| {
                const constant = module.constants.get(id) orelse return error.InvalidConstant;
                if (constant.type != value.type)
                    return error.WrongResultType;
            },
            .function_parameter => |definition| {
                const function = module.functions.get(definition.function) orelse return error.InvalidFunction;
                if (definition.index >= function.parameters.items.len or function.parameters.items[definition.index] != value_id)
                    return error.WrongParameterIndex;
            },
            .block_parameter => |definition| {
                const block = module.blocks.get(definition.block) orelse return error.InvalidBlock;
                if (definition.index >= block.parameters.items.len or block.parameters.items[definition.index] != value_id)
                    return error.WrongParameterIndex;
            },
            .instruction => |instruction_id| {
                const instruction = module.instructions.get(instruction_id) orelse return error.InvalidInstruction;
                if (instruction.result != value_id)
                    return error.WrongDefinition;
            },
            .undef => {},
        }
    }

    for (module.interface_variables.entries.items) |entry| {
        const variable = entry orelse continue;
        if (!module.types.isLive(variable.type))
            return error.InvalidType;
    }

    for (module.resources.entries.items) |entry| {
        const resource = entry orelse continue;
        if (!module.types.isLive(resource.type))
            return error.InvalidType;
    }

    for (module.functions.entries.items, 0..) |entry, function_index| {
        const function = entry orelse continue;
        const function_id = ids.FunctionId.fromIndex(function_index);

        if (!module.types.isLive(function.return_type))
            return error.InvalidType;

        if (function.parameter_types.items.len != function.parameters.items.len)
            return error.WrongParameterIndex;

        for (function.parameter_types.items, function.parameters.items, 0..) |parameter_type, parameter_id, index| {
            const parameter = module.values.get(parameter_id) orelse return error.InvalidValue;

            if (parameter.type != parameter_type)
                return error.WrongResultType;

            if (parameter.definition != .function_parameter or
                parameter.definition.function_parameter.function != function_id or
                parameter.definition.function_parameter.index != index)
                return error.WrongDefinition;
        }

        const entry_block = function.entry_block orelse return error.MissingFunctionEntryBlock;
        const entry_block_value = module.blocks.get(entry_block) orelse return error.InvalidBlock;
        if (entry_block_value.parent_function != function_id) return error.WrongParent;

        for (function.blocks.items) |block_id| {
            const block = module.blocks.get(block_id) orelse return error.InvalidBlock;

            if (block.parent_function != function_id)
                return error.WrongParent;

            try validateBlock(module, function_id, block_id, block);
        }

        for (function.blocks.items) |block_id| {
            const block = module.blocks.get(block_id).?;

            if (block.terminator) |terminator| {
                if (targetsBlock(terminator, entry_block))
                    return error.EntryBlockHasPredecessor;
            }
        }

        try dominance.validate(module, function_id);
    }
}

fn validateType(module: *const module_ir.Module, ty: type_ir.Type) ValidationError!void {
    switch (ty) {
        .vector => |vector| {
            if (!module.types.isLive(vector.element_type) or vector.length < 2)
                return error.InvalidType;
        },
        .array => |array| {
            if (!module.types.isLive(array.element_type) or array.length == 0)
                return error.InvalidType;
        },
        .structure => |structure| for (structure.members) |member| {
            if (!module.types.isLive(member))
                return error.InvalidType;
        },
        .pointer => |pointer| {
            if (!module.types.isLive(pointer.pointee_type))
                return error.InvalidType;
        },
        .resource_handle => |handle| if (handle.data_type) |data_type| {
            if (!module.types.isLive(data_type))
                return error.InvalidType;
        },
        else => {},
    }
}

fn validateBlock(
    module: *const module_ir.Module,
    function_id: ids.FunctionId,
    block_id: ids.BlockId,
    block: *const module_ir.Block,
) ValidationError!void {
    for (block.parameters.items, 0..) |parameter_id, index| {
        const parameter = module.values.get(parameter_id) orelse return error.InvalidValue;
        if (parameter.definition != .block_parameter or
            parameter.definition.block_parameter.block != block_id or
            parameter.definition.block_parameter.index != index)
            return error.WrongDefinition;
    }

    switch (block.structured_control) {
        .none => {},
        .selection => |selection| try validateTarget(module, function_id, selection.merge_block),
        .loop => |loop| {
            try validateTarget(module, function_id, loop.merge_block);
            try validateTarget(module, function_id, loop.continue_block);
        },
    }

    for (block.instructions.items) |instruction_id| {
        const instruction = module.instructions.get(instruction_id) orelse return error.InvalidInstruction;

        if (instruction.parent_block != block_id)
            return error.WrongParent;

        if (instruction.result) |result_id| {
            const result = module.values.get(result_id) orelse return error.InvalidValue;

            if (result.definition != .instruction or result.definition.instruction != instruction_id)
                return error.WrongDefinition;
        }

        try validateOperation(module, function_id, instruction);
    }

    const terminator = block.terminator orelse return error.MissingTerminator;
    try validateTerminator(module, function_id, terminator);
}

fn validateOperation(module: *const module_ir.Module, function_id: ids.FunctionId, instruction: *const inst_ir.Instruction) ValidationError!void {
    const result_type = if (instruction.result) |result| module.typeOf(result) orelse return error.InvalidValue else null;

    switch (instruction.operation) {
        .unary => |op| {
            const operand_type = try operandType(module, function_id, op.operand);

            if (result_type == null)
                return error.WrongResultPresence;

            if (result_type.? != operand_type)
                return error.WrongResultType;
        },
        .binary => |op| {
            const lhs_type = try operandType(module, function_id, op.lhs);
            const rhs_type = try operandType(module, function_id, op.rhs);

            if (lhs_type != rhs_type)
                return error.WrongOperandType;

            if (result_type == null or result_type.? != lhs_type)
                return error.WrongResultType;
        },
        .compare => |op| {
            const lhs_type = try operandType(module, function_id, op.lhs);
            if (try operandType(module, function_id, op.rhs) != lhs_type)
                return error.WrongOperandType;

            const result = result_type orelse return error.WrongResultPresence;
            if (!isBoolean(module, result))
                return error.WrongResultType;
        },
        .select => |op| {
            if (!isBoolean(module, try operandType(module, function_id, op.condition)))
                return error.WrongOperandType;

            const true_type = try operandType(module, function_id, op.true_value);
            if (try operandType(module, function_id, op.false_value) != true_type)
                return error.WrongOperandType;

            if (result_type == null or result_type.? != true_type)
                return error.WrongResultType;
        },
        .bitcast => |operand| {
            _ = try operandType(module, function_id, operand);
            if (result_type == null)
                return error.WrongResultPresence;
        },
        .composite_construct => |op| {
            const result = result_type orelse return error.WrongResultPresence;
            const ty = module.types.get(result) orelse return error.InvalidType;

            switch (ty.*) {
                .vector => |vector| {
                    if (op.elements.len != vector.length)
                        return error.WrongOperandType;

                    for (op.elements) |element| {
                        if (try operandType(module, function_id, element) != vector.element_type)
                            return error.WrongOperandType;
                    }
                },
                .structure => |structure| {
                    if (op.elements.len != structure.members.len)
                        return error.WrongOperandType;

                    for (op.elements, structure.members) |element, member_type| {
                        if (try operandType(module, function_id, element) != member_type)
                            return error.WrongOperandType;
                    }
                },
                else => return error.WrongResultType,
            }
        },
        .composite_extract => |op| {
            const composite_type = try operandType(module, function_id, op.composite);
            const extracted_type = try indexedType(module, composite_type, op.indices);

            if (result_type == null or result_type.? != extracted_type)
                return error.WrongResultType;
        },
        .load_interface => |op| {
            const variable = module.interface_variables.get(op.variable) orelse return error.InvalidValue;

            if (variable.direction != .input)
                return error.WrongInterfaceDirection;

            if (op.element_index) |index|
                _ = try operandType(module, function_id, index);

            if (result_type == null or result_type.? != variable.type)
                return error.WrongResultType;
        },
        .store_interface => |op| {
            if (result_type != null)
                return error.WrongResultPresence;

            const variable = module.interface_variables.get(op.variable) orelse return error.InvalidValue;

            if (variable.direction != .output)
                return error.WrongInterfaceDirection;

            if (try operandType(module, function_id, op.value) != variable.type)
                return error.WrongOperandType;

            if (op.element_index) |index|
                _ = try operandType(module, function_id, index);
        },
        .call => |op| {
            const callee = module.functions.get(op.function) orelse return error.InvalidFunction;

            if (op.arguments.len != callee.parameter_types.items.len)
                return error.WrongOperandType;

            for (op.arguments, callee.parameter_types.items) |argument, parameter_type| {
                if (try operandType(module, function_id, argument) != parameter_type)
                    return error.WrongOperandType;
            }

            const return_type = module.types.get(callee.return_type) orelse return error.InvalidType;

            if (return_type.* == .void) {
                if (result_type != null)
                    return error.WrongResultPresence;
            } else if (result_type == null or result_type.? != callee.return_type)
                return error.WrongResultType;
        },
    }
}

fn validateTerminator(module: *const module_ir.Module, function_id: ids.FunctionId, terminator: module_ir.Terminator) ValidationError!void {
    const function = module.functions.get(function_id) orelse return error.InvalidFunction;

    switch (terminator) {
        .branch => |edge| try validateEdge(module, function_id, edge),
        .conditional_branch => |branch| {
            if (!isBoolean(module, try operandType(module, function_id, branch.condition)))
                return error.WrongOperandType;

            try validateEdge(module, function_id, branch.true_edge);
            try validateEdge(module, function_id, branch.false_edge);
        },
        .return_void => {
            if (module.types.get(function.return_type).?.* != .void)
                return error.WrongReturnType;
        },
        .return_value => |value| {
            if (try operandType(module, function_id, value) != function.return_type)
                return error.WrongReturnType;
        },
        .discard => {
            if (module.stage != .fragment)
                return error.WrongReturnType;
        },
        .@"unreachable" => {},
    }
}

fn validateEdge(module: *const module_ir.Module, function_id: ids.FunctionId, edge: module_ir.Edge) ValidationError!void {
    const target = module.blocks.get(edge.target) orelse return error.InvalidBlock;

    if (target.parent_function != function_id)
        return error.CrossFunctionReference;

    if (edge.arguments.len != target.parameters.items.len)
        return error.WrongBranchArgumentCount;

    for (edge.arguments, target.parameters.items) |argument, parameter| {
        if (try operandType(module, function_id, argument) != module.typeOf(parameter).?)
            return error.WrongBranchArgumentType;
    }
}

fn validateTarget(module: *const module_ir.Module, function_id: ids.FunctionId, target_id: ids.BlockId) ValidationError!void {
    const target = module.blocks.get(target_id) orelse return error.InvalidStructuredControl;
    if (target.parent_function != function_id)
        return error.InvalidStructuredControl;
}

fn operandType(module: *const module_ir.Module, function_id: ids.FunctionId, value_id: ids.ValueId) ValidationError!ids.TypeId {
    const value = module.values.get(value_id) orelse return error.InvalidValue;
    const owner = valueFunction(module, value_id) catch return error.InvalidValue;

    if (owner) |actual| {
        if (actual != function_id)
            return error.CrossFunctionReference;
    }
    return value.type;
}

fn valueFunction(module: *const module_ir.Module, value_id: ids.ValueId) ValidationError!?ids.FunctionId {
    const value = module.values.get(value_id) orelse return error.InvalidValue;

    return switch (value.definition) {
        .constant, .undef => null,
        .function_parameter => |definition| definition.function,
        .block_parameter => |definition| (module.blocks.get(definition.block) orelse return error.InvalidBlock).parent_function,
        .instruction => |instruction_id| blk: {
            const instruction = module.instructions.get(instruction_id) orelse return error.InvalidInstruction;
            const block = module.blocks.get(instruction.parent_block) orelse return error.InvalidBlock;
            break :blk block.parent_function;
        },
    };
}

fn indexedType(module: *const module_ir.Module, root: ids.TypeId, indices: []const u32) ValidationError!ids.TypeId {
    if (indices.len == 0)
        return error.WrongOperandType;

    var current = root;

    for (indices) |index| {
        const ty = module.types.get(current) orelse return error.InvalidType;
        current = switch (ty.*) {
            .vector => |vector| if (index < vector.length)
                vector.element_type
            else
                return error.WrongOperandType,
            .array => |array| if (index < array.length)
                array.element_type
            else
                return error.WrongOperandType,
            .structure => |structure| if (index < structure.members.len)
                structure.members[index]
            else
                return error.WrongOperandType,

            else => return error.WrongOperandType,
        };
    }
    return current;
}

fn isBoolean(module: *const module_ir.Module, type_id: ids.TypeId) bool {
    const ty = module.types.get(type_id) orelse return false;
    return ty.* == .boolean;
}

fn targetsBlock(terminator: module_ir.Terminator, target: ids.BlockId) bool {
    return switch (terminator) {
        .branch => |edge| edge.target == target,
        .conditional_branch => |branch| branch.true_edge.target == target or branch.false_edge.target == target,
        else => false,
    };
}
