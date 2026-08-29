const std = @import("std");

const eu = @import("eu_encoder.zig");
const program_ir = @import("../../../ir/program.zig");

pub const Error = std.mem.Allocator.Error || eu.Error || error{
    InvalidProgram,
    UnsupportedControlFlow,
    UnsupportedOperation,
    UnsupportedPredication,
    EotRegisterUnavailable,
};

pub fn encode(allocator: std.mem.Allocator, program: *program_ir.Program) Error![]u8 {
    if (!program.properties.registers_allocated)
        return Error.InvalidProgram;
    if (program.program_data.total_grf_count > eu.eot_payload_grf)
        return Error.EotRegisterUnavailable;

    const entry_id = program.entry_block orelse return Error.InvalidProgram;
    const entry = program.blocks.get(entry_id) orelse return Error.InvalidProgram;
    var live_block_count: usize = 0;
    for (program.blocks.entries.items) |block| {
        if (block != null)
            live_block_count += 1;
    }

    if (live_block_count != 1)
        return Error.UnsupportedControlFlow;

    var kernel: std.ArrayList(u8) = .empty;
    errdefer kernel.deinit(allocator);

    for (entry.instructions.items) |instruction_id| {
        const instruction = program.instructions.get(instruction_id) orelse return Error.InvalidProgram;
        if (instruction.predicate != null)
            return Error.UnsupportedPredication;

        const encoded = switch (instruction.operation) {
            .move => |move| try eu.encodeMove(instruction.execution_size, move),
            .surface_message => |message| try eu.encodeSurfaceMessage(instruction.execution_size, message),
            else => return Error.UnsupportedOperation,
        };
        try appendInstruction(allocator, &kernel, encoded);
    }

    const terminator = entry.terminator orelse return Error.InvalidProgram;
    switch (terminator) {
        .end_thread => {
            const header = program.payload.header_grf orelse return Error.InvalidProgram;
            const instructions = try eu.encodeEndThread(header);
            for (instructions) |instruction|
                try appendInstruction(allocator, &kernel, instruction);
            program.program_data.total_grf_count = eu.eot_payload_grf + 1;
        },
        else => return Error.UnsupportedControlFlow,
    }

    return kernel.toOwnedSlice(allocator);
}

fn appendInstruction(allocator: std.mem.Allocator, kernel: *std.ArrayList(u8), instruction: eu.EncodedInstruction) std.mem.Allocator.Error!void {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], instruction.words[0], .little);
    std.mem.writeInt(u64, bytes[8..16], instruction.words[1], .little);
    try kernel.appendSlice(allocator, &bytes);
}
