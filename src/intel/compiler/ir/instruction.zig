const std = @import("std");
const device = @import("../device.zig");
const ids = @import("id.zig");
const operand = @import("operand.zig");

pub const Builtin = enum {
    position,
    vertex_index,
    instance_index,
};

pub const InterfaceSemantic = union(enum) {
    location: struct {
        location: u32,
        component: u8 = 0,
    },
    builtin: struct {
        builtin: Builtin,
        component: u8 = 0,
    },
};

pub const LoadInput = struct {
    destination: operand.Destination,
    semantic: InterfaceSemantic,
};

pub const StoreOutput = struct {
    semantic: InterfaceSemantic,
    source: operand.Source,
};

pub const Move = struct {
    destination: operand.Destination,
    source: operand.Source,
};

pub const BinaryOpcode = enum {
    add,
    multiply,
    bitwise_and,
    bitwise_or,
    bitwise_xor,
    shift_left,
    shift_right,
};

pub const Binary = struct {
    opcode: BinaryOpcode,
    destination: operand.Destination,
    lhs: operand.Source,
    rhs: operand.Source,
};

pub const CompareOpcode = enum {
    equal,
    not_equal,
    less_than,
    less_or_equal,
    greater_than,
    greater_or_equal,
};

pub const Compare = struct {
    opcode: CompareOpcode,
    destination: operand.FlagRef,
    lhs: operand.Source,
    rhs: operand.Source,
};

pub const ChannelMask = packed struct(u4) {
    x: bool = true,
    y: bool = true,
    z: bool = true,
    w: bool = true,
};

pub const UrbWrite = struct {
    offset: u16,
    channels: ChannelMask = .{},
    end_of_thread: bool = false,
};

pub const Message = union(enum) {
    urb_write: UrbWrite,
};

pub const Send = struct {
    message: Message,
    payload: operand.RegisterSpan,
    response: ?operand.RegisterSpan = null,
};

pub const Operation = union(enum) {
    load_input: LoadInput,
    store_output: StoreOutput,
    move: Move,
    binary: Binary,
    compare: Compare,
    send: Send,
};

pub const Instruction = struct {
    parent_block: ids.BlockId,
    execution_size: device.ExecutionSize,
    predicate: ?operand.Predicate = null,
    operation: Operation,
};

pub const Terminator = union(enum) {
    jump: ids.BlockId,
    conditional_branch: struct {
        predicate: operand.Predicate,
        true_block: ids.BlockId,
        false_block: ids.BlockId,
    },
    end_thread,
    @"unreachable",
};

pub const StructuredControl = union(enum) {
    none,
    selection: struct {
        merge_block: ids.BlockId,
    },
    loop: struct {
        merge_block: ids.BlockId,
        continue_block: ids.BlockId,
    },
};

pub const Block = struct {
    instructions: std.ArrayList(ids.InstructionId) = .empty,
    terminator: ?Terminator = null,
    structured_control: StructuredControl = .none,
    name: ?[]const u8 = null,
};
