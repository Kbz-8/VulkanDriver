const std = @import("std");
const shared_ir = @import("shader_ir").ir.module;
const device = @import("device.zig");
const ids = @import("id.zig");
const instructions = @import("instruction.zig");
const operand = @import("operand.zig");

pub const Stage = shared_ir.Stage;

pub const Properties = packed struct {
    instructions_selected: bool = false,
    block_parameters_lowered: bool = false,
    calls_lowered: bool = false,

    stage_io_lowered: bool = false,
    resources_lowered: bool = false,
    messages_lowered: bool = false,
    control_flow_lowered: bool = false,

    regions_legalized: bool = false,
    types_legalized: bool = false,

    registers_allocated: bool = false,
    flags_allocated: bool = false,
    branches_resolved: bool = false,

    _padding: u20 = 0,
};

pub const VertexPayload = struct {
    first_attribute_grf: operand.PhysicalGrf,
    attribute_grf_count: u16,
};

pub const PayloadLayout = struct {
    header_grf: ?operand.PhysicalGrf = null,
    vertex: ?VertexPayload = null,
};

pub const ProgramData = struct {
    payload_grf_count: u16 = 0,
    total_grf_count: u16 = 0,
    scratch_size_bytes: u32 = 0,
};

pub const Function = struct {
    return_type: ?operand.DataType,
    parameters: std.ArrayList(ids.VirtualRegisterId) = .empty,
    blocks: std.ArrayList(ids.BlockId) = .empty,
    entry_block: ?ids.BlockId = null,
    name: ?[]const u8 = null,
};

pub const FunctionStore = ids.Store(ids.FunctionId, Function);
pub const BlockStore = ids.Store(ids.BlockId, instructions.Block);
pub const InstructionStore = ids.Store(ids.InstructionId, instructions.Instruction);
pub const VirtualRegisterStore = ids.Store(ids.VirtualRegisterId, operand.VirtualRegister);
pub const VirtualFlagStore = ids.Store(ids.VirtualFlagId, operand.VirtualFlag);

pub const Program = struct {
    arena: std.heap.ArenaAllocator,

    stage: Stage,
    device_info: device.DeviceInfo,
    dispatch_width: device.DispatchWidth,

    entry_function: ?ids.FunctionId = null,

    functions: FunctionStore = .{},
    blocks: BlockStore = .{},
    instructions: InstructionStore = .{},
    virtual_registers: VirtualRegisterStore = .{},
    virtual_flags: VirtualFlagStore = .{},

    payload: PayloadLayout = .{},
    program_data: ProgramData = .{},
    properties: Properties = .{},

    pub fn init(
        backing_allocator: std.mem.Allocator,
        stage: Stage,
        device_info: device.DeviceInfo,
        dispatch_width: device.DispatchWidth,
    ) Program {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .stage = stage,
            .device_info = device_info,
            .dispatch_width = dispatch_width,
        };
    }

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *Program) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn addFunction(self: *Program, return_type: ?operand.DataType, name: ?[]const u8) !ids.FunctionId {
        const owned_name = if (name) |value| try self.allocator().dupe(u8, value) else null;
        return self.functions.add(self.allocator(), .{
            .return_type = return_type,
            .name = owned_name,
        });
    }

    pub fn setEntryFunction(self: *Program, function_id: ids.FunctionId) !void {
        if (!self.functions.isLive(function_id))
            return error.InvalidFunction;
        self.entry_function = function_id;
    }

    pub fn addFunctionParameter(self: *Program, function_id: ids.FunctionId, register_id: ids.VirtualRegisterId) !void {
        const function = self.functions.getMut(function_id) orelse return error.InvalidFunction;
        if (!self.virtual_registers.isLive(register_id))
            return error.InvalidVirtualRegister;
        try function.parameters.append(self.allocator(), register_id);
    }

    pub fn addVirtualRegister(self: *Program, register: operand.VirtualRegister) !ids.VirtualRegisterId {
        var owned = register;
        if (register.name) |name|
            owned.name = try self.allocator().dupe(u8, name);
        return self.virtual_registers.add(self.allocator(), owned);
    }

    pub fn addVirtualFlag(self: *Program, flag: operand.VirtualFlag) !ids.VirtualFlagId {
        var owned = flag;
        if (flag.name) |name|
            owned.name = try self.allocator().dupe(u8, name);
        return self.virtual_flags.add(self.allocator(), owned);
    }

    pub fn addBlock(self: *Program, function_id: ids.FunctionId, name: ?[]const u8) !ids.BlockId {
        const function = self.functions.getMut(function_id) orelse return error.InvalidFunction;
        const owned_name = if (name) |value| try self.allocator().dupe(u8, value) else null;
        const block_id = try self.blocks.add(self.allocator(), .{
            .parent_function = function_id,
            .name = owned_name,
        });
        errdefer _ = self.blocks.remove(block_id);

        try function.blocks.append(self.allocator(), block_id);
        if (function.entry_block == null)
            function.entry_block = block_id;
        return block_id;
    }

    pub fn appendInstruction(
        self: *Program,
        block_id: ids.BlockId,
        execution_size: device.ExecutionSize,
        predicate: ?operand.Predicate,
        operation: instructions.Operation,
    ) !ids.InstructionId {
        const block = self.blocks.getMut(block_id) orelse return error.InvalidBlock;
        var owned_operation = operation;
        switch (owned_operation) {
            .call => |*call| call.arguments = try self.allocator().dupe(operand.Source, call.arguments),
            else => {},
        }

        const instruction_id = try self.instructions.add(self.allocator(), .{
            .parent_block = block_id,
            .execution_size = execution_size,
            .predicate = predicate,
            .operation = owned_operation,
        });
        try block.instructions.append(self.allocator(), instruction_id);
        return instruction_id;
    }

    pub fn setTerminator(self: *Program, block_id: ids.BlockId, terminator: instructions.Terminator) !void {
        const block = self.blocks.getMut(block_id) orelse return error.InvalidBlock;
        if (block.terminator != null)
            return error.TerminatorAlreadySet;
        block.terminator = terminator;
    }
};
