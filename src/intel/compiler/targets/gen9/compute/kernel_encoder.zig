const std = @import("std");

const eu = @import("eu_encoder.zig");
const ids = @import("../../../ir/id.zig");
const program_ir = @import("../../../ir/program.zig");

pub const Error = std.mem.Allocator.Error || eu.Error || error{
    InvalidProgram,
    UnsupportedControlFlow,
    UnsupportedOperation,
    UnsupportedPredication,
    EotRegisterUnavailable,
};

const JumpFixup = struct {
    instruction_offset: usize,
    target: ids.BlockId,
};

pub fn encode(allocator: std.mem.Allocator, program: *program_ir.Program) Error![]u8 {
    if (!program.properties.registers_allocated)
        return Error.InvalidProgram;
    if (program.program_data.total_grf_count > eu.eot_payload_grf)
        return Error.EotRegisterUnavailable;

    const entry_id = program.entry_block orelse return Error.InvalidProgram;
    if (!program.blocks.isLive(entry_id))
        return Error.InvalidProgram;

    const block_offsets = try allocator.alloc(?usize, program.blocks.entries.items.len);
    defer allocator.free(block_offsets);
    @memset(block_offsets, null);

    var block_order: std.ArrayList(ids.BlockId) = .empty;
    defer block_order.deinit(allocator);
    try block_order.append(allocator, entry_id);
    for (program.blocks.entries.items, 0..) |block, block_index| {
        if (block != null and block_index != entry_id.index())
            try block_order.append(allocator, ids.BlockId.fromIndex(block_index));
    }

    var fixups: std.ArrayList(JumpFixup) = .empty;
    defer fixups.deinit(allocator);
    var kernel: std.ArrayList(u8) = .empty;
    errdefer kernel.deinit(allocator);

    for (block_order.items) |block_id| {
        const block = program.blocks.get(block_id) orelse return Error.InvalidProgram;
        block_offsets[block_id.index()] = kernel.items.len;

        for (block.instructions.items) |instruction_id|
            try encodeInstruction(allocator, &kernel, program, instruction_id);

        const terminator = block.terminator orelse return Error.InvalidProgram;
        switch (terminator) {
            .jump => |edge| {
                const instruction_offset = kernel.items.len;
                try appendInstruction(allocator, &kernel, try eu.encodeJump(0));
                try fixups.append(allocator, .{
                    .instruction_offset = instruction_offset,
                    .target = edge.target,
                });
            },
            .conditional_branch => |branch| {
                const true_instruction_offset = kernel.items.len;
                try appendInstruction(allocator, &kernel, try eu.encodePredicatedJump(0, branch.predicate));
                try fixups.append(allocator, .{
                    .instruction_offset = true_instruction_offset,
                    .target = branch.true_edge.target,
                });

                const false_instruction_offset = kernel.items.len;
                try appendInstruction(allocator, &kernel, try eu.encodeJump(0));
                try fixups.append(allocator, .{
                    .instruction_offset = false_instruction_offset,
                    .target = branch.false_edge.target,
                });
            },
            .end_thread => {
                const header = program.payload.header_grf orelse return Error.InvalidProgram;
                const instructions = try eu.encodeEndThread(header);
                for (instructions) |encoded|
                    try appendInstruction(allocator, &kernel, encoded);
                program.program_data.total_grf_count = eu.eot_payload_grf + 1;
            },
            .@"unreachable" => return Error.UnsupportedControlFlow,
        }
    }

    for (fixups.items) |fixup| {
        if (fixup.target.index() >= block_offsets.len)
            return Error.InvalidProgram;
        const target_offset = block_offsets[fixup.target.index()] orelse return Error.InvalidProgram;
        const next_instruction_offset = fixup.instruction_offset + 16;
        const displacement = std.math.cast(i32, @as(i64, @intCast(target_offset)) - @as(i64, @intCast(next_instruction_offset))) orelse
            return Error.UnsupportedControlFlow;
        try eu.patchJump(kernel.items[fixup.instruction_offset..][0..16], displacement);
    }

    return kernel.toOwnedSlice(allocator);
}

