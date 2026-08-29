const std = @import("std");

const Builder = @import("../../../ir/Builder.zig");
const device = @import("../../../device.zig");
const ids = @import("../../../ir/id.zig");
const instruction = @import("../../../ir/instruction.zig");
const operand = @import("../../../ir/operand.zig");
const program_ir = @import("../../../ir/program.zig");

pub const Error = std.mem.Allocator.Error || error{
    MessageAddressesNotLowered,
    InvalidProgram,
};

pub fn run(program: *program_ir.Program) Error!void {
    if (!program.properties.message_addresses_lowered)
        return Error.MessageAddressesNotLowered;
    if (program.properties.message_payloads_lowered)
        return;
    if (program.device_info.grf_size_bytes != 32)
        return Error.InvalidProgram;

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
            const execution_size = inst.execution_size;
            switch (inst.operation) {
                .surface_read => |op| {
                    if (op.immediate_offset != 0 or op.address.type != .u32)
                        return Error.InvalidProgram;
                    const response = try responseSpan(op.destination);
                    const payload = try addPayloadRegister(&builder, execution_size, 1);
                    _ = builder.insertInstruction(block_id, instruction_index, execution_size, null, .{ .move = .{
                        .destination = payloadDestination(payload, 0, .u32),
                        .source = op.address,
                    } }) catch |err| return mapBuilderError(err);

                    const mutable = program.instructions.getMut(instruction_id) orelse return Error.InvalidProgram;
                    mutable.operation = .{ .surface_message = .{
                        .kind = .read,
                        .binding_table = op.binding_table,
                        .payload = .{ .base = .{ .virtual = payload }, .register_count = 1 },
                        .response = response,
                        .data_type = op.destination.type,
                    } };
                    instruction_index += 2;
                },
                .surface_write => |op| {
                    if (op.immediate_offset != 0 or op.address.type != .u32)
                        return Error.InvalidProgram;
                    const payload = try addPayloadRegister(&builder, execution_size, 2);
                    _ = builder.insertInstruction(block_id, instruction_index, execution_size, null, .{ .move = .{
                        .destination = payloadDestination(payload, 0, .u32),
                        .source = op.address,
                    } }) catch |err| return mapBuilderError(err);
                    _ = builder.insertInstruction(block_id, instruction_index + 1, execution_size, null, .{ .move = .{
                        .destination = payloadDestination(payload, 32, op.data.type),
                        .source = op.data,
                    } }) catch |err| return mapBuilderError(err);

                    const mutable = program.instructions.getMut(instruction_id) orelse return Error.InvalidProgram;
                    mutable.operation = .{ .surface_message = .{
                        .kind = .write,
                        .binding_table = op.binding_table,
                        .payload = .{ .base = .{ .virtual = payload }, .register_count = 2 },
                        .response = null,
                        .data_type = op.data.type,
                    } };
                    instruction_index += 3;
                },
                else => instruction_index += 1,
            }
        }
    }

    program.properties.message_payloads_lowered = true;
}

fn addPayloadRegister(builder: *Builder, execution_size: device.ExecutionSize, register_count: u8) Error!ids.VirtualRegisterId {
    return builder.addVirtualRegister(.{
        .size_bytes = @as(u32, register_count) * 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = @intFromEnum(execution_size),
        .class = .temporary,
        .spillable = false,
    }) catch |err| return mapBuilderError(err);
}

fn payloadDestination(register: ids.VirtualRegisterId, byte_offset: u16, data_type: operand.DataType) operand.Destination {
    return .{
        .register = .{ .virtual = register },
        .type = data_type,
        .region = .{ .byte_offset = byte_offset },
    };
}

fn responseSpan(destination: operand.Destination) Error!operand.RegisterSpan {
    if (destination.region.byte_offset != 0 or destination.region.horizontal_stride != 1)
        return Error.InvalidProgram;
    return switch (destination.register) {
        .virtual, .physical_grf => .{
            .base = destination.register,
            .register_count = 1,
        },
        else => Error.InvalidProgram,
    };
}

fn mapBuilderError(err: Builder.Error) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.InvalidProgram,
    };
}

const test_device: device.DeviceInfo = .{
    .generation = .gen9,
    .platform = .skylake,
    .pci_device_id = 0x1912,
    .grf_count = 128,
};

fn immediate(value: u32) operand.Source {
    return .{
        .register = .{ .immediate = .{ .u32 = value } },
        .type = .u32,
        .region = operand.Region.broadcast(),
    };
}

test "[gen9] message payloads: pack surface write address and data" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();

    const entry = try program.addBlock("entry");
    const message = try program.appendInstruction(entry, .simd8, null, .{ .surface_write = .{
        .binding_table = 2,
        .address = immediate(16),
        .data = immediate(42),
    } });
    try program.setTerminator(entry, .end_thread);
    program.properties.message_addresses_lowered = true;

    try run(&program);

    const block = program.blocks.get(entry).?;
    try std.testing.expectEqual(@as(usize, 3), block.instructions.items.len);
    const address_move = program.instructions.get(block.instructions.items[0]).?.operation.move;
    const data_move = program.instructions.get(block.instructions.items[1]).?.operation.move;
    try std.testing.expectEqual(@as(u16, 0), address_move.destination.region.byte_offset);
    try std.testing.expectEqual(@as(u16, 32), data_move.destination.region.byte_offset);
    try std.testing.expectEqual(address_move.destination.register.virtual, data_move.destination.register.virtual);

    const send = program.instructions.get(message).?.operation.surface_message;
    try std.testing.expectEqual(instruction.SurfaceMessageKind.write, send.kind);
    try std.testing.expectEqual(@as(u8, 2), send.binding_table);
    try std.testing.expectEqual(@as(u8, 2), send.payload.register_count);
    try std.testing.expect(send.response == null);
    try std.testing.expect(program.properties.message_payloads_lowered);
}

test "[gen9] message payloads: prepare surface read response" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();

    const result = try program.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .response,
    });
    const entry = try program.addBlock("entry");
    const message = try program.appendInstruction(entry, .simd8, null, .{ .surface_read = .{
        .destination = .{ .register = .{ .virtual = result }, .type = .u32 },
        .binding_table = 1,
        .address = immediate(0),
    } });
    try program.setTerminator(entry, .end_thread);
    program.properties.message_addresses_lowered = true;

    try run(&program);

    const send = program.instructions.get(message).?.operation.surface_message;
    try std.testing.expectEqual(instruction.SurfaceMessageKind.read, send.kind);
    try std.testing.expectEqual(@as(u8, 1), send.payload.register_count);
    try std.testing.expectEqual(result, send.response.?.base.virtual);
    try std.testing.expectEqual(@as(u8, 1), send.response.?.register_count);
}
