const std = @import("std");

const Builder = @import("../../../ir/Builder.zig");
const ids = @import("../../../ir/id.zig");
const instruction = @import("../../../ir/instruction.zig");
const operand = @import("../../../ir/operand.zig");
const program_ir = @import("../../../ir/program.zig");
const resource_layout = @import("resource_layout.zig");

pub const Error = std.mem.Allocator.Error || error{InvalidProgram};

pub fn run(program: *program_ir.Program, layout: *const resource_layout.Layout) Error!void {
    if (!program.properties.resources_lowered)
        return Error.InvalidProgram;
    if (layout.bindings.len >= std.math.maxInt(u8))
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
            const op = switch (inst.operation) {
                .array_length => |value| value,
                else => {
                    instruction_index += 1;
                    continue;
                },
            };
            const resource_index = switch (op.buffer) {
                .binding_table => |value| value,
                .logical => return Error.InvalidProgram,
            };
            if (resource_index >= layout.bindings.len or op.stride == 0)
                return Error.InvalidProgram;

            const execution_size = inst.execution_size;
            const predicate = inst.predicate;
            const result_source: operand.Source = .{
                .register = op.destination.register,
                .type = .u32,
                .region = operand.Region.contiguous(execution_size),
            };
            var negated_offset = op.byte_offset;
            negated_offset.negate = !negated_offset.negate;

            const mutable = program.instructions.getMut(instruction_id) orelse return Error.InvalidProgram;
            mutable.operation = .{ .load_buffer = .{
                .destination = op.destination,
                .buffer = .{ .binding_table = @intCast(layout.bindings.len) },
                .byte_offset = immediate(@as(u32, resource_index) * @sizeOf(u32)),
            } };

            _ = builder.insertInstruction(block_id, instruction_index + 1, execution_size, predicate, .{ .binary = .{
                .opcode = .add,
                .destination = op.destination,
                .lhs = result_source,
                .rhs = negated_offset,
            } }) catch |err| return mapBuilderError(err);
            _ = builder.insertInstruction(block_id, instruction_index + 2, execution_size, predicate, .{ .math = .{
                .opcode = .integer_quotient,
                .destination = op.destination,
                .lhs = result_source,
                .rhs = immediate(op.stride),
            } }) catch |err| return mapBuilderError(err);
            instruction_index += 3;
        }
    }
}

fn immediate(value: u32) operand.Source {
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
