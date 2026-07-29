const std = @import("std");
const ids = @import("../id.zig");
const type_ir = @import("../type.zig");
const inst_ir = @import("../instruction.zig");
const module_ir = @import("../module.zig");
const Builder = @import("../Builder.zig");
const dominance = @import("dominance.zig");

pub const ValidationError = error{
    CrossFunctionReference,
    DefinitionDoesNotDominateUse,
    EntryBlockHasPredecessor,
    InvalidBlock,
    InvalidConstant,
    InvalidEntryPoint,
    InvalidFunction,
    InvalidInstruction,
    InvalidStructuredControl,
    InvalidType,
    InvalidValue,
    MissingEntryPoint,
    MissingFunctionEntryBlock,
    MissingTerminator,
    WrongBranchArgumentCount,
    WrongBranchArgumentType,
    WrongDefinition,
    WrongInterfaceDirection,
    WrongOperandType,
    WrongParameterIndex,
    WrongParent,
    WrongResultPresence,
    WrongResultType,
    WrongReturnType,
};

pub const Error = ValidationError || std.mem.Allocator.Error;

pub fn validate(module: *const module_ir.Module) Error!void {
    const entry_point = module.entry_point orelse return Error.MissingEntryPoint;
    if (!module.functions.isLive(entry_point))
        return Error.InvalidEntryPoint;

    for (module.types.entries.items) |entry| {
        const ty = entry orelse continue;
        try validateType(module, ty);
    }

    for (module.constants.entries.items) |entry| {
        const constant = entry orelse continue;

        if (!module.types.isLive(constant.type))
            return Error.InvalidType;

        if (constant.value == .composite) {
            for (constant.value.composite) |element| {
                if (!module.constants.isLive(element))
                    return Error.InvalidConstant;
            }
        }
    }

    for (module.values.entries.items, 0..) |entry, value_index| {
        const value = entry orelse continue;

        if (!module.types.isLive(value.type))
            return Error.InvalidType;

        const value_id = ids.ValueId.fromIndex(value_index);

        switch (value.definition) {
            .constant => |id| {
                const constant = module.constants.get(id) orelse return Error.InvalidConstant;
                if (constant.type != value.type)
                    return Error.WrongResultType;
            },
            .function_parameter => |definition| {
                const function = module.functions.get(definition.function) orelse return Error.InvalidFunction;
                if (definition.index >= function.parameters.items.len or function.parameters.items[definition.index] != value_id)
                    return Error.WrongParameterIndex;
            },
            .block_parameter => |definition| {
                const block = module.blocks.get(definition.block) orelse return Error.InvalidBlock;
                if (definition.index >= block.parameters.items.len or block.parameters.items[definition.index] != value_id)
                    return Error.WrongParameterIndex;
            },
            .instruction => |instruction_id| {
                const instruction = module.instructions.get(instruction_id) orelse return Error.InvalidInstruction;
                if (instruction.result != value_id)
                    return Error.WrongDefinition;
            },
            .undef => {},
        }
    }

    for (module.interface_variables.entries.items) |entry| {
        const variable = entry orelse continue;
        if (!module.types.isLive(variable.type))
            return Error.InvalidType;
    }

    for (module.resources.entries.items) |entry| {
        const resource = entry orelse continue;
        if (!module.types.isLive(resource.type))
            return Error.InvalidType;
    }

    for (module.functions.entries.items, 0..) |entry, function_index| {
        const function = entry orelse continue;
        const function_id = ids.FunctionId.fromIndex(function_index);

        if (!module.types.isLive(function.return_type))
            return Error.InvalidType;

        if (function.parameter_types.items.len != function.parameters.items.len)
            return Error.WrongParameterIndex;

        for (function.parameter_types.items, function.parameters.items, 0..) |parameter_type, parameter_id, index| {
            const parameter = module.values.get(parameter_id) orelse return Error.InvalidValue;

            if (parameter.type != parameter_type)
                return Error.WrongResultType;

            if (parameter.definition != .function_parameter or
                parameter.definition.function_parameter.function != function_id or
                parameter.definition.function_parameter.index != index)
                return Error.WrongDefinition;
        }

        const entry_block = function.entry_block orelse return Error.MissingFunctionEntryBlock;
        const entry_block_value = module.blocks.get(entry_block) orelse return Error.InvalidBlock;
        if (entry_block_value.parent_function != function_id) return Error.WrongParent;

        for (function.blocks.items) |block_id| {
            const block = module.blocks.get(block_id) orelse return Error.InvalidBlock;

            if (block.parent_function != function_id)
                return Error.WrongParent;

            try validateBlock(module, function_id, block_id, block);
        }

        for (function.blocks.items) |block_id| {
            const block = module.blocks.get(block_id).?;

            if (block.terminator) |terminator| {
                if (targetsBlock(terminator, entry_block))
                    return Error.EntryBlockHasPredecessor;
            }
        }

        try dominance.validate(module, function_id);
    }
}

