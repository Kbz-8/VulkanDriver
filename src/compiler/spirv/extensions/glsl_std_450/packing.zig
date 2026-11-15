const ir = @import("../../../ir/ir.zig");
const ext = @import("../types.zig");

pub const Format = enum {
    snorm2x16,
    unorm2x16,
    snorm4x8,
    unorm4x8,
    half2x16,
    double2x32,
};

const Emitter = struct {
    ext: *ext.Emitter,

    fn emit(self: Emitter, ty: ir.id.TypeId, operation: ir.instruction.Operation, name: ?[]const u8) !ir.id.ValueId {
        return (try self.ext.builder.appendInstruction(self.ext.block, ty, operation, name)).?;
    }

    fn binary(self: Emitter, ty: ir.id.TypeId, opcode: ir.instruction.BinaryOpcode, lhs: ir.id.ValueId, rhs: ir.id.ValueId) !ir.id.ValueId {
        return self.emit(ty, .{ .binary = .{ .opcode = opcode, .lhs = lhs, .rhs = rhs } }, null);
    }

    fn convert(self: Emitter, ty: ir.id.TypeId, opcode: ir.instruction.ConvertOpcode, operand: ir.id.ValueId) !ir.id.ValueId {
        return self.emit(ty, .{ .convert = .{ .opcode = opcode, .operand = operand } }, null);
    }

    fn integer(self: Emitter, ty: ir.id.TypeId, value: u64) !ir.id.ValueId {
        return self.ext.builder.internConstant(ty, .{ .integer_bits = value });
    }

    fn float(self: Emitter, ty: ir.id.TypeId, value: f32) !ir.id.ValueId {
        return self.ext.builder.internConstant(ty, .{ .float_bits = @as(u32, @bitCast(value)) });
    }
};

