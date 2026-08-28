const std = @import("std");
const device = @import("../device.zig");
const ids = @import("id.zig");
const operand = @import("operand.zig");
const pseudo = @import("pseudo.zig");

pub const LoadGlobalInvocationId = struct {
    destination: operand.Destination,
    component: u8,
};

pub const BufferReference = union(enum) {
    logical: ids.StorageBufferId,
    binding_table: u8,
};

pub const LoadBuffer = struct {
    destination: operand.Destination,
    buffer: BufferReference,
    byte_offset: operand.Source,
    immediate_offset: u32 = 0,
};

pub const StoreBuffer = struct {
    buffer: BufferReference,
    byte_offset: operand.Source,
    immediate_offset: u32 = 0,
    source: operand.Source,
};

pub const SurfaceRead = struct {
    destination: operand.Destination,
    binding_table: u8,
    address: operand.Source,
    immediate_offset: u32 = 0,
};

pub const SurfaceWrite = struct {
    binding_table: u8,
    address: operand.Source,
    immediate_offset: u32 = 0,
    data: operand.Source,
};

pub const SurfaceMessageKind = enum {
    read,
    write,
};

pub const SurfaceMessage = struct {
    kind: SurfaceMessageKind,
    binding_table: u8,
    payload: operand.RegisterSpan,
    response: ?operand.RegisterSpan,
    data_type: operand.DataType,
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

pub const Operation = union(enum) {
    load_global_invocation_id: LoadGlobalInvocationId,
    load_buffer: LoadBuffer,
    store_buffer: StoreBuffer,
    surface_read: SurfaceRead,
    surface_write: SurfaceWrite,
    surface_message: SurfaceMessage,
    move: Move,
    binary: Binary,
    compare: Compare,
    parallel_copy: pseudo.ParallelCopy,
};

pub fn cloneOperation(allocator: std.mem.Allocator, operation: Operation) std.mem.Allocator.Error!Operation {
    return switch (operation) {
        .parallel_copy => |copy| .{
            .parallel_copy = .{
                .register_copies = try allocator.dupe(pseudo.RegisterCopy, copy.register_copies),
                .flag_copies = try allocator.dupe(pseudo.FlagCopy, copy.flag_copies),
            },
        },
        else => operation,
    };
}

pub const Instruction = struct {
    parent_block: ids.BlockId,
    execution_size: device.ExecutionSize,
    predicate: ?operand.Predicate = null,
    operation: Operation,
};

pub const Edge = struct {
    target: ids.BlockId,
    arguments: []const pseudo.EdgeArgument,
};

pub const Terminator = union(enum) {
    jump: Edge,
    conditional_branch: struct {
        predicate: operand.Predicate,
        true_edge: Edge,
        false_edge: Edge,
    },
    end_thread,
    @"unreachable",
};

pub fn cloneEdge(allocator: std.mem.Allocator, edge: Edge) std.mem.Allocator.Error!Edge {
    return .{
        .target = edge.target,
        .arguments = try allocator.dupe(pseudo.EdgeArgument, edge.arguments),
    };
}

pub fn cloneTerminator(allocator: std.mem.Allocator, terminator: Terminator) std.mem.Allocator.Error!Terminator {
    return switch (terminator) {
        .jump => |edge| .{ .jump = try cloneEdge(allocator, edge) },
        .conditional_branch => |branch| .{
            .conditional_branch = .{
                .predicate = branch.predicate,
                .true_edge = try cloneEdge(allocator, branch.true_edge),
                .false_edge = try cloneEdge(allocator, branch.false_edge),
            },
        },
        else => terminator,
    };
}

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
    parameters: std.ArrayList(pseudo.BlockParameter) = .empty,
    instructions: std.ArrayList(ids.InstructionId) = .empty,
    terminator: ?Terminator = null,
    structured_control: StructuredControl = .none,
    name: ?[]const u8 = null,
};
