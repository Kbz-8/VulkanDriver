const ir = @import("../ir/ir.zig");
const spirv = @import("spirv.zig");

pub fn update(
    builder: *ir.Builder,
    block: ir.id.BlockId,
    opcode: spirv.Opcode,
    previous: ir.id.ValueId,
    value: ?ir.id.ValueId,
    comparator: ?ir.id.ValueId,
) !ir.id.ValueId {
    const value_type = builder.module.typeOf(previous) orelse return error.InvalidId;
    if ((value != null and builder.module.typeOf(value.?) != value_type) or (comparator != null and builder.module.typeOf(comparator.?) != value_type))
        return error.InvalidInstruction;

    switch (opcode) {
        .atomic_exchange => return value orelse error.InvalidInstruction,
        .atomic_compare_exchange,
        .atomic_compare_exchange_weak,
        => {
            const boolean = try builder.internType(.boolean);
            const matches = (try builder.appendInstruction(block, boolean, .{
                .compare = .{
                    .opcode = .equal,
                    .lhs = previous,
                    .rhs = comparator orelse return error.InvalidInstruction,
                },
            }, null)).?;

            return (try builder.appendInstruction(block, value_type, .{
                .select = .{
                    .condition = matches,
                    .true_value = value orelse return error.InvalidInstruction,
                    .false_value = previous,
                },
            }, null)).?;
        },
        .atomic_s_min,
        .atomic_u_min,
        .atomic_s_max,
        .atomic_u_max,
        => {
            const signed = opcode == .atomic_s_min or opcode == .atomic_s_max;
            const minimum = opcode == .atomic_s_min or opcode == .atomic_u_min;

            const compare_type = try builder.internType(.{
                .integer = .{
                    .bits = 32,
                    .signedness = if (signed) .signed else .unsigned,
                },
            });

            const rhs = value orelse return error.InvalidInstruction;

            const left = if (value_type == compare_type) previous else (try builder.appendInstruction(block, compare_type, .{ .bitcast = previous }, null)).?;
            const right = if (value_type == compare_type) rhs else (try builder.appendInstruction(block, compare_type, .{ .bitcast = rhs }, null)).?;

            const boolean = try builder.internType(.boolean);

            const less = (try builder.appendInstruction(block, boolean, .{
                .compare = .{
                    .opcode = if (signed) .signed_less else .unsigned_less,
                    .lhs = left,
                    .rhs = right,
                },
            }, null)).?;

            return (try builder.appendInstruction(block, value_type, .{
                .select = .{
                    .condition = less,
                    .true_value = if (minimum) previous else rhs,
                    .false_value = if (minimum) rhs else previous,
                },
            }, null)).?;
        },
        else => {},
    }

    const binary_opcode: ir.instruction.BinaryOpcode = switch (opcode) {
        .atomic_i_add, .atomic_i_increment => .integer_add,
        .atomic_i_sub, .atomic_i_decrement => .integer_subtract,
        .atomic_and => .bitwise_and,
        .atomic_or => .bitwise_or,
        .atomic_xor => .bitwise_xor,
        else => return error.UnsupportedOpcode,
    };

    const rhs = if (opcode == .atomic_i_increment or opcode == .atomic_i_decrement)
        try builder.internConstant(value_type, .{ .integer_bits = 1 })
    else
        value orelse return error.InvalidInstruction;

    return (try builder.appendInstruction(block, value_type, .{
        .binary = .{
            .opcode = binary_opcode,
            .lhs = previous,
            .rhs = rhs,
        },
    }, null)).?;
}