pub fn lower(emitter: *ext.Emitter, invocation: ext.Invocation, comptime format: Format, comptime pack: bool) !ir.id.ValueId {
    if (invocation.operands.len != 1)
        return error.InvalidInstruction;

    const count = switch (format) {
        .snorm4x8, .unorm4x8 => 4,
        else => 2,
    };

    const bits = switch (format) {
        .snorm4x8, .unorm4x8 => 8,
        .double2x32 => 32,
        else => 16,
    };

    const signed = format == .snorm2x16 or format == .snorm4x8;
    const normalized = switch (format) {
        .snorm2x16, .unorm2x16, .snorm4x8, .unorm4x8 => true,
        else => false,
    };

    const emit = Emitter{ .ext = emitter };
    const u32_type = try emitter.builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });
    const f32_type = try emitter.builder.internType(.{ .floating = .{ .bits = 32 } });
    const element_type = if (format == .double2x32) u32_type else f32_type;
    const vector_type = try emitter.builder.internType(.{ .vector = .{ .element_type = element_type, .length = count } });

    const scalar_type = if (format == .double2x32)
        try emitter.builder.internType(.{ .floating = .{ .bits = 64 } })
    else
        u32_type;

    const operand = invocation.operands[0];
    if (emitter.module.typeOf(operand) != (if (pack) vector_type else scalar_type) or invocation.result_type != (if (pack) scalar_type else vector_type))
        return error.InvalidInstruction;

    const packed_type = if (format == .double2x32)
        try emitter.builder.internType(.{ .integer = .{ .bits = 64, .signedness = .unsigned } })
    else
        u32_type;

    const mask = try emit.integer(packed_type, (1 << bits) - 1);

    const packed_value = if (pack)
        try emit.integer(packed_type, 0)
    else if (format == .double2x32)
        try emit.emit(packed_type, .{ .bitcast = operand }, null)
    else
        operand;

    var result = packed_value;
    var elements: [count]ir.id.ValueId = undefined;

    inline for (0..count) |index| {
        const shift = try emit.integer(packed_type, index * bits);
        if (pack) {
            const value = try emit.emit(element_type, .{
                .composite_extract = .{
                    .composite = operand,
                    .indices = &.{index},
                },
            }, null);

            var field: ir.id.ValueId = undefined;
            if (normalized) {
                const lower_bound = try emit.float(f32_type, if (signed) -1.0 else 0.0);
                const upper = try emit.float(f32_type, 1.0);
                const scale = try emit.float(f32_type, if (signed) (1 << (bits - 1)) - 1 else (1 << bits) - 1);
                const low_clamped = try emit.binary(f32_type, .float_max, value, lower_bound);
                const clamped = try emit.binary(f32_type, .float_min, low_clamped, upper);
                const scaled = try emit.binary(f32_type, .float_multiply, clamped, scale);
                const rounded = try emit.emit(f32_type, .{
                    .unary = .{
                        .opcode = .round,
                        .operand = scaled,
                    },
                }, null);

                if (signed) {
                    const i32_type = try emitter.builder.internType(.{ .integer = .{ .bits = 32, .signedness = .signed } });
                    const integer = try emit.convert(i32_type, .float_to_signed, rounded);
                    field = try emit.emit(u32_type, .{ .bitcast = integer }, null);
                } else {
                    field = try emit.convert(u32_type, .float_to_unsigned, rounded);
                }
            } else if (format == .half2x16) {
                const f16_type = try emitter.builder.internType(.{
                    .floating = .{ .bits = 16 },
                });

                const u16_type = try emitter.builder.internType(.{
                    .integer = .{
                        .bits = 16,
                        .signedness = .unsigned,
                    },
                });

                const half = try emit.convert(f16_type, .float_convert, value);
                const half_bits = try emit.emit(u16_type, .{ .bitcast = half }, null);
                field = try emit.convert(u32_type, .unsigned_convert, half_bits);
            } else {
                field = try emit.convert(packed_type, .unsigned_convert, value);
            }

            const masked = try emit.binary(packed_type, .bitwise_and, field, mask);
            const shifted = try emit.binary(packed_type, .shift_left, masked, shift);

            result = try emit.emit(packed_type, .{
                .binary = .{
                    .opcode = .bitwise_or,
                    .lhs = result,
                    .rhs = shifted,
                },
            }, if (index + 1 == count and format != .double2x32) invocation.result_name else null);
        } else {
            const shifted = try emit.binary(packed_type, .logical_shift_right, packed_value, shift);
            const field = try emit.binary(packed_type, .bitwise_and, shifted, mask);

            if (normalized) {
                var converted: ir.id.ValueId = undefined;
                if (signed) {
                    const i32_type = try emitter.builder.internType(.{
                        .integer = .{
                            .bits = 32,
                            .signedness = .signed,
                        },
                    });

                    const left_shift = try emit.integer(u32_type, 32 - bits);
                    const high = try emit.binary(u32_type, .shift_left, field, left_shift);
                    const signed_high = try emit.emit(i32_type, .{ .bitcast = high }, null);
                    const right_shift = try emit.integer(i32_type, 32 - bits);
                    const extended = try emit.binary(i32_type, .arithmetic_shift_right, signed_high, right_shift);

                    converted = try emit.convert(f32_type, .signed_to_float, extended);
                } else {
                    converted = try emit.convert(f32_type, .unsigned_to_float, field);
                }

                const scale = try emit.float(f32_type, if (signed) (1 << (bits - 1)) - 1 else (1 << bits) - 1);
                const fraction = try emit.binary(f32_type, .float_divide, converted, scale);

                elements[index] = if (signed)
                    try emit.binary(f32_type, .float_max, fraction, try emit.float(f32_type, -1.0))
                else
                    fraction;
            } else if (format == .half2x16) {
                const u16_type = try emitter.builder.internType(.{
                    .integer = .{
                        .bits = 16,
                        .signedness = .unsigned,
                    },
                });

                const f16_type = try emitter.builder.internType(.{
                    .floating = .{
                        .bits = 16,
                    },
                });

                const half_bits = try emit.convert(u16_type, .unsigned_convert, field);
                const half = try emit.emit(f16_type, .{ .bitcast = half_bits }, null);
                elements[index] = try emit.convert(f32_type, .float_convert, half);
            } else {
                elements[index] = try emit.convert(u32_type, .unsigned_convert, field);
            }
        }
    }

    if (pack) {
        if (format == .double2x32)
            return emit.emit(scalar_type, .{ .bitcast = result }, invocation.result_name);
        return result;
    }

    return emit.emit(vector_type, .{ .composite_construct = .{ .elements = &elements } }, invocation.result_name);
}