fn encodeInstruction(allocator: std.mem.Allocator, kernel: *std.ArrayList(u8), program: *const program_ir.Program, instruction_id: ids.InstructionId) Error!void {
    const inst = program.instructions.get(instruction_id) orelse return Error.InvalidProgram;
    if (inst.predicate != null) {
        std.log.scoped(.FlintEuEncoder).err("cannot encode instruction {d} ({t}): predication is not supported", .{ instruction_id.index(), std.meta.activeTag(inst.operation) });
        return Error.UnsupportedPredication;
    }

    const encoded = switch (inst.operation) {
        .move => |move| eu.encodeMove(inst.execution_size, move),
        .surface_message => |message| eu.encodeSurfaceMessage(inst.execution_size, message),
        .binary => |binary| eu.encodeBinary(inst.execution_size, binary),
        .compare => |compare| eu.encodeCompare(inst.execution_size, compare),
        .math => |math| eu.encodeMath(inst.execution_size, math),
        else => {
            std.log.scoped(.FlintEuEncoder).err("cannot encode instruction {d}: unsupported operation {t}", .{ instruction_id.index(), std.meta.activeTag(inst.operation) });
            return Error.UnsupportedOperation;
        },
    } catch |err| {
        std.log.scoped(.FlintEuEncoder).err("failed to encode instruction {d} ({t}): {s}", .{ instruction_id.index(), std.meta.activeTag(inst.operation), @errorName(err) });
        if (err == error.InvalidRegion) switch (inst.operation) {
            .move => |move| std.log.scoped(.FlintEuEncoder).err("move in block {d}: destination {t} byte={d} hstride={d}; source {t} byte={d} vstride={d} width={d} hstride={d}", .{
                inst.parent_block.index(),
                move.destination.register,
                move.destination.region.byte_offset,
                move.destination.region.horizontal_stride,
                move.source.register,
                move.source.region.byte_offset,
                move.source.region.vertical_stride,
                move.source.region.width,
                move.source.region.horizontal_stride,
            }),
            else => {},
        };
        return err;
    };
    try appendInstruction(allocator, kernel, encoded);
}

fn appendInstruction(allocator: std.mem.Allocator, kernel: *std.ArrayList(u8), instruction: eu.EncodedInstruction) std.mem.Allocator.Error!void {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], instruction.words[0], .little);
    std.mem.writeInt(u64, bytes[8..16], instruction.words[1], .little);
    try kernel.appendSlice(allocator, &bytes);
}

test "[gen9] kernel encoder: patch unconditional jump between blocks" {
    const device = @import("../../../device.zig");

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, device_info, .simd8);
    defer program.deinit();

    const entry = try program.addBlock("entry");
    const exit = try program.addBlock("exit");
    try program.setEntryBlock(entry);
    try program.setTerminator(entry, .{ .jump = .{ .target = exit, .arguments = &.{} } });
    try program.setTerminator(exit, .end_thread);
    program.payload.header_grf = .{ .number = 0 };
    program.properties.registers_allocated = true;

    const kernel = try encode(std.testing.allocator, &program);
    defer std.testing.allocator.free(kernel);

    try std.testing.expectEqual(@as(usize, 48), kernel.len);
    try std.testing.expectEqual(@as(u7, 32), @as(u7, @truncate(std.mem.readInt(u64, kernel[0..8], .little))));
    try std.testing.expectEqual(@as(i32, 0), @as(i32, @bitCast(std.mem.readInt(u32, kernel[12..16], .little))));
}

test "[gen9] kernel encoder: patch conditional branch targets" {
    const device = @import("../../../device.zig");

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, device_info, .simd8);
    defer program.deinit();

    const entry = try program.addBlock("entry");
    const true_block = try program.addBlock("true");
    const false_block = try program.addBlock("false");
    try program.setEntryBlock(entry);
    try program.setTerminator(entry, .{ .conditional_branch = .{
        .predicate = .{ .flag = .{ .physical = .{ .register = 0, .subregister = 1 } } },
        .true_edge = .{ .target = true_block, .arguments = &.{} },
        .false_edge = .{ .target = false_block, .arguments = &.{} },
    } });
    try program.setTerminator(true_block, .end_thread);
    try program.setTerminator(false_block, .end_thread);
    program.payload.header_grf = .{ .number = 0 };
    program.properties.registers_allocated = true;

    const kernel = try encode(std.testing.allocator, &program);
    defer std.testing.allocator.free(kernel);

    try std.testing.expectEqual(@as(usize, 96), kernel.len);
    try std.testing.expectEqual(@as(i32, 16), @as(i32, @bitCast(std.mem.readInt(u32, kernel[12..16], .little))));
    try std.testing.expectEqual(@as(i32, 32), @as(i32, @bitCast(std.mem.readInt(u32, kernel[28..32], .little))));
    const first_word = std.mem.readInt(u64, kernel[0..8], .little);
    try std.testing.expectEqual(@as(u64, 1), (first_word >> 16) & 0xf);
    try std.testing.expectEqual(@as(u64, 1), (first_word >> 32) & 0x1);
}
