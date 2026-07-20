const std = @import("std");
const ids = @import("id.zig");
const types = @import("type.zig");
const constants = @import("constant.zig");
const values = @import("value.zig");
const instructions = @import("instruction.zig");

pub const Stage = enum {
    vertex,
    fragment,
    compute,
};

pub const ExecutionModes = struct {
    workgroup_size: ?[3]u32 = null,
    early_fragment_tests: bool = false,
};

pub const Properties = packed struct {
    valid_cfg: bool = false,
    valid_ssa: bool = false,
    structured_control_flow: bool = false,
    no_function_calls: bool = false,
    no_local_memory: bool = false,
    no_matrix_types: bool = false,
    no_large_composites: bool = false,
    explicit_resource_offsets: bool = false,
    _padding: u24 = 0,
};

pub const ConstantStore = ids.Store(ids.ConstantId, constants.Constant);
pub const ValueStore = ids.Store(ids.ValueId, values.Value);
pub const InstructionStore = ids.Store(ids.InstructionId, instructions.Instruction);
pub const BlockStore = ids.Store(ids.BlockId, Block);
pub const FunctionStore = ids.Store(ids.FunctionId, Function);
pub const InterfaceVariableStore = ids.Store(ids.InterfaceVariableId, InterfaceVariable);
pub const ResourceStore = ids.Store(ids.ResourceId, Resource);
pub const TypeStore = ids.Store(ids.TypeId, types.Type);

pub const Edge = struct {
    target: ids.BlockId,
    arguments: []const ids.ValueId,
};

pub const Terminator = union(enum) {
    branch: Edge,
    conditional_branch: struct {
        condition: ids.ValueId,
        true_edge: Edge,
        false_edge: Edge,
    },
    return_void,
    return_value: ids.ValueId,
    discard,
    @"unreachable",
};

pub const StructuredControl = union(enum) {
    none,
    selection: struct { merge_block: ids.BlockId },
    loop: struct {
        merge_block: ids.BlockId,
        continue_block: ids.BlockId,
    },
};

pub const Block = struct {
    parent_function: ids.FunctionId,
    parameters: std.ArrayList(ids.ValueId) = .empty,
    instructions: std.ArrayList(ids.InstructionId) = .empty,
    terminator: ?Terminator = null,
    structured_control: StructuredControl = .none,
    name: ?[]const u8 = null,
};

pub const Function = struct {
    return_type: ids.TypeId,
    parameter_types: std.ArrayList(ids.TypeId) = .empty,
    parameters: std.ArrayList(ids.ValueId) = .empty,
    blocks: std.ArrayList(ids.BlockId) = .empty,
    entry_block: ?ids.BlockId = null,
    name: ?[]const u8 = null,
};

pub const InterfaceDirection = enum {
    input,
    output,
};

pub const Builtin = enum {
    position,
    vertex_index,
    instance_index,
    frag_coord,
    frag_depth,
    global_invocation_id,
};

pub const InterfaceSemantic = union(enum) {
    location: struct { location: u32, component: u8 = 0, index: u8 = 0 },
    builtin: Builtin,
};

pub const InterfaceVariable = struct {
    type: ids.TypeId,
    direction: InterfaceDirection,
    semantic: InterfaceSemantic,
    name: ?[]const u8 = null,
};

pub const Resource = struct {
    kind: types.ResourceKind,
    set: u32,
    binding: u32,
    type: ids.TypeId,
    name: ?[]const u8 = null,
};

pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    stage: Stage,
    entry_point: ?ids.FunctionId = null,
    execution_modes: ExecutionModes = .{},
    types: TypeStore = .{},
    constants: ConstantStore = .{},
    values: ValueStore = .{},
    instructions: InstructionStore = .{},
    blocks: BlockStore = .{},
    functions: FunctionStore = .{},
    interface_variables: InterfaceVariableStore = .{},
    resources: ResourceStore = .{},
    properties: Properties = .{},

    pub fn init(backing_allocator: std.mem.Allocator, stage: Stage) Module {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .stage = stage,
        };
    }

    pub fn deinit(self: *Module) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *Module) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn backingAllocator(self: *const Module) std.mem.Allocator {
        return self.arena.child_allocator;
    }

    pub fn internType(self: *Module, candidate: types.Type) !ids.TypeId {
        for (self.types.entries.items, 0..) |entry, index| {
            if (entry) |existing| {
                if (existing.eql(candidate))
                    return ids.TypeId.fromIndex(index);
            }
        }

        var owned = candidate;
        if (candidate == .structure) {
            owned.structure.members = try self.allocator().dupe(ids.TypeId, candidate.structure.members);
        }

        return self.types.add(self.allocator(), owned);
    }

    pub fn typeOf(self: *const Module, value_id: ids.ValueId) ?ids.TypeId {
        const value = self.values.get(value_id) orelse return null;
        return value.type;
    }
};

pub fn visitTerminatorValueUses(terminator: Terminator, context: anytype, comptime visitor: anytype) void {
    switch (terminator) {
        .branch => |edge| {
            for (edge.arguments) |argument|
                visitor(context, argument);
        },
        .conditional_branch => |branch| {
            visitor(context, branch.condition);

            for (branch.true_edge.arguments) |argument|
                visitor(context, argument);

            for (branch.false_edge.arguments) |argument|
                visitor(context, argument);
        },
        .return_value => |value| visitor(context, value),
        else => {},
    }
}

pub fn replaceTerminatorValueUses(allocator: std.mem.Allocator, terminator: *Terminator, old: ids.ValueId, replacement: ids.ValueId) !usize {
    var count: usize = 0;
    switch (terminator.*) {
        .branch => |*edge| try replaceEdgeUses(allocator, edge, old, replacement, &count),
        .conditional_branch => |*branch| {
            replaceOne(&branch.condition, old, replacement, &count);
            try replaceEdgeUses(allocator, &branch.true_edge, old, replacement, &count);
            try replaceEdgeUses(allocator, &branch.false_edge, old, replacement, &count);
        },
        .return_value => |*value| replaceOne(value, old, replacement, &count),
        else => {},
    }
    return count;
}

fn replaceEdgeUses(allocator: std.mem.Allocator, edge: *Edge, old: ids.ValueId, replacement: ids.ValueId, count: *usize) !void {
    var occurrences: usize = 0;
    for (edge.arguments) |argument| if (argument == old) {
        occurrences += 1;
    };

    if (occurrences == 0)
        return;

    const copy = try allocator.dupe(ids.ValueId, edge.arguments);
    for (copy) |*argument| {
        if (argument.* == old)
            argument.* = replacement;
    }

    edge.arguments = copy;
    count.* += occurrences;
}

fn replaceOne(operand: *ids.ValueId, old: ids.ValueId, replacement: ids.ValueId, count: *usize) void {
    if (operand.* != old)
        return;
    operand.* = replacement;
    count.* += 1;
}
