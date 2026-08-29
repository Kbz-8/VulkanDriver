const std = @import("std");

const device = @import("../device.zig");
const ids = @import("id.zig");
const instructions = @import("instruction.zig");
const operand = @import("operand.zig");

pub const Properties = packed struct {
    common_ir_lowered: bool = false,
    instructions_selected: bool = false,
    block_parameters_lowered: bool = false,
    parallel_copies_lowered: bool = false,

    compute_abi_lowered: bool = false,
    system_values_lowered: bool = false,
    resources_lowered: bool = false,
    messages_lowered: bool = false,
    message_addresses_lowered: bool = false,
    message_payloads_lowered: bool = false,
    control_flow_lowered: bool = false,

    regions_legalized: bool = false,
    types_legalized: bool = false,

    registers_allocated: bool = false,
    flags_allocated: bool = false,
    branches_resolved: bool = false,

    _padding: u16 = 0,
};

pub const StorageBuffer = struct {
    set: u32,
    binding: u32,
    name: ?[]const u8 = null,
};

pub const PayloadLayout = struct {
    header_grf: ?operand.PhysicalGrf = null,
};

pub const ProgramData = struct {
    payload_grf_count: u16 = 0,
    total_grf_count: u16 = 0,
    scratch_size_bytes: u32 = 0,
};

pub const BlockStore = ids.Store(ids.BlockId, instructions.Block);
pub const InstructionStore = ids.Store(ids.InstructionId, instructions.Instruction);
pub const VirtualRegisterStore = ids.Store(ids.VirtualRegisterId, operand.VirtualRegister);
pub const VirtualFlagStore = ids.Store(ids.VirtualFlagId, operand.VirtualFlag);
pub const StorageBufferStore = ids.Store(ids.StorageBufferId, StorageBuffer);

pub const Program = struct {
    arena: std.heap.ArenaAllocator,

    workgroup_size: [3]u32,
    device_info: device.DeviceInfo,
    dispatch_width: device.DispatchWidth,

    entry_block: ?ids.BlockId = null,

    blocks: BlockStore = .{},
    instructions: InstructionStore = .{},
    virtual_registers: VirtualRegisterStore = .{},
    virtual_flags: VirtualFlagStore = .{},
    storage_buffers: StorageBufferStore = .{},

    payload: PayloadLayout = .{},
    program_data: ProgramData = .{},
    properties: Properties = .{},

    pub fn init(backing_allocator: std.mem.Allocator, workgroup_size: [3]u32, device_info: device.DeviceInfo, dispatch_width: device.DispatchWidth) Program {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .workgroup_size = workgroup_size,
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

    pub fn addStorageBuffer(self: *Program, buffer: StorageBuffer) !ids.StorageBufferId {
        var owned = buffer;
        if (buffer.name) |name|
            owned.name = try self.allocator().dupe(u8, name);
        return self.storage_buffers.add(self.allocator(), owned);
    }

    pub fn addBlock(self: *Program, name: ?[]const u8) !ids.BlockId {
        const owned_name = if (name) |value| try self.allocator().dupe(u8, value) else null;
        const block_id = try self.blocks.add(self.allocator(), .{
            .name = owned_name,
        });
        if (self.entry_block == null)
            self.entry_block = block_id;
        return block_id;
    }

    pub fn setEntryBlock(self: *Program, block_id: ids.BlockId) !void {
        if (!self.blocks.isLive(block_id))
            return error.InvalidBlock;
        self.entry_block = block_id;
    }

    pub fn appendInstruction(self: *Program, block_id: ids.BlockId, execution_size: device.ExecutionSize, predicate: ?operand.Predicate, operation: instructions.Operation) !ids.InstructionId {
        const block = self.blocks.getMut(block_id) orelse return error.InvalidBlock;

        const owned_operation = try instructions.cloneOperation(self.allocator(), operation);
        const instruction_id = try self.instructions.add(self.allocator(), .{
            .parent_block = block_id,
            .execution_size = execution_size,
            .predicate = predicate,
            .operation = owned_operation,
        });
        errdefer std.debug.assert(self.instructions.remove(instruction_id));

        try block.instructions.append(self.allocator(), instruction_id);
        return instruction_id;
    }

    pub fn setTerminator(self: *Program, block_id: ids.BlockId, terminator: instructions.Terminator) !void {
        const block = self.blocks.getMut(block_id) orelse return error.InvalidBlock;
        if (block.terminator != null)
            return error.TerminatorAlreadySet;
        block.terminator = try instructions.cloneTerminator(self.allocator(), terminator);
    }
};