fn validateType(module: *const module_ir.Module, ty: type_ir.Type) ValidationError!void {
    switch (ty) {
        .vector => |vector| {
            if (!module.types.isLive(vector.element_type) or vector.length < 2)
                return ValidationError.InvalidType;
        },
        .array => |array| {
            if (!module.types.isLive(array.element_type) or array.length == 0)
                return ValidationError.InvalidType;
        },
        .structure => |structure| for (structure.members) |member| {
            if (!module.types.isLive(member))
                return ValidationError.InvalidType;
        },
        .pointer => |pointer| {
            if (!module.types.isLive(pointer.pointee_type))
                return ValidationError.InvalidType;
        },
        .resource_handle => |handle| if (handle.data_type) |data_type| {
            if (!module.types.isLive(data_type))
                return ValidationError.InvalidType;
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
        const parameter = module.values.get(parameter_id) orelse return ValidationError.InvalidValue;
        if (parameter.definition != .block_parameter or
            parameter.definition.block_parameter.block != block_id or
            parameter.definition.block_parameter.index != index)
            return ValidationError.WrongDefinition;
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
        const instruction = module.instructions.get(instruction_id) orelse return ValidationError.InvalidInstruction;

        if (instruction.parent_block != block_id)
            return ValidationError.WrongParent;

        if (instruction.result) |result_id| {
            const result = module.values.get(result_id) orelse return ValidationError.InvalidValue;

            if (result.definition != .instruction or result.definition.instruction != instruction_id)
                return ValidationError.WrongDefinition;
        }

        try validateOperation(module, function_id, instruction);
    }

    const terminator = block.terminator orelse return ValidationError.MissingTerminator;
    try validateTerminator(module, function_id, terminator);
}

fn validateOperation(module: *const module_ir.Module, function_id: ids.FunctionId, instruction: *const inst_ir.Instruction) ValidationError!void {
    const result_type = if (instruction.result) |result| module.typeOf(result) orelse return ValidationError.InvalidValue else null;

    switch (instruction.operation) {
        .unary => |op| {
            const operand_type = try operandType(module, function_id, op.operand);

            if (result_type == null)
                return ValidationError.WrongResultPresence;

            if (result_type.? != operand_type)
                return ValidationError.WrongResultType;
        },
        .binary => |op| {
            const lhs_type = try operandType(module, function_id, op.lhs);
            const rhs_type = try operandType(module, function_id, op.rhs);

            if (lhs_type != rhs_type)
                return ValidationError.WrongOperandType;

            if (result_type == null or result_type.? != lhs_type)
                return ValidationError.WrongResultType;
        },
        .compare => |op| {
            const lhs_type = try operandType(module, function_id, op.lhs);
            if (try operandType(module, function_id, op.rhs) != lhs_type)
                return ValidationError.WrongOperandType;

            const result = result_type orelse return ValidationError.WrongResultPresence;
            if (!isBoolean(module, result))
                return ValidationError.WrongResultType;
        },
        .select => |op| {
            if (!isBoolean(module, try operandType(module, function_id, op.condition)))
                return ValidationError.WrongOperandType;

            const true_type = try operandType(module, function_id, op.true_value);
            if (try operandType(module, function_id, op.false_value) != true_type)
                return ValidationError.WrongOperandType;

            if (result_type == null or result_type.? != true_type)
                return ValidationError.WrongResultType;
        },
        .bitcast => |operand| {
            _ = try operandType(module, function_id, operand);
            if (result_type == null)
                return ValidationError.WrongResultPresence;
        },
        .composite_construct => |op| {
            const result = result_type orelse return ValidationError.WrongResultPresence;
            const ty = module.types.get(result) orelse return ValidationError.InvalidType;

            switch (ty.*) {
                .vector => |vector| {
                    if (op.elements.len != vector.length)
                        return ValidationError.WrongOperandType;

                    for (op.elements) |element| {
                        if (try operandType(module, function_id, element) != vector.element_type)
                            return ValidationError.WrongOperandType;
                    }
                },
                .structure => |structure| {
                    if (op.elements.len != structure.members.len)
                        return ValidationError.WrongOperandType;

                    for (op.elements, structure.members) |element, member_type| {
                        if (try operandType(module, function_id, element) != member_type)
                            return ValidationError.WrongOperandType;
                    }
                },
                else => return ValidationError.WrongResultType,
            }
        },
        .composite_extract => |op| {
            const composite_type = try operandType(module, function_id, op.composite);
            const extracted_type = try indexedType(module, composite_type, op.indices);

            if (result_type == null or result_type.? != extracted_type)
                return ValidationError.WrongResultType;
        },
        .load_interface => |op| {
            const variable = module.interface_variables.get(op.variable) orelse return ValidationError.InvalidValue;

            if (variable.direction != .input)
                return ValidationError.WrongInterfaceDirection;

            if (op.element_index) |index|
                _ = try operandType(module, function_id, index);

            if (result_type == null or result_type.? != variable.type)
                return ValidationError.WrongResultType;
        },
        .store_interface => |op| {
            if (result_type != null)
                return ValidationError.WrongResultPresence;

            const variable = module.interface_variables.get(op.variable) orelse return ValidationError.InvalidValue;

            if (variable.direction != .output)
                return ValidationError.WrongInterfaceDirection;

            if (try operandType(module, function_id, op.value) != variable.type)
                return ValidationError.WrongOperandType;

            if (op.element_index) |index|
                _ = try operandType(module, function_id, index);
        },
        .call => |op| {
            const callee = module.functions.get(op.function) orelse return ValidationError.InvalidFunction;

            if (op.arguments.len != callee.parameter_types.items.len)
                return ValidationError.WrongOperandType;

            for (op.arguments, callee.parameter_types.items) |argument, parameter_type| {
                if (try operandType(module, function_id, argument) != parameter_type)
                    return ValidationError.WrongOperandType;
            }

            const return_type = module.types.get(callee.return_type) orelse return ValidationError.InvalidType;

            if (return_type.* == .void) {
                if (result_type != null)
                    return ValidationError.WrongResultPresence;
            } else if (result_type == null or result_type.? != callee.return_type)
                return ValidationError.WrongResultType;
        },
    }
}

fn validateTerminator(module: *const module_ir.Module, function_id: ids.FunctionId, terminator: module_ir.Terminator) ValidationError!void {
    const function = module.functions.get(function_id) orelse return ValidationError.InvalidFunction;

    switch (terminator) {
        .branch => |edge| try validateEdge(module, function_id, edge),
        .conditional_branch => |branch| {
            if (!isBoolean(module, try operandType(module, function_id, branch.condition)))
                return ValidationError.WrongOperandType;

            try validateEdge(module, function_id, branch.true_edge);
            try validateEdge(module, function_id, branch.false_edge);
        },
        .return_void => {
            if (module.types.get(function.return_type).?.* != .void)
                return ValidationError.WrongReturnType;
        },
        .return_value => |value| {
            if (try operandType(module, function_id, value) != function.return_type)
                return ValidationError.WrongReturnType;
        },
        .discard => {
            if (module.stage != .fragment)
                return ValidationError.WrongReturnType;
        },
        .@"unreachable" => {},
    }
}

fn validateEdge(module: *const module_ir.Module, function_id: ids.FunctionId, edge: module_ir.Edge) ValidationError!void {
    const target = module.blocks.get(edge.target) orelse return ValidationError.InvalidBlock;

    if (target.parent_function != function_id)
        return ValidationError.CrossFunctionReference;

    if (edge.arguments.len != target.parameters.items.len)
        return ValidationError.WrongBranchArgumentCount;

    for (edge.arguments, target.parameters.items) |argument, parameter| {
        if (try operandType(module, function_id, argument) != module.typeOf(parameter).?)
            return ValidationError.WrongBranchArgumentType;
    }
}

fn validateTarget(module: *const module_ir.Module, function_id: ids.FunctionId, target_id: ids.BlockId) ValidationError!void {
    const target = module.blocks.get(target_id) orelse return ValidationError.InvalidStructuredControl;
    if (target.parent_function != function_id)
        return ValidationError.InvalidStructuredControl;
}

fn operandType(module: *const module_ir.Module, function_id: ids.FunctionId, value_id: ids.ValueId) ValidationError!ids.TypeId {
    const value = module.values.get(value_id) orelse return ValidationError.InvalidValue;
    const owner = valueFunction(module, value_id) catch return ValidationError.InvalidValue;

    if (owner) |actual| {
        if (actual != function_id)
            return ValidationError.CrossFunctionReference;
    }
    return value.type;
}

fn valueFunction(module: *const module_ir.Module, value_id: ids.ValueId) ValidationError!?ids.FunctionId {
    const value = module.values.get(value_id) orelse return ValidationError.InvalidValue;

    return switch (value.definition) {
        .constant, .undef => null,
        .function_parameter => |definition| definition.function,
        .block_parameter => |definition| (module.blocks.get(definition.block) orelse return ValidationError.InvalidBlock).parent_function,
        .instruction => |instruction_id| blk: {
            const instruction = module.instructions.get(instruction_id) orelse return ValidationError.InvalidInstruction;
            const block = module.blocks.get(instruction.parent_block) orelse return ValidationError.InvalidBlock;
            break :blk block.parent_function;
        },
    };
}

fn indexedType(module: *const module_ir.Module, root: ids.TypeId, indices: []const u32) ValidationError!ids.TypeId {
    if (indices.len == 0)
        return ValidationError.WrongOperandType;

    var current = root;

    for (indices) |index| {
        const ty = module.types.get(current) orelse return ValidationError.InvalidType;
        current = switch (ty.*) {
            .vector => |vector| if (index < vector.length)
                vector.element_type
            else
                return ValidationError.WrongOperandType,
            .array => |array| if (index < array.length)
                array.element_type
            else
                return ValidationError.WrongOperandType,
            .structure => |structure| if (index < structure.members.len)
                structure.members[index]
            else
                return ValidationError.WrongOperandType,

            else => return ValidationError.WrongOperandType,
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

test "Validator: Error wrong block argument count" {
    // shader compute @main
    // {
    //     fn @main() -> void
    //     {
    //         .entry():
    //             branch .merge()
    //
    //         .merge(%0: u32):
    //             return
    //     }
    // }

    var module = module_ir.Module.init(std.testing.allocator, .compute);
    defer module.deinit();
    var builder = Builder.init(&module);

    const void_type = try builder.internType(.void);
    const u32_type = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });
    const main = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(main);
    const entry = try builder.addBlock(main, "entry");
    const merge = try builder.addBlock(main, "merge");
    _ = try builder.addBlockParameter(merge, u32_type, null);
    try builder.setTerminator(entry, .{ .branch = try builder.edge(merge, &.{}) });
    try builder.setTerminator(merge, .return_void);

    try std.testing.expectError(Error.WrongBranchArgumentCount, validate(&module));
}

test "Validator: Error SSA definition does not dominate its use" {
    // shader compute @main
    // {
    //     %0: constant bool = true
    //     %1: constant u32 = bits(0x1)
    //
    //     fn @main() -> void
    //     {
    //         .entry():
    //             conditional_branch %0, .left(), .right()
    //
    //         .left():
    //             %2: u32 = integer_add %1, %1
    //             branch .merge()
    //
    //         .right():
    //             branch .merge()
    //
    //         .merge():
    //             %3: u32 = integer_multiply %2, %1
    //             return
    //     }
    // }

    var module = module_ir.Module.init(std.testing.allocator, .compute);
    defer module.deinit();
    var builder = Builder.init(&module);

    const void_type = try builder.internType(.void);
    const bool_type = try builder.internType(.boolean);
    const u32_type = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });
    const condition = try builder.internConstant(bool_type, .{ .boolean = true });
    const one = try builder.internConstant(u32_type, .{ .integer_bits = 1 });
    const main = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(main);
    const entry = try builder.addBlock(main, "entry");
    const left = try builder.addBlock(main, "left");
    const right = try builder.addBlock(main, "right");
    const merge = try builder.addBlock(main, "merge");

    try builder.setTerminator(
        entry,
        .{
            .conditional_branch = .{
                .condition = condition,
                .true_edge = try builder.edge(left, &.{}),
                .false_edge = try builder.edge(right, &.{}),
            },
        },
    );

    const left_value = (try builder.appendInstruction(left, u32_type, .{
        .binary = .{
            .opcode = .integer_add,
            .lhs = one,
            .rhs = one,
        },
    }, null)).?;

    try builder.setTerminator(left, .{ .branch = try builder.edge(merge, &.{}) });
    try builder.setTerminator(right, .{ .branch = try builder.edge(merge, &.{}) });

    _ = try builder.appendInstruction(merge, u32_type, .{
        .binary = .{
            .opcode = .integer_multiply,
            .lhs = left_value,
            .rhs = one,
        },
    }, null);

    try builder.setTerminator(merge, .return_void);

    try std.testing.expectError(Error.DefinitionDoesNotDominateUse, validate(&module));
}
