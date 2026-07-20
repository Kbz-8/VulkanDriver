const std = @import("std");
const Builder = @import("../Builder.zig");
const constant_ir = @import("../constant.zig");
const ids = @import("../id.zig");
const inst_ir = @import("../instruction.zig");
const module_ir = @import("../module.zig");
const ast = @import("ast.zig");

const ValueRef = ast.ValueRef;
const ParsedModule = ast.ParsedModule;
const ParsedOperation = ast.ParsedOperation;
const ParsedTerminator = ast.ParsedTerminator;
const ParsedEdge = ast.ParsedEdge;

const LoweredOperation = struct {
    operation: inst_ir.Operation,
    inferred_type: ?ids.TypeId,
};

pub fn lower(allocator: std.mem.Allocator, module: *module_ir.Module, parsed: *ParsedModule) !void {
    var builder = Builder.init(module);
    var values: std.StringHashMapUnmanaged(ids.ValueId) = .empty;
    var constants: std.AutoHashMapUnmanaged(u32, ids.ConstantId) = .empty;
    var interfaces: std.StringHashMapUnmanaged(ids.InterfaceVariableId) = .empty;
    var functions: std.StringHashMapUnmanaged(ids.FunctionId) = .empty;

    for (parsed.interfaces.items) |interface| {
        if (interfaces.contains(interface.name))
            return error.DuplicateName;

        const id = try builder.addInterfaceVariable(interface.ty, interface.direction, interface.semantic, interface.name);
        try interfaces.put(allocator, interface.name, id);
    }

    for (parsed.constants.items, 0..) |constant, constant_index| {
        const value: constant_ir.ConstantValue = switch (constant.value) {
            .boolean => |item| .{ .boolean = item },
            .integer_bits => |item| .{ .integer_bits = item },
            .float_bits => |item| .{ .float_bits = item },
            .null_value => .null,
            .undef => .undef,
            .composite => |printed_elements| blk: {
                var elements: std.ArrayList(ids.ConstantId) = .empty;
                for (printed_elements) |printed_element| {
                    try elements.append(allocator, constants.get(printed_element) orelse return error.UnknownConstant);
                }
                break :blk .{ .composite = elements.items };
            },
        };

        const value_id = try builder.internConstant(constant.ty, value);
        try builder.setValueName(value_id, valueName(constant.printed_value));
        try putValue(allocator, &values, constant.printed_value, value_id);
        const definition = module.values.get(value_id).?.definition;

        if (definition != .constant)
            return error.InvalidResult;

        try constants.put(allocator, @intCast(constant_index), definition.constant);
    }

    for (parsed.functions.items) |*function| {
        if (functions.contains(function.name))
            return error.DuplicateName;

        const function_id = try builder.addFunction(function.return_type, function.name);
        function.actual = function_id;
        try functions.put(allocator, function.name, function_id);

        for (function.parameters.items) |parameter| {
            const value_id = try builder.addFunctionParameter(function_id, parameter.ty, valueName(parameter.printed_value));
            try putValue(allocator, &values, parameter.printed_value, value_id);
        }
    }

    if (parsed.entry_point_name) |entry_name|
        builder.setEntryPoint(functions.get(entry_name) orelse return error.UnknownFunction);

    for (parsed.functions.items) |*function| {
        var block_names: std.StringHashMapUnmanaged(ids.BlockId) = .empty;
        for (function.blocks.items) |*block| {
            if (block_names.contains(block.name))
                return error.DuplicateName;

            const block_id = try builder.addBlock(function.actual.?, block.name);
            block.actual = block_id;
            try block_names.put(allocator, block.name, block_id);

            for (block.parameters.items) |parameter| {
                const value_id = try builder.addBlockParameter(block_id, parameter.ty, valueName(parameter.printed_value));
                try putValue(allocator, &values, parameter.printed_value, value_id);
            }
        }

        for (function.blocks.items) |block| {
            for (block.instructions.items) |instruction| {
                const lowered = try lowerOperation(allocator, module, &values, &interfaces, &functions, instruction.operation);
                const result_type = instruction.result_type orelse lowered.inferred_type;

                if (instruction.printed_result != null and result_type == null)
                    return error.MissingResultType;

                if (instruction.printed_result == null and result_type != null)
                    return error.InvalidResult;

                const result = try builder.appendInstruction(
                    block.actual.?,
                    result_type,
                    lowered.operation,
                    if (instruction.printed_result) |printed_result| valueName(printed_result) else null,
                );
                if (instruction.printed_result) |printed_result|
                    try putValue(allocator, &values, printed_result, result orelse return error.InvalidResult)
                else if (result != null)
                    return error.InvalidResult;
            }
            const terminator = try lowerTerminator(allocator, &builder, &values, &block_names, block.terminator orelse return error.MissingTerminator);
            try builder.setTerminator(block.actual.?, terminator);
        }
    }
}

