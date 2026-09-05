const operand = @import("../../../ir/operand.zig");
const program_ir = @import("../../../ir/program.zig");

pub fn run(program: *program_ir.Program) void {
    if (program.properties.regions_legalized)
        return;

    for (program.instructions.entries.items) |*entry| {
        const inst = if (entry.*) |*value| value else continue;
        switch (inst.operation) {
            .load_buffer => |*op| legalizeSource(&op.byte_offset, inst.execution_size),
            .store_buffer => |*op| {
                legalizeSource(&op.byte_offset, inst.execution_size);
                legalizeSource(&op.source, inst.execution_size);
            },
            .array_length => |*op| legalizeSource(&op.byte_offset, inst.execution_size),
            .surface_read => |*op| legalizeSource(&op.address, inst.execution_size),
            .surface_write => |*op| {
                legalizeSource(&op.address, inst.execution_size);
                legalizeSource(&op.data, inst.execution_size);
            },
            .move => |*op| legalizeSource(&op.source, inst.execution_size),
            .binary => |*op| {
                legalizeSource(&op.lhs, inst.execution_size);
                legalizeSource(&op.rhs, inst.execution_size);
            },
            .math => |*op| {
                legalizeSource(&op.lhs, inst.execution_size);
                legalizeSource(&op.rhs, inst.execution_size);
            },
            .compare => |*op| {
                legalizeSource(&op.lhs, inst.execution_size);
                legalizeSource(&op.rhs, inst.execution_size);
            },
            else => {},
        }
    }

    program.properties.regions_legalized = true;
}

fn legalizeSource(source: *operand.Source, execution_size: @import("../../../device.zig").ExecutionSize) void {
    const byte_offset = source.region.byte_offset;
    source.region = switch (source.register) {
        .immediate => operand.Region.broadcast(),
        // Physical payload operands already describe the hardware ABI, including
        // scalar header fields that must be broadcast rather than read as vectors
        .physical_grf => source.region,
        else => operand.Region.contiguous(execution_size),
    };
    source.region.byte_offset = byte_offset;
}

test "[gen9] regions: preserve scalar physical payload reads" {
    const std = @import("std");
    var source: operand.Source = .{
        .register = .{ .physical_grf = .{ .number = 0, .byte_offset = 28 } },
        .type = .u32,
        .region = operand.Region.broadcast(),
    };
    legalizeSource(&source, .simd8);
    try std.testing.expectEqual(operand.Region.broadcast(), source.region);
    try std.testing.expectEqual(@as(u8, 28), source.register.physical_grf.byte_offset);
}
