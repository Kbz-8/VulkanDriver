const std = @import("std");

const Builder = @import("../../../ir/Builder.zig");
const ids = @import("../../../ir/id.zig");
const operand = @import("../../../ir/operand.zig");
const program_ir = @import("../../../ir/program.zig");
const instruction = @import("../../../ir/instruction.zig");

pub const Error = std.mem.Allocator.Error || error{
    MessagesNotLowered,
    InvalidProgram,
};

const AddressAdjustment = struct {
    address: operand.Source,
    immediate_offset: u32,
};

pub fn run(program: *program_ir.Program) Error!void {
    if (!program.properties.messages_lowered)
        return Error.MessagesNotLowered;
    if (program.properties.message_addresses_lowered)
        return;

    var builder = Builder.init(program);
    for (program.blocks.entries.items, 0..) |entry, block_index| {
        _ = entry orelse continue;
        const block_id = ids.BlockId.fromIndex(block_index);
        var instruction_index: usize = 0;

        while (true) {
            const block = program.blocks.get(block_id) orelse return Error.InvalidProgram;
            if (instruction_index >= block.instructions.items.len)
                break;

            const instruction_id = block.instructions.items[instruction_index];
            const inst = program.instructions.get(instruction_id) orelse return Error.InvalidProgram;
            const adjustment = addressAdjustment(inst.operation) orelse {
                instruction_index += 1;
                continue;
            };
            if (adjustment.address.type != .u32)
                return Error.InvalidProgram;

            if (adjustment.immediate_offset == 0) {
                instruction_index += 1;
                continue;
            }

            switch (adjustment.address.register) {
                .immediate => |immediate| {
                    const base = switch (immediate) {
                        .u32 => |value| value,
                        else => return Error.InvalidProgram,
                    };
                    const mutable = program.instructions.getMut(instruction_id) orelse return Error.InvalidProgram;
                    const address = messageAddressMut(&mutable.operation) orelse return Error.InvalidProgram;
                    address.source.register = .{ .immediate = .{ .u32 = base +% adjustment.immediate_offset } };
                    address.immediate_offset.* = 0;
                    instruction_index += 1;
                },
                .virtual,
                .physical_grf,
                .architecture,
                => {
                    const execution_width: u32 = @intFromEnum(inst.execution_size);
                    const size_bytes = execution_width * @sizeOf(u32);
                    const address_register = builder.addVirtualRegister(.{
                        .size_bytes = size_bytes,
                        .alignment_bytes = @intCast(@min(size_bytes, program.device_info.grf_size_bytes)),
                        .element_type = .u32,
                        .lane_count = @intCast(execution_width),
                        .class = .temporary,
                    }) catch |err| return mapBuilderError(err);

                    _ = builder.insertInstruction(block_id, instruction_index, inst.execution_size, inst.predicate, .{
                        .binary = .{
                            .opcode = .add,
                            .destination = .{
                                .register = .{ .virtual = address_register },
                                .type = .u32,
                            },
                            .lhs = adjustment.address,
                            .rhs = immediateSource(adjustment.immediate_offset),
                        },
                    }) catch |err| return mapBuilderError(err);

                    const mutable = program.instructions.getMut(instruction_id) orelse return Error.InvalidProgram;
                    const address = messageAddressMut(&mutable.operation) orelse return Error.InvalidProgram;
                    address.source.* = .{
                        .register = .{ .virtual = address_register },
                        .type = .u32,
                        .region = operand.Region.contiguous(inst.execution_size),
                    };
                    address.immediate_offset.* = 0;
                    instruction_index += 2;
                },
                .null => return Error.InvalidProgram,
            }
        }
    }

    program.properties.message_addresses_lowered = true;
}

fn addressAdjustment(operation: instruction.Operation) ?AddressAdjustment {
    return switch (operation) {
        .surface_read => |op| .{ .address = op.address, .immediate_offset = op.immediate_offset },
        .surface_write => |op| .{ .address = op.address, .immediate_offset = op.immediate_offset },
        else => null,
    };
}

const MutableAddress = struct {
    source: *operand.Source,
    immediate_offset: *u32,
};

fn messageAddressMut(operation: *instruction.Operation) ?MutableAddress {
    return switch (operation.*) {
        .surface_read => |*op| .{ .source = &op.address, .immediate_offset = &op.immediate_offset },
        .surface_write => |*op| .{ .source = &op.address, .immediate_offset = &op.immediate_offset },
        else => null,
    };
}

fn immediateSource(value: u32) operand.Source {
    return .{
        .register = .{ .immediate = .{ .u32 = value } },
        .type = .u32,
        .region = operand.Region.broadcast(),
    };
}

fn mapBuilderError(err: Builder.Error) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.InvalidProgram,
    };
}

const device = @import("../../../device.zig");

const test_device: device.DeviceInfo = .{
    .generation = .gen9,
    .platform = .skylake,
    .pci_device_id = 0x1912,
    .grf_count = 128,
};

fn markPrerequisite(program: *program_ir.Program) void {
    program.properties.messages_lowered = true;
}

test "[gen9] message addresses: fold immediate offsets" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();

    const entry = try program.addBlock("entry");
    const message = try program.appendInstruction(entry, .simd8, null, .{ .surface_write = .{
        .binding_table = 0,
        .address = immediateSource(12),
        .immediate_offset = 4,
        .data = immediateSource(7),
    } });
    try program.setTerminator(entry, .end_thread);
    markPrerequisite(&program);

    try run(&program);

    const write = program.instructions.get(message).?.operation.surface_write;
    try std.testing.expectEqual(@as(u32, 16), write.address.register.immediate.u32);
    try std.testing.expectEqual(@as(u32, 0), write.immediate_offset);
    try std.testing.expect(program.properties.message_addresses_lowered);
}

test "[gen9] message addresses: materialize dynamic offsets" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();

    const base = try program.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
    });
    const entry = try program.addBlock("entry");
    const message = try program.appendInstruction(entry, .simd8, null, .{ .surface_read = .{
        .destination = .{ .register = .{ .virtual = base }, .type = .u32 },
        .binding_table = 0,
        .address = .{
            .register = .{ .virtual = base },
            .type = .u32,
            .region = operand.Region.contiguous(.simd8),
        },
        .immediate_offset = 8,
    } });
    try program.setTerminator(entry, .end_thread);
    markPrerequisite(&program);

    try run(&program);

    const block = program.blocks.get(entry).?;
    try std.testing.expectEqual(@as(usize, 2), block.instructions.items.len);
    try std.testing.expect(program.instructions.get(block.instructions.items[0]).?.operation == .binary);
    const read = program.instructions.get(message).?.operation.surface_read;
    try std.testing.expect(read.address.register == .virtual);
    try std.testing.expect(read.address.register.virtual != base);
    try std.testing.expectEqual(@as(u32, 0), read.immediate_offset);
}