fn lowerOperation(
    allocator: std.mem.Allocator,
    module: *module_ir.Module,
    values: *const std.StringHashMapUnmanaged(ids.ValueId),
    interfaces: *const std.StringHashMapUnmanaged(ids.InterfaceVariableId),
    functions: *const std.StringHashMapUnmanaged(ids.FunctionId),
    parsed: ParsedOperation,
) !LoweredOperation {
    return switch (parsed) {
        .unary => |op| blk: {
            const operand = resolveValue(values, op.operand) orelse return error.UnknownValue;

            break :blk .{
                .operation = .{
                    .unary = .{
                        .opcode = op.opcode,
                        .operand = operand,
                    },
                },
                .inferred_type = module.typeOf(operand),
            };
        },
        .binary => |op| blk: {
            const lhs = resolveValue(values, op.lhs) orelse return error.UnknownValue;
            const rhs = resolveValue(values, op.rhs) orelse return error.UnknownValue;

            break :blk .{
                .operation = .{
                    .binary = .{
                        .opcode = op.opcode,
                        .lhs = lhs,
                        .rhs = rhs,
                    },
                },
                .inferred_type = module.typeOf(lhs),
            };
        },
        .compare => |op| blk: {
            const lhs = resolveValue(values, op.lhs) orelse return error.UnknownValue;
            const rhs = resolveValue(values, op.rhs) orelse return error.UnknownValue;

            break :blk .{
                .operation = .{
                    .compare = .{
                        .opcode = op.opcode,
                        .lhs = lhs,
                        .rhs = rhs,
                    },
                },
                .inferred_type = try module.internType(.boolean),
            };
        },
        .select => |op| blk: {
            const condition = resolveValue(values, op.condition) orelse return error.UnknownValue;
            const true_value = resolveValue(values, op.true_value) orelse return error.UnknownValue;
            const false_value = resolveValue(values, op.false_value) orelse return error.UnknownValue;

            break :blk .{
                .operation = .{
                    .select = .{
                        .condition = condition,
                        .true_value = true_value,
                        .false_value = false_value,
                    },
                },
                .inferred_type = module.typeOf(true_value),
            };
        },
        .bitcast => |printed_operand| blk: {
            const operand = resolveValue(values, printed_operand) orelse return error.UnknownValue;
            break :blk .{ .operation = .{ .bitcast = operand }, .inferred_type = module.typeOf(operand) };
        },
        .composite_construct => |printed_elements| blk: {
            var elements: std.ArrayList(ids.ValueId) = .empty;
            var element_types: std.ArrayList(ids.TypeId) = .empty;
            for (printed_elements) |printed_element| {
                const element = resolveValue(values, printed_element) orelse return error.UnknownValue;
                try elements.append(allocator, element);
                try element_types.append(allocator, module.typeOf(element) orelse return error.UnknownValue);
            }

            break :blk .{
                .operation = .{
                    .composite_construct = .{
                        .elements = elements.items,
                    },
                },
                .inferred_type = try inferCompositeType(module, element_types.items),
            };
        },
        .composite_extract => |op| blk: {
            const composite = resolveValue(values, op.composite) orelse return error.UnknownValue;

            break :blk .{
                .operation = .{
                    .composite_extract = .{
                        .composite = composite,
                        .indices = op.indices,
                    },
                },
                .inferred_type = try extractedType(module, module.typeOf(composite) orelse return error.UnknownValue, op.indices),
            };
        },
        .load_interface => |name| blk: {
            const interface_id = interfaces.get(name) orelse return error.UnknownInterface;

            break :blk .{
                .operation = .{
                    .load_interface = .{
                        .variable = interface_id,
                    },
                },
                .inferred_type = module.interface_variables.get(interface_id).?.type,
            };
        },
        .store_interface => |op| blk: {
            const interface_id = interfaces.get(op.interface_name) orelse return error.UnknownInterface;
            const value = resolveValue(values, op.value) orelse return error.UnknownValue;

            break :blk .{
                .operation = .{
                    .store_interface = .{
                        .variable = interface_id,
                        .value = value,
                    },
                },
                .inferred_type = null,
            };
        },
        .call => |op| blk: {
            const function_id = functions.get(op.function_name) orelse return error.UnknownFunction;
            var arguments: std.ArrayList(ids.ValueId) = .empty;

            for (op.arguments) |printed_argument|
                try arguments.append(allocator, resolveValue(values, printed_argument) orelse return error.UnknownValue);

            const return_type = module.functions.get(function_id).?.return_type;
            const return_ir_type = module.types.get(return_type) orelse return error.InvalidType;

            break :blk .{
                .operation = .{
                    .call = .{
                        .function = function_id,
                        .arguments = arguments.items,
                    },
                },
                .inferred_type = if (return_ir_type.* == .void) null else return_type,
            };
        },
    };
}

