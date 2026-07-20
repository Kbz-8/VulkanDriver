const std = @import("std");
const ids = @import("id.zig");

pub const TypeId = ids.TypeId;
pub const ValueId = ids.ValueId;
pub const BlockId = ids.BlockId;
pub const FunctionId = ids.FunctionId;
pub const InterfaceVariableId = ids.InterfaceVariableId;

pub const SourceLocation = struct {
    file: ?[]const u8 = null,
    line: u32,
    column: u32,
};

pub const UnaryOpcode = enum {
    negate,
    logical_not,
    bitwise_not,
};

pub const BinaryOpcode = enum {
    integer_add,
    integer_subtract,
    integer_multiply,
    unsigned_divide,
    signed_divide,
    unsigned_modulo,
    signed_modulo,
    float_add,
    float_subtract,
    float_multiply,
    float_divide,
    float_modulo,
    shift_left,
    logical_shift_right,
    arithmetic_shift_right,
    bitwise_and,
    bitwise_or,
    bitwise_xor,
    logical_and,
    logical_or,
};

pub const CompareOpcode = enum {
    equal,
    not_equal,
    unsigned_less,
    signed_less,
    ordered_float_equal,
    unordered_float_equal,
    ordered_float_not_equal,
    unordered_float_not_equal,
    ordered_float_less,
    unordered_float_less,
};

pub const Unary = struct {
    opcode: UnaryOpcode,
    operand: ValueId,
};

pub const Binary = struct {
    opcode: BinaryOpcode,
    lhs: ValueId,
    rhs: ValueId,
};

pub const Compare = struct {
    opcode: CompareOpcode,
    lhs: ValueId,
    rhs: ValueId,
};

pub const Select = struct {
    condition: ValueId,
    true_value: ValueId,
    false_value: ValueId,
};

pub const CompositeConstruct = struct {
    elements: []const ValueId,
};

pub const CompositeExtract = struct {
    composite: ValueId,
    indices: []const u32,
};

pub const LoadInterface = struct {
    variable: InterfaceVariableId,
    element_index: ?ValueId = null,
};

pub const StoreInterface = struct {
    variable: InterfaceVariableId,
    value: ValueId,
    element_index: ?ValueId = null,
};

pub const Call = struct {
    function: FunctionId,
    arguments: []const ValueId,
};

pub const Operation = union(enum) {
    unary: Unary,
    binary: Binary,
    compare: Compare,
    select: Select,
    bitcast: ValueId,
    composite_construct: CompositeConstruct,
    composite_extract: CompositeExtract,
    load_interface: LoadInterface,
    store_interface: StoreInterface,
    call: Call,

    pub fn visitValueUses(self: Operation, context: anytype, comptime visitor: anytype) void {
        switch (self) {
            .unary => |op| visitor(context, op.operand),
            .binary => |op| {
                visitor(context, op.lhs);
                visitor(context, op.rhs);
            },
            .compare => |op| {
                visitor(context, op.lhs);
                visitor(context, op.rhs);
            },
            .select => |op| {
                visitor(context, op.condition);
                visitor(context, op.true_value);
                visitor(context, op.false_value);
            },
            .bitcast => |operand| visitor(context, operand),
            .composite_construct => |op| for (op.elements) |element| visitor(context, element),
            .composite_extract => |op| visitor(context, op.composite),
            .load_interface => |op| if (op.element_index) |index| visitor(context, index),
            .store_interface => |op| {
                visitor(context, op.value);
                if (op.element_index) |index|
                    visitor(context, index);
            },
            .call => |op| {
                for (op.arguments) |argument|
                    visitor(context, argument);
            },
        }
    }

    pub fn replaceValueUses(self: *Operation, allocator: std.mem.Allocator, old: ValueId, replacement: ValueId) !usize {
        var count: usize = 0;
        switch (self.*) {
            .unary => |*op| replaceOne(&op.operand, old, replacement, &count),
            .binary => |*op| {
                replaceOne(&op.lhs, old, replacement, &count);
                replaceOne(&op.rhs, old, replacement, &count);
            },
            .compare => |*op| {
                replaceOne(&op.lhs, old, replacement, &count);
                replaceOne(&op.rhs, old, replacement, &count);
            },
            .select => |*op| {
                replaceOne(&op.condition, old, replacement, &count);
                replaceOne(&op.true_value, old, replacement, &count);
                replaceOne(&op.false_value, old, replacement, &count);
            },
            .bitcast => |*operand| replaceOne(operand, old, replacement, &count),
            .composite_construct => |*op| op.elements = try replaceSlice(allocator, op.elements, old, replacement, &count),
            .composite_extract => |*op| replaceOne(&op.composite, old, replacement, &count),
            .load_interface => |*op| {
                if (op.element_index) |*index|
                    replaceOne(index, old, replacement, &count);
            },
            .store_interface => |*op| {
                replaceOne(&op.value, old, replacement, &count);
                if (op.element_index) |*index|
                    replaceOne(index, old, replacement, &count);
            },
            .call => |*op| op.arguments = try replaceSlice(allocator, op.arguments, old, replacement, &count),
        }
        return count;
    }

    pub fn hasSideEffects(self: Operation) bool {
        return switch (self) {
            .store_interface, .call => true,
            else => false,
        };
    }
};

pub const Instruction = struct {
    parent_block: BlockId,
    result: ?ValueId,
    operation: Operation,
    source: ?SourceLocation = null,
};

fn replaceOne(operand: *ValueId, old: ValueId, replacement: ValueId, count: *usize) void {
    if (operand.* != old) return;
    operand.* = replacement;
    count.* += 1;
}

fn replaceSlice(
    allocator: std.mem.Allocator,
    operands: []const ValueId,
    old: ValueId,
    replacement: ValueId,
    count: *usize,
) ![]const ValueId {
    var occurrences: usize = 0;
    for (operands) |operand| if (operand == old) {
        occurrences += 1;
    };

    if (occurrences == 0)
        return operands;

    const copy = try allocator.dupe(ValueId, operands);
    for (copy) |*operand| {
        if (operand.* == old)
            operand.* = replacement;
    }

    count.* += occurrences;
    return copy;
}
