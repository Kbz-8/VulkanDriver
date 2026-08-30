const instruction = @import("../../../ir/instruction.zig");
const program_ir = @import("../../../ir/program.zig");
const validator = @import("../../../ir/validator.zig");
const resource_layout = @import("resource_layout.zig");

pub const Error = error{
    InvalidProgram,
    InvalidResourceLayout,
};

pub fn run(program: *program_ir.Program, layout: *const resource_layout.Layout) Error!void {
    validator.validate(program) catch return Error.InvalidProgram;
    if (program.properties.resources_lowered)
        return;
    if (layout.resource_indices.len != program.storage_buffers.entries.items.len)
        return Error.InvalidResourceLayout;

    for (program.blocks.entries.items) |block_entry| {
        const block = block_entry orelse continue;
        for (block.instructions.items) |instruction_id| {
            const inst = program.instructions.get(instruction_id) orelse return Error.InvalidProgram;
            const reference = bufferReference(inst.operation) orelse continue;
            const resource = switch (reference) {
                .logical => |value| value,
                .binding_table => return Error.InvalidProgram,
            };
            const binding_table_index = layout.bindingTableIndex(resource) orelse return Error.InvalidResourceLayout;
            if (binding_table_index >= layout.bindings.len)
                return Error.InvalidResourceLayout;
            const buffer = program.storage_buffers.get(resource) orelse return Error.InvalidProgram;
            const binding = layout.bindings[binding_table_index];
            if (binding.binding_table_index != binding_table_index or binding.set != buffer.set or binding.binding != buffer.binding)
                return Error.InvalidResourceLayout;
        }
    }

    for (program.blocks.entries.items) |block_entry| {
        const block = block_entry orelse continue;
        for (block.instructions.items) |instruction_id| {
            const inst = program.instructions.getMut(instruction_id) orelse unreachable;
            const reference = bufferReferenceMut(&inst.operation) orelse continue;
            const resource = reference.logical;
            const binding_table_index = layout.bindingTableIndex(resource).?;
            reference.* = .{ .binding_table = binding_table_index };
        }
    }

    program.properties.resources_lowered = true;
    validator.validate(program) catch return Error.InvalidProgram;
}

fn bufferReference(operation: instruction.Operation) ?instruction.BufferReference {
    return switch (operation) {
        .load_buffer => |op| op.buffer,
        .store_buffer => |op| op.buffer,
        .array_length => |op| op.buffer,
        else => null,
    };
}

fn bufferReferenceMut(operation: *instruction.Operation) ?*instruction.BufferReference {
    return switch (operation.*) {
        .load_buffer => |*op| &op.buffer,
        .store_buffer => |*op| &op.buffer,
        .array_length => |*op| &op.buffer,
        else => null,
    };
}

test "[gen9] compute resource lowering: resolve logical buffers" {
    const std = @import("std");
    const Builder = @import("../../../ir/Builder.zig");
    const device = @import("../../../device.zig");
    const operand = @import("../../../ir/operand.zig");
    const printer = @import("../../../ir/printer.zig");

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, device_info, .simd8);
    defer program.deinit();
    var builder = Builder.init(&program);

    const value = try builder.addVirtualRegister(.{
        .size_bytes = 32,
        .alignment_bytes = 32,
        .element_type = .u32,
        .lane_count = 8,
        .class = .temporary,
    });
    const buffer = try builder.addStorageBuffer(.{ .set = 1, .binding = 3, .name = "storage" });
    const entry = try builder.addBlock("entry");
    const store_id = try builder.appendInstruction(entry, .simd8, null, .{
        .store_buffer = .{
            .buffer = .{ .logical = buffer },
            .byte_offset = .{
                .register = .{ .immediate = .{ .u32 = 0 } },
                .type = .u32,
                .region = operand.Region.broadcast(),
            },
            .source = .{
                .register = .{ .virtual = value },
                .type = .u32,
                .region = operand.Region.contiguous(.simd8),
            },
        },
    });
    try builder.setTerminator(entry, .end_thread);

    var layout = try resource_layout.Layout.init(std.testing.allocator, &program);
    defer layout.deinit(std.testing.allocator);
    layout.bindings[0].binding = 4;
    try std.testing.expectError(Error.InvalidResourceLayout, run(&program, &layout));
    try std.testing.expect(!program.properties.resources_lowered);
    try std.testing.expect(program.instructions.get(store_id).?.operation.store_buffer.buffer == .logical);
    layout.bindings[0].binding = 3;

    try run(&program, &layout);
    try validator.validate(&program);

    try std.testing.expect(program.properties.resources_lowered);
    try std.testing.expectEqual(@as(u8, 0), program.instructions.get(store_id).?.operation.store_buffer.buffer.binding_table);
    const text = try printer.allocPrint(std.testing.allocator, &program);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "store_buffer bti(0), 0:u32") != null);
}