fn lowerTerminator(
    allocator: std.mem.Allocator,
    builder: *Builder,
    values: *const std.StringHashMapUnmanaged(ids.ValueId),
    blocks: *const std.StringHashMapUnmanaged(ids.BlockId),
    parsed: ParsedTerminator,
) !module_ir.Terminator {
    return switch (parsed) {
        .branch => |edge| .{
            .branch = try lowerEdge(allocator, builder, values, blocks, edge),
        },
        .conditional_branch => |branch| .{
            .conditional_branch = .{
                .condition = resolveValue(values, branch.condition) orelse return error.UnknownValue,
                .true_edge = try lowerEdge(allocator, builder, values, blocks, branch.true_edge),
                .false_edge = try lowerEdge(allocator, builder, values, blocks, branch.false_edge),
            },
        },
        .return_void => .return_void,
        .return_value => |printed_value| .{
            .return_value = resolveValue(values, printed_value) orelse return error.UnknownValue,
        },
        .discard => .discard,
        .unreachable_value => .@"unreachable",
    };
}

fn lowerEdge(
    allocator: std.mem.Allocator,
    builder: *Builder,
    values: *const std.StringHashMapUnmanaged(ids.ValueId),
    blocks: *const std.StringHashMapUnmanaged(ids.BlockId),
    parsed: ParsedEdge,
) !module_ir.Edge {
    var arguments: std.ArrayList(ids.ValueId) = .empty;
    for (parsed.arguments) |printed_argument|
        try arguments.append(allocator, resolveValue(values, printed_argument) orelse return error.UnknownValue);

    return builder.edge(blocks.get(parsed.block_name) orelse return error.UnknownBlock, arguments.items);
}

fn inferCompositeType(module: *module_ir.Module, element_types: []const ids.TypeId) !ids.TypeId {
    if (element_types.len >= 2 and element_types.len <= std.math.maxInt(u8)) {
        const first = element_types[0];
        for (element_types[1..]) |element_type| {
            if (element_type != first)
                return module.internType(.{
                    .structure = .{
                        .members = element_types,
                    },
                });
        }
        return module.internType(.{
            .vector = .{
                .element_type = first,
                .length = @intCast(element_types.len),
            },
        });
    }
    return module.internType(.{
        .structure = .{
            .members = element_types,
        },
    });
}

fn extractedType(module: *const module_ir.Module, root_type: ids.TypeId, indices: []const u32) !ids.TypeId {
    var current = root_type;
    for (indices) |index| {
        const ty = module.types.get(current) orelse return error.InvalidType;
        current = switch (ty.*) {
            .vector => |vector| if (index < vector.length)
                vector.element_type
            else
                return error.InvalidCompositeIndex,
            .array => |array| if (index < array.length)
                array.element_type
            else
                return error.InvalidCompositeIndex,
            .structure => |structure| if (index < structure.members.len)
                structure.members[index]
            else
                return error.InvalidCompositeIndex,
            else => return error.InvalidCompositeIndex,
        };
    }
    return current;
}

fn putValue(allocator: std.mem.Allocator, values: *std.StringHashMapUnmanaged(ids.ValueId), printed: ValueRef, actual: ids.ValueId) !void {
    if (values.contains(printed))
        return error.DuplicateValue;
    try values.put(allocator, printed, actual);
}

fn resolveValue(values: *const std.StringHashMapUnmanaged(ids.ValueId), printed: ValueRef) ?ids.ValueId {
    return values.get(printed);
}

fn valueName(reference: ValueRef) ?[]const u8 {
    for (reference) |byte| {
        if (!std.ascii.isDigit(byte))
            return reference;
    }
    return null;
}
