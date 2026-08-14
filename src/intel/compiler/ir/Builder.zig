const std = @import("std");
const device = @import("../device.zig");
const ids = @import("id.zig");
const instruction = @import("instruction.zig");
const operand = @import("operand.zig");
const program_ir = @import("program.zig");
const pseudo = @import("pseudo.zig");

const Self = @This();

pub const Error = std.mem.Allocator.Error || error{
    InvalidBlock,
    InvalidInstruction,
    InvalidInsertionIndex,
    TerminatorAlreadySet,
};

program: *program_ir.Program,

pub fn init(program: *program_ir.Program) Self {
    return .{ .program = program };
}

pub fn addVirtualRegister(self: *Self, register: operand.VirtualRegister) Error!ids.VirtualRegisterId {
    return self.program.addVirtualRegister(register);
}

pub fn addVirtualFlag(self: *Self, flag: operand.VirtualFlag) Error!ids.VirtualFlagId {
    return self.program.addVirtualFlag(flag);
}

pub fn addStorageBuffer(self: *Self, buffer: program_ir.StorageBuffer) Error!ids.StorageBufferId {
    return self.program.addStorageBuffer(buffer);
}

pub fn addBlock(self: *Self, name: ?[]const u8) Error!ids.BlockId {
    return self.program.addBlock(name);
}

pub fn setEntryBlock(self: *Self, block_id: ids.BlockId) Error!void {
    return self.program.setEntryBlock(block_id);
}

pub fn addBlockParameter(self: *Self, block_id: ids.BlockId, parameter: pseudo.BlockParameter) Error!void {
    const block = self.program.blocks.getMut(block_id) orelse return Error.InvalidBlock;
    try block.parameters.append(self.program.allocator(), parameter);
}

pub fn clearBlockParameters(self: *Self, block_id: ids.BlockId) Error!void {
    const block = self.program.blocks.getMut(block_id) orelse return Error.InvalidBlock;
    block.parameters.clearRetainingCapacity();
}

pub fn edge(self: *Self, target: ids.BlockId, arguments: []const pseudo.EdgeArgument) Error!instruction.Edge {
    if (!self.program.blocks.isLive(target))
        return Error.InvalidBlock;
    return .{
        .target = target,
        .arguments = try self.program.allocator().dupe(pseudo.EdgeArgument, arguments),
    };
}

pub fn appendInstruction(self: *Self, block_id: ids.BlockId, execution_size: device.ExecutionSize, predicate: ?operand.Predicate, operation: instruction.Operation) Error!ids.InstructionId {
    const block = self.program.blocks.get(block_id) orelse return Error.InvalidBlock;
    return self.insertInstruction(block_id, block.instructions.items.len, execution_size, predicate, operation);
}

pub fn insertInstruction(
    self: *Self,
    block_id: ids.BlockId,
    index: usize,
    execution_size: device.ExecutionSize,
    predicate: ?operand.Predicate,
    operation: instruction.Operation,
) Error!ids.InstructionId {
    const block = self.program.blocks.getMut(block_id) orelse return Error.InvalidBlock;
    if (index > block.instructions.items.len)
        return Error.InvalidInsertionIndex;

    const owned_operation = try instruction.cloneOperation(self.program.allocator(), operation);
    const instruction_id = try self.program.instructions.add(self.program.allocator(), .{
        .parent_block = block_id,
        .execution_size = execution_size,
        .predicate = predicate,
        .operation = owned_operation,
    });
    errdefer std.debug.assert(self.program.instructions.remove(instruction_id));

    try block.instructions.insert(self.program.allocator(), index, instruction_id);
    return instruction_id;
}

pub fn replaceOperation(self: *Self, instruction_id: ids.InstructionId, operation: instruction.Operation) Error!void {
    const inst = self.program.instructions.getMut(instruction_id) orelse return Error.InvalidInstruction;
    const owned_operation = try instruction.cloneOperation(self.program.allocator(), operation);
    inst.operation = owned_operation;
}

pub fn setStructuredControl(self: *Self, block_id: ids.BlockId, control: instruction.StructuredControl) Error!void {
    const block = self.program.blocks.getMut(block_id) orelse return Error.InvalidBlock;
    block.structured_control = control;
}

pub fn setTerminator(self: *Self, block_id: ids.BlockId, terminator: instruction.Terminator) Error!void {
    return self.program.setTerminator(block_id, terminator);
}

pub fn replaceTerminator(self: *Self, block_id: ids.BlockId, terminator: instruction.Terminator) Error!void {
    const block = self.program.blocks.getMut(block_id) orelse return Error.InvalidBlock;
    block.terminator = try instruction.cloneTerminator(self.program.allocator(), terminator);
}

fn moveImmediate(register_id: ids.VirtualRegisterId, value: u32) instruction.Operation {
    return .{
        .move = .{
            .destination = .{
                .register = .{ .virtual = register_id },
                .type = .u32,
            },
            .source = .{
                .register = .{ .immediate = .{ .u32 = value } },
                .type = .u32,
                .region = operand.Region.broadcast(),
            },
        },
    };
}

test "[ir] Builder: construction and ordered insertion" {
    const validator = @import("validator.zig");

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };

    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, device_info, .simd8);
    defer program.deinit();
    var builder = Self.init(&program);

    var register_name = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    const register_id = try builder.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
        .name = &register_name,
    });
    register_name[0] = 'x';
    try std.testing.expectEqualStrings("value", program.virtual_registers.get(register_id).?.name.?);

    const flag_id = try builder.addVirtualFlag(.{ .name = "condition" });
    try std.testing.expectEqualStrings("condition", program.virtual_flags.get(flag_id).?.name.?);

    const entry = try builder.addBlock("entry");
    const exit = try builder.addBlock("exit");
    try builder.setEntryBlock(entry);

    const second = try builder.appendInstruction(entry, .simd8, null, moveImmediate(register_id, 2));
    const first = try builder.insertInstruction(entry, 0, .simd8, null, moveImmediate(register_id, 1));

    const entry_block = program.blocks.get(entry).?;
    try std.testing.expectEqualSlices(ids.InstructionId, &.{ first, second }, entry_block.instructions.items);
    try std.testing.expectEqual(entry, program.instructions.get(first).?.parent_block);
    try std.testing.expectEqual(entry, program.instructions.get(second).?.parent_block);

    try builder.replaceOperation(first, moveImmediate(register_id, 3));
    const replaced = program.instructions.get(first).?;
    try std.testing.expectEqual(entry, replaced.parent_block);
    try std.testing.expectEqual(device.ExecutionSize.simd8, replaced.execution_size);
    try std.testing.expectEqual(@as(u32, 3), replaced.operation.move.source.register.immediate.u32);
    try std.testing.expectError(Error.InvalidInstruction, builder.replaceOperation(ids.InstructionId.fromIndex(999), moveImmediate(register_id, 4)));

    try builder.setStructuredControl(entry, .{ .selection = .{ .merge_block = exit } });
    try builder.setTerminator(entry, .{ .jump = try builder.edge(exit, &.{}) });
    try builder.setTerminator(exit, .end_thread);
    try std.testing.expectError(Error.TerminatorAlreadySet, builder.setTerminator(entry, .end_thread));

    const instruction_count = program.instructions.entries.items.len;
    try std.testing.expectError(
        Error.InvalidInsertionIndex,
        builder.insertInstruction(entry, 3, .simd8, null, moveImmediate(register_id, 3)),
    );
    try std.testing.expectEqual(instruction_count, program.instructions.entries.items.len);

    try validator.validate(&program);
}
