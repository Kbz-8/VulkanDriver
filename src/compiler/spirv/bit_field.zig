const ir = @import("../ir/ir.zig");
const spirv = @import("spirv.zig");

const Emitter = struct {
    builder: *ir.Builder,
    block: ir.id.BlockId,

    fn binary(self: Emitter, ty: ir.id.TypeId, opcode: ir.instruction.BinaryOpcode, lhs: ir.id.ValueId, rhs: ir.id.ValueId) !ir.id.ValueId {
        return (try self.builder.appendInstruction(self.block, ty, .{
            .binary = .{
                .opcode = opcode,
                .lhs = lhs,
                .rhs = rhs,
            },
        }, null)).?;
    }

    fn bitcast(self: Emitter, ty: ir.id.TypeId, value: ir.id.ValueId) !ir.id.ValueId {
        if (self.builder.module.typeOf(value) == ty)
            return value;
        return (try self.builder.appendInstruction(self.block, ty, .{ .bitcast = value }, null)).?;
    }

    fn component(self: Emitter, ty: ir.id.TypeId, value: ir.id.ValueId, index: usize) !ir.id.ValueId {
        if (self.builder.module.typeOf(value) == ty)
            return value;
        return (try self.builder.appendInstruction(self.block, ty, .{
            .composite_extract = .{
                .composite = value,
                .indices = &.{@intCast(index)},
            },
        }, null)).?;
    }

    fn unsignedRange(self: Emitter, value: ir.id.ValueId) !ir.id.ValueId {
        const ty = self.builder.module.typeOf(value) orelse return error.InvalidId;
        const data = self.builder.module.types.get(ty) orelse return error.InvalidId;

        if (data.* != .integer)
            return error.InvalidInstruction;

        const unsigned = try self.builder.internType(.{
            .integer = .{
                .bits = data.integer.bits,
                .signedness = .unsigned,
            },
        });

        return self.bitcast(unsigned, value);
    }

    fn constant(self: Emitter, ty: ir.id.TypeId, bits: u64) !ir.id.ValueId {
        return self.builder.internConstant(ty, .{ .integer_bits = bits });
    }
};

pub fn lower(
    builder: *ir.Builder,
    block: ir.id.BlockId,
    opcode: spirv.Opcode,
    result_type: ir.id.TypeId,
    base: ir.id.ValueId,
    insert: ?ir.id.ValueId,
    offset: ir.id.ValueId,
    count: ir.id.ValueId,
    name: ?[]const u8,
) !ir.id.ValueId {
    const emit = Emitter{ .builder = builder, .block = block };
    if (builder.module.typeOf(base) != result_type or (insert != null and builder.module.typeOf(insert.?) != result_type))
        return error.InvalidInstruction;

    const result = builder.module.types.get(result_type) orelse return error.InvalidId;
    const scalar_type = switch (result.*) {
        .integer => result_type,
        .vector => |vector| if (vector.length >= 2 and vector.length <= 4)
            vector.element_type
        else
            return error.InvalidInstruction,
        else => return error.InvalidInstruction,
    };

    const scalar = builder.module.types.get(scalar_type) orelse return error.InvalidId;
    if (scalar.* != .integer)
        return error.InvalidInstruction;

    const bits = scalar.integer.bits;
    switch (bits) {
        8, 16, 32, 64 => {},
        else => return error.UnsupportedType,
    }

    const components: usize = if (result.* == .vector) result.vector.length else 1;
    const unsigned_type = try builder.internType(.{ .integer = .{ .bits = bits, .signedness = .unsigned } });
    const unsigned_offset = try emit.unsignedRange(offset);
    const unsigned_count = try emit.unsignedRange(count);

    const offset_type = builder.module.typeOf(unsigned_offset).?;
    const count_type = builder.module.typeOf(unsigned_count).?;

    const zero = try emit.constant(unsigned_type, 0);
    const ones = try emit.constant(unsigned_type, ~@as(u64, 0) >> @as(u6, @intCast(64 - bits)));

    const count_zero = try emit.constant(count_type, 0);
    const width = try emit.constant(count_type, bits);

    const count_mask = try emit.constant(count_type, bits - 1);
    const offset_mask = try emit.constant(offset_type, bits - 1);

    const boolean = try builder.internType(.boolean);
    const empty = (try builder.appendInstruction(block, boolean, .{
        .compare = .{
            .opcode = .equal,
            .lhs = unsigned_count,
            .rhs = count_zero,
        },
    }, null)).?;

    const safe_offset = try emit.binary(offset_type, .bitwise_and, unsigned_offset, offset_mask);
    const inverse_count = try emit.binary(count_type, .integer_subtract, width, unsigned_count);

    const safe_inverse = try emit.binary(count_type, .bitwise_and, inverse_count, count_mask);
    const nonempty_mask = try emit.binary(unsigned_type, .logical_shift_right, ones, safe_inverse);

    const mask = (try builder.appendInstruction(block, unsigned_type, .{
        .select = .{
            .condition = empty,
            .true_value = zero,
            .false_value = nonempty_mask,
        },
    }, null)).?;

    const signed_type = if (opcode == .bit_field_s_extract)
        try builder.internType(.{ .integer = .{ .bits = bits, .signedness = .signed } })
    else
        unsigned_type;

    var elements: [4]ir.id.ValueId = undefined;
    for (elements[0..components], 0..) |*element, index| {
        const source = try emit.bitcast(unsigned_type, try emit.component(scalar_type, base, index));

        const value = switch (opcode) {
            .bit_field_u_extract,
            .bit_field_s_extract,
            => blk: {
                const shifted = try emit.binary(unsigned_type, .logical_shift_right, source, safe_offset);
                const extracted = try emit.binary(unsigned_type, .bitwise_and, shifted, mask);

                if (opcode == .bit_field_u_extract)
                    break :blk extracted;

                const signed = try emit.bitcast(signed_type, extracted);
                const aligned = try emit.binary(signed_type, .shift_left, signed, safe_inverse);

                break :blk try emit.binary(signed_type, .arithmetic_shift_right, aligned, safe_inverse);
            },
            .bit_field_insert => blk: {
                const field_mask = try emit.binary(unsigned_type, .shift_left, mask, safe_offset);
                const inverse_mask = (try builder.appendInstruction(block, unsigned_type, .{
                    .unary = .{
                        .opcode = .bitwise_not,
                        .operand = field_mask,
                    },
                }, null)).?;

                const preserved = try emit.binary(unsigned_type, .bitwise_and, source, inverse_mask);
                const inserted = try emit.bitcast(unsigned_type, try emit.component(scalar_type, insert.?, index));
                const shifted = try emit.binary(unsigned_type, .shift_left, inserted, safe_offset);
                const field = try emit.binary(unsigned_type, .bitwise_and, shifted, field_mask);

                break :blk try emit.binary(unsigned_type, .bitwise_or, preserved, field);
            },
            else => unreachable,
        };
        element.* = try emit.bitcast(scalar_type, value);
    }

    if (components == 1)
        return (try builder.appendInstruction(block, result_type, .{ .bitcast = elements[0] }, name)).?;

    return (try builder.appendInstruction(block, result_type, .{
        .composite_construct = .{
            .elements = elements[0..components],
        },
    }, name)).?;
}
