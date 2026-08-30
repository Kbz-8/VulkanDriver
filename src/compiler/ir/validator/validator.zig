const std = @import("std");
const ids = @import("../id.zig");
const type_ir = @import("../type.zig");
const inst_ir = @import("../instruction.zig");
const module_ir = @import("../module.zig");

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
    WrongResourceKind,
    WrongResultPresence,
    WrongResultType,
    WrongReturnType,
};

const IntegerShape = struct {
    bits: u16,
    components: u8,
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
            const operand_type =
                try operandType(module, function_id, op.operand);

            const result =
                result_type orelse return ValidationError.WrongResultPresence;

            switch (op.opcode) {
                .bitwise_not => {
                    if (!isIntegerScalarOrVector(module, operand_type))
                        return ValidationError.WrongOperandType;

                    if (!isIntegerScalarOrVector(module, result))
                        return ValidationError.WrongResultType;

                    if (!haveSameIntegerShape(module, operand_type, result))
                        return ValidationError.WrongResultType;
                },

                .logical_not => {
                    if (!isBoolean(module, operand_type))
                        return ValidationError.WrongOperandType;

                    if (!isBoolean(module, result))
                        return ValidationError.WrongResultType;
                },

                .negate => {
                    if (result != operand_type)
                        return ValidationError.WrongResultType;
                },
            }
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
        .load_buffer => |op| {
            const resource = module.resources.get(op.resource) orelse return ValidationError.InvalidValue;
            if (resource.kind != .storage_buffer)
                return ValidationError.WrongResourceKind;

            if (!isUnsignedInteger(module, try operandType(module, function_id, op.byte_offset)))
                return ValidationError.WrongOperandType;

            const result = result_type orelse return ValidationError.WrongResultPresence;
            if (!isBufferAccessibleType(module, result))
                return ValidationError.WrongResultType;
        },
        .store_buffer => |op| {
            if (result_type != null)
                return ValidationError.WrongResultPresence;

            const resource = module.resources.get(op.resource) orelse return ValidationError.InvalidValue;
            if (resource.kind != .storage_buffer)
                return ValidationError.WrongResourceKind;

            if (!isUnsignedInteger(module, try operandType(module, function_id, op.byte_offset)))
                return ValidationError.WrongOperandType;

            if (!isBufferAccessibleType(module, try operandType(module, function_id, op.value)))
                return ValidationError.WrongOperandType;
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
        .array_length => |op| {
            const resource = module.resources.get(op.resource) orelse return ValidationError.InvalidValue;

            if (resource.kind != .storage_buffer)
                return ValidationError.WrongResourceKind;

            if (!isUnsignedInteger(module, try operandType(module, function_id, op.byte_offset)))
                return ValidationError.WrongOperandType;

            if (op.stride == 0)
                return ValidationError.InvalidInstruction;

            const result = result_type orelse return ValidationError.WrongResultPresence;

            if (!isArrayLengthResultType(module, result))
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

fn isUnsignedInteger(module: *const module_ir.Module, type_id: ids.TypeId) bool {
    const ty = module.types.get(type_id) orelse return false;
    return switch (ty.*) {
        .integer => |integer| integer.signedness == .unsigned,
        else => false,
    };
}

fn isBufferAccessibleType(module: *const module_ir.Module, type_id: ids.TypeId) bool {
    const ty = module.types.get(type_id) orelse return false;
    return switch (ty.*) {
        .integer, .floating => true,
        .vector => |vector| {
            const element_type = module.types.get(vector.element_type) orelse return false;
            return element_type.* == .integer or element_type.* == .floating;
        },
        else => false,
    };
}

fn isArrayLengthResultType(module: *const module_ir.Module, type_id: ids.TypeId) bool {
    const ty = module.types.get(type_id) orelse return false;

    return switch (ty.*) {
        .integer => |integer| integer.signedness == .unsigned and (integer.bits == 32 or integer.bits == 64),

        else => false,
    };
}

fn integerShape(module: *const module_ir.Module, type_id: ids.TypeId) ?IntegerShape {
    const ty = module.types.get(type_id) orelse return null;

    return switch (ty.*) {
        .integer => |integer| .{
            .bits = integer.bits,
            .components = 1,
        },

        .vector => |vector| blk: {
            const element =
                module.types.get(vector.element_type) orelse return null;

            const integer = switch (element.*) {
                .integer => |integer| integer,
                else => return null,
            };

            break :blk .{
                .bits = integer.bits,
                .components = vector.length,
            };
        },

        else => null,
    };
}

fn isIntegerScalarOrVector(module: *const module_ir.Module, type_id: ids.TypeId) bool {
    return integerShape(module, type_id) != null;
}

fn haveSameIntegerShape(module: *const module_ir.Module, lhs: ids.TypeId, rhs: ids.TypeId) bool {
    const lhs_shape = integerShape(module, lhs) orelse return false;
    const rhs_shape = integerShape(module, rhs) orelse return false;

    return lhs_shape.bits == rhs_shape.bits and
        lhs_shape.components == rhs_shape.components;
}

fn targetsBlock(terminator: module_ir.Terminator, target: ids.BlockId) bool {
    return switch (terminator) {
        .branch => |edge| edge.target == target,
        .conditional_branch => |branch| branch.true_edge.target == target or branch.false_edge.target == target,
        else => false,
    };
}

fn expectValidationError(expected: Error, source: []const u8) !void {
    const parser = @import("../parser/parser.zig");
    try std.testing.expectError(expected, parser.parseString(std.testing.allocator, source));
}

test "Validator: well-typed control flow and operations" {
    const parser = @import("../parser/parser.zig");

    var module = try parser.parseString(std.testing.allocator,
        \\shader vertex @main
        \\{
        \\    @input: u32 = input[location(0), component(0), index(0)]
        \\    @output: u32 = output[location(0), component(0), index(0)]
        \\    %condition: constant bool = true
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %loaded: u32 = load_interface @input
        \\            conditional_branch %condition, .left(%loaded), .right(%one)
        \\        .left(%left_value: u32):
        \\            %left_result: u32 = integer_add %left_value, %one
        \\            branch .merge(%left_result)
        \\        .right(%right_value: u32):
        \\            %right_result: u32 = call @identity(%right_value)
        \\            branch .merge(%right_result)
        \\        .merge(%result: u32):
        \\            store_interface @output, %result
        \\            return
        \\    }
        \\    fn @identity(%value: u32) -> u32
        \\    {
        \\        .entry():
        \\            return %value
        \\    }
        \\}
    );
    defer module.deinit();

    try validate(&module);
}

test "Validator: required entry point" {
    try expectValidationError(Error.MissingEntryPoint,
        \\shader compute
        \\{
        \\    fn @helper() -> void
        \\    {
        \\        .entry():
        \\            return
        \\    }
        \\}
    );
}

test "Validator: required function entry block" {
    try expectValidationError(Error.MissingFunctionEntryBlock,
        \\shader compute @main
        \\{
        \\    fn @main() -> void
        \\    {
        \\    }
        \\}
    );
}

test "Validator: reject invalid aggregate types" {
    try expectValidationError(Error.InvalidType,
        \\shader compute @main
        \\{
        \\    fn @main(%value: vec1[u32]) -> void
        \\    {
        \\        .entry():
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.InvalidType,
        \\shader compute @main
        \\{
        \\    fn @main(%value: array[u32, 0]) -> void
        \\    {
        \\        .entry():
        \\            return
        \\    }
        \\}
    );
}

test "Validator: reject predecessor of the entry block" {
    try expectValidationError(Error.EntryBlockHasPredecessor,
        \\shader compute @main
        \\{
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            return
        \\        .back_edge():
        \\            branch .entry()
        \\    }
        \\}
    );
}

test "Validator: check branch arguments" {
    try expectValidationError(Error.WrongBranchArgumentCount,
        \\shader compute @main
        \\{
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            branch .merge()
        \\        .merge(%value: u32):
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongBranchArgumentType,
        \\shader compute @main
        \\{
        \\    %condition: constant bool = true
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            branch .merge(%condition)
        \\        .merge(%value: u32):
        \\            return
        \\    }
        \\}
    );
}

test "Validator: check terminator operand and return types" {
    try expectValidationError(Error.WrongOperandType,
        \\shader compute @main
        \\{
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            conditional_branch %one, .left(), .right()
        \\        .left():
        \\            return
        \\        .right():
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongReturnType,
        \\shader compute @main
        \\{
        \\    fn @main() -> u32
        \\    {
        \\        .entry():
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongReturnType,
        \\shader compute @main
        \\{
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            return %one
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongReturnType,
        \\shader compute @main
        \\{
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            discard
        \\    }
        \\}
    );
}

test "Validator: check unary, binary, compare, and select types" {
    try expectValidationError(Error.WrongResultType,
        \\shader compute @main
        \\{
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: bool = bitwise_not %one
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongOperandType,
        \\shader compute @main
        \\{
        \\    %one: constant u32 = 1
        \\    %float: constant f32 = 1.0
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: u32 = integer_add %one, %float
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongResultType,
        \\shader compute @main
        \\{
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: u32 = cmp_equal %one, %one
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongOperandType,
        \\shader compute @main
        \\{
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: u32 = select %one, %one, %one
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongOperandType,
        \\shader compute @main
        \\{
        \\    %condition: constant bool = true
        \\    %one: constant u32 = 1
        \\    %float: constant f32 = 1.0
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: u32 = select %condition, %one, %float
        \\            return
        \\    }
        \\}
    );
}

test "Validator: check composite operations" {
    try expectValidationError(Error.WrongOperandType,
        \\shader compute @main
        \\{
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: vec2[u32] = composite_construct %one
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongResultType,
        \\shader compute @main
        \\{
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %vector: vec2[u32] = composite_construct %one, %one
        \\            %result: bool = composite_extract %vector[0]
        \\            return
        \\    }
        \\}
    );
}

test "Validator: check interface direction and value types" {
    try expectValidationError(Error.WrongInterfaceDirection,
        \\shader vertex @main
        \\{
        \\    @output: u32 = output[location(0), component(0), index(0)]
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %value: u32 = load_interface @output
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongInterfaceDirection,
        \\shader vertex @main
        \\{
        \\    @input: u32 = input[location(0), component(0), index(0)]
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            store_interface @input, %one
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongOperandType,
        \\shader vertex @main
        \\{
        \\    @output: u32 = output[location(0), component(0), index(0)]
        \\    %value: constant f32 = 1.0
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            store_interface @output, %value
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongResultPresence,
        \\shader vertex @main
        \\{
        \\    @output: u32 = output[location(0), component(0), index(0)]
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: bool = store_interface @output, %one
        \\            return
        \\    }
        \\}
    );
}

test "Validator: check buffer resources, offsets, and value types" {
    try expectValidationError(Error.WrongResourceKind,
        \\shader compute @main
        \\{
        \\    @uniforms: u32 = uniform_buffer[set(0), binding(0)]
        \\    %offset: constant u32 = 0
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %value: u32 = load_buffer @uniforms, %offset
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongResourceKind,
        \\shader compute @main
        \\{
        \\    @uniforms: u32 = uniform_buffer[set(0), binding(0)]
        \\    %offset: constant u32 = 0
        \\    %value: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            store_buffer @uniforms, %offset, %value
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongOperandType,
        \\shader compute @main
        \\{
        \\    @storage: u32 = storage_buffer[set(0), binding(0)]
        \\    %offset: constant i32 = 0
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %value: u32 = load_buffer @storage, %offset
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongResultType,
        \\shader compute @main
        \\{
        \\    @storage: struct[u32, f32] = storage_buffer[set(0), binding(0)]
        \\    %offset: constant u32 = 0
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %value: struct[u32, f32] = load_buffer @storage, %offset
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongOperandType,
        \\shader compute @main
        \\{
        \\    @storage: struct[u32, f32] = storage_buffer[set(0), binding(0)]
        \\    %offset: constant u32 = 0
        \\    %value: constant ptr[private, u32] = null
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            store_buffer @storage, %offset, %value
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongResultPresence,
        \\shader compute @main
        \\{
        \\    @storage: struct[u32, f32] = storage_buffer[set(0), binding(0)]
        \\    %offset: constant u32 = 0
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            load_buffer @storage, %offset
        \\            return
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongResultPresence,
        \\shader compute @main
        \\{
        \\    @storage: u32 = storage_buffer[set(0), binding(0)]
        \\    %offset: constant u32 = 0
        \\    %value: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: u32 = store_buffer @storage, %offset, %value
        \\            return
        \\    }
        \\}
    );
}

test "Validator: check function calls" {
    try expectValidationError(Error.WrongOperandType,
        \\shader compute @main
        \\{
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: u32 = call @identity()
        \\            return
        \\    }
        \\    fn @identity(%value: u32) -> u32
        \\    {
        \\        .entry():
        \\            return %value
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongOperandType,
        \\shader compute @main
        \\{
        \\    %condition: constant bool = true
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: u32 = call @identity(%condition)
        \\            return
        \\    }
        \\    fn @identity(%value: u32) -> u32
        \\    {
        \\        .entry():
        \\            return %value
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongResultType,
        \\shader compute @main
        \\{
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: f32 = call @identity(%one)
        \\            return
        \\    }
        \\    fn @identity(%value: u32) -> u32
        \\    {
        \\        .entry():
        \\            return %value
        \\    }
        \\}
    );

    try expectValidationError(Error.WrongResultPresence,
        \\shader compute @main
        \\{
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: u32 = call @helper()
        \\            return
        \\    }
        \\    fn @helper() -> void
        \\    {
        \\        .entry():
        \\            return
        \\    }
        \\}
    );
}

test "Validator: reject cross-function value references" {
    try expectValidationError(Error.CrossFunctionReference,
        \\shader compute @main
        \\{
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %main_value: u32 = integer_add %one, %one
        \\            return
        \\    }
        \\    fn @helper() -> void
        \\    {
        \\        .entry():
        \\            %result: u32 = integer_add %main_value, %one
        \\            return
        \\    }
        \\}
    );
}

test "Validator: reject an SSA definition that does not dominate its use" {
    try expectValidationError(Error.DefinitionDoesNotDominateUse,
        \\shader compute @main
        \\{
        \\    %condition: constant bool = true
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            conditional_branch %condition, .left(), .right()
        \\        .left():
        \\            %left_value: u32 = integer_add %one, %one
        \\            branch .merge()
        \\        .right():
        \\            branch .merge()
        \\        .merge():
        \\            %result: u32 = integer_multiply %left_value, %one
        \\            return
        \\    }
        \\}
    );
}

test "Validator: reject a same-block use before its definition" {
    const parser = @import("../parser/parser.zig");

    var module = try parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %first: u32 = integer_add %one, %one
        \\            %second: u32 = integer_multiply %first, %one
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    const function = module.functions.get(module.entry_point.?).?;
    const block = module.blocks.get(function.entry_block.?).?;
    const first_instruction = block.instructions.items[0];
    const second_instruction = block.instructions.items[1];
    const later_result = module.instructions.get(second_instruction).?.result.?;
    module.instructions.getMut(first_instruction).?.operation.binary.lhs = later_result;

    try std.testing.expectError(Error.DefinitionDoesNotDominateUse, validate(&module));
}

test "Validator: reject a structured-control target in another function" {
    const parser = @import("../parser/parser.zig");

    var module = try parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            return
        \\    }
        \\    fn @helper() -> void
        \\    {
        \\        .entry():
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    const main = module.functions.get(module.entry_point.?).?;
    const helper = module.functions.get(ids.FunctionId.fromIndex(1)).?;
    module.blocks.getMut(main.entry_block.?).?.structured_control = .{
        .selection = .{ .merge_block = helper.entry_block.? },
    };

    try std.testing.expectError(Error.InvalidStructuredControl, validate(&module));
}
