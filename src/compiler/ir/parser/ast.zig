const std = @import("std");
const ids = @import("../id.zig");
const inst_ir = @import("../instruction.zig");
const module_ir = @import("../module.zig");

pub const ValueRef = []const u8;

pub const ParsedModule = struct {
    entry_point_name: ?[]const u8,
    interfaces: std.ArrayList(ParsedInterface) = .empty,
    constants: std.ArrayList(ParsedConstant) = .empty,
    functions: std.ArrayList(ParsedFunction) = .empty,
};

pub const ParsedInterface = struct {
    direction: module_ir.InterfaceDirection,
    name: []const u8,
    ty: ids.TypeId,
    semantic: module_ir.InterfaceSemantic,
};

pub const ParsedConstantValue = union(enum) {
    boolean: bool,
    integer_bits: u64,
    float_bits: u64,
    null_value,
    undef,
    composite: []const u32,
};

pub const ParsedConstant = struct {
    printed_value: ValueRef,
    ty: ids.TypeId,
    value: ParsedConstantValue,
};

pub const ParsedParameter = struct {
    printed_value: ValueRef,
    ty: ids.TypeId,
};

pub const ParsedInstruction = struct {
    printed_result: ?ValueRef,
    result_type: ?ids.TypeId,
    operation: ParsedOperation,
};

pub const ParsedBlock = struct {
    name: []const u8,
    parameters: std.ArrayList(ParsedParameter) = .empty,
    instructions: std.ArrayList(ParsedInstruction) = .empty,
    terminator: ?ParsedTerminator = null,
    actual: ?ids.BlockId = null,
};

pub const ParsedFunction = struct {
    name: []const u8,
    return_type: ids.TypeId,
    parameters: std.ArrayList(ParsedParameter) = .empty,
    blocks: std.ArrayList(ParsedBlock) = .empty,
    actual: ?ids.FunctionId = null,
};

pub const ParsedEdge = struct {
    block_name: []const u8,
    arguments: []const ValueRef,
};

pub const ParsedTerminator = union(enum) {
    branch: ParsedEdge,
    conditional_branch: struct {
        condition: ValueRef,
        true_edge: ParsedEdge,
        false_edge: ParsedEdge,
    },
    return_void,
    return_value: ValueRef,
    discard,
    unreachable_value,
};

pub const ParsedOperation = union(enum) {
    unary: struct { opcode: inst_ir.UnaryOpcode, operand: ValueRef },
    binary: struct { opcode: inst_ir.BinaryOpcode, lhs: ValueRef, rhs: ValueRef },
    compare: struct { opcode: inst_ir.CompareOpcode, lhs: ValueRef, rhs: ValueRef },
    select: struct { condition: ValueRef, true_value: ValueRef, false_value: ValueRef },
    bitcast: ValueRef,
    composite_construct: []const ValueRef,
    composite_extract: struct { composite: ValueRef, indices: []const u32 },
    load_interface: []const u8,
    store_interface: struct { interface_name: []const u8, value: ValueRef },
    call: struct { function_name: []const u8, arguments: []const ValueRef },
};
