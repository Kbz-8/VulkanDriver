const instruction = @import("../../../ir/instruction.zig");
const operand = @import("../../../ir/operand.zig");
const program_ir = @import("../../../ir/program.zig");

pub const Error = error{
    ResourcesNotLowered,
    InvalidProgram,
};

pub fn run(program: *program_ir.Program) Error!void {
    if (!program.properties.resources_lowered)
        return Error.ResourcesNotLowered;
    if (program.properties.messages_lowered)
        return;

    for (program.instructions.entries.items) |*entry| {
        const inst = if (entry.*) |*value| value else continue;
        inst.operation = switch (inst.operation) {
            .load_buffer => |op| .{ .surface_read = .{
                .destination = op.destination,
                .binding_table = bindingTableIndex(op.buffer) orelse return Error.InvalidProgram,
                .address = op.byte_offset,
                .immediate_offset = op.immediate_offset,
            } },
            .store_buffer => |op| .{ .surface_write = .{
                .binding_table = bindingTableIndex(op.buffer) orelse return Error.InvalidProgram,
                .address = op.byte_offset,
                .immediate_offset = op.immediate_offset,
                .data = op.source,
            } },
            else => inst.operation,
        };
    }

    program.properties.messages_lowered = true;
}

fn bindingTableIndex(reference: instruction.BufferReference) ?u8 {
    return switch (reference) {
        .binding_table => |index| index,
        .logical => null,
    };
}

const std = @import("std");
const device = @import("../../../device.zig");

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

test "[gen9] compute message lowering: select surface messages" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();

    const value = try program.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
    });
    const entry = try program.addBlock("entry");
    const load = try program.appendInstruction(entry, .simd8, null, .{ .load_buffer = .{
        .destination = .{ .register = .{ .virtual = value }, .type = .u32 },
        .buffer = .{ .binding_table = 2 },
        .byte_offset = immediate(16),
        .immediate_offset = 4,
    } });
    const store = try program.appendInstruction(entry, .simd8, null, .{ .store_buffer = .{
        .buffer = .{ .binding_table = 3 },
        .byte_offset = immediate(32),
        .immediate_offset = 8,
        .source = .{
            .register = .{ .virtual = value },
            .type = .u32,
            .region = operand.Region.contiguous(.simd8),
        },
    } });
    try program.setTerminator(entry, .end_thread);
    program.properties.resources_lowered = true;

    try run(&program);

    const read = program.instructions.get(load).?.operation.surface_read;
    try std.testing.expectEqual(@as(u8, 2), read.binding_table);
    try std.testing.expectEqual(@as(u32, 4), read.immediate_offset);
    const write = program.instructions.get(store).?.operation.surface_write;
    try std.testing.expectEqual(@as(u8, 3), write.binding_table);
    try std.testing.expectEqual(@as(u32, 8), write.immediate_offset);
    try std.testing.expect(program.properties.messages_lowered);
}

test "[gen9] compute message lowering: reject unresolved resources" {
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, test_device, .simd8);
    defer program.deinit();

    try std.testing.expectError(Error.ResourcesNotLowered, run(&program));
}
