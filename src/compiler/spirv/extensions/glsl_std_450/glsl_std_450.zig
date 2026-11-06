const std = @import("std");
const ir = @import("../../../ir/ir.zig");
const ext = @import("../types.zig");
const vector_helper = @import("../../vector.zig");

pub const Opcode = enum(u32) {
    acos = 17,
    acosh = 23,
    asin = 16,
    asinh = 22,
    atan = 18,
    atan2 = 25,
    atanh = 24,
    bad = 0,
    ceil = 9,
    cos = 14,
    cosh = 20,
    cross = 68,
    degrees = 12,
    determinant = 33,
    distance = 67,
    exp = 27,
    exp2 = 29,
    f_abs = 4,
    f_clamp = 43,
    f_max = 40,
    f_min = 37,
    f_mix = 46,
    f_sign = 6,
    face_forward = 70,
    find_i_lsb = 73,
    find_s_msb = 74,
    find_u_msb = 75,
    floor = 8,
    fma = 50,
    fract = 10,
    frexp = 51,
    frexp_struct = 52,
    i_mix = 47,
    interpolate_at_centroid = 76,
    interpolate_at_offset = 78,
    interpolate_at_sample = 77,
    inverse_sqrt = 32,
    ldexp = 53,
    length = 66,
    log = 28,
    log2 = 30,
    matrix_inverse = 34,
    modf = 35,
    modf_struct = 36,
    n_clamp = 81,
    n_max = 80,
    n_min = 79,
    normalize = 69,
    pack_double2x32 = 59,
    pack_half2x16 = 58,
    pack_snorm2x16 = 56,
    pack_snorm4x8 = 54,
    pack_unorm2x16 = 57,
    pack_unorm4x8 = 55,
    pow = 26,
    radians = 11,
    reflect = 71,
    refract = 72,
    round = 1,
    round_even = 2,
    s_abs = 5,
    s_clamp = 45,
    s_max = 42,
    s_min = 39,
    s_sign = 7,
    sin = 13,
    sinh = 19,
    smooth_step = 49,
    sqrt = 31,
    step = 48,
    tan = 15,
    tanh = 21,
    trunc = 3,
    u_clamp = 44,
    u_max = 41,
    u_min = 38,
    unpack_double2x32 = 65,
    unpack_half2x16 = 62,
    unpack_snorm2x16 = 60,
    unpack_snorm4x8 = 63,
    unpack_unorm2x16 = 61,
    unpack_unorm4x8 = 64,
};

pub fn translate(emitter: *ext.Emitter, invocation: ext.Invocation) !ir.id.ValueId {
    const opcode: Opcode = @fromBackingInt(@intCast(invocation.opcode));
    return switch (opcode) {
        .acos => translateUnary(emitter, invocation, .acos),
        .acosh => translateUnary(emitter, invocation, .acosh),
        .asin => translateUnary(emitter, invocation, .asin),
        .asinh => translateUnary(emitter, invocation, .asinh),
        .atan => translateUnary(emitter, invocation, .atan),
        .atan2 => translateBinary(emitter, invocation, .atan2),
        .atanh => translateUnary(emitter, invocation, .atanh),
        .ceil => translateUnary(emitter, invocation, .ceil),
        .cos => translateUnary(emitter, invocation, .cos),
        .cosh => translateUnary(emitter, invocation, .cosh),
        .cross => translateCross(emitter, invocation),
        .degrees => translateAngleScale(emitter, invocation, 180.0 / std.math.pi),
        .distance => translateDistance(emitter, invocation),
        .exp => translateUnary(emitter, invocation, .exp),
        .exp2 => translateUnary(emitter, invocation, .exp2),
        .f_abs => translateUnary(emitter, invocation, .float_absolute),
        .f_clamp => translateClamp(emitter, invocation, .float_max, .float_min),
        .f_max => translateBinary(emitter, invocation, .float_max),
        .f_min => translateBinary(emitter, invocation, .float_min),
        .f_mix => translateFMix(emitter, invocation),
        .f_sign => translateSign(emitter, invocation, true),
        .find_i_lsb => translateUnary(emitter, invocation, .find_lsb),
        .find_s_msb => translateUnary(emitter, invocation, .find_s_msb),
        .find_u_msb => translateUnary(emitter, invocation, .find_u_msb),
        .floor => translateUnary(emitter, invocation, .floor),
        .fma => translateTernary(emitter, invocation, .float_mul_add),
        .fract => translateFract(emitter, invocation),
        .inverse_sqrt => translateUnary(emitter, invocation, .inverse_sqrt),
        .length => translateLength(emitter, invocation),
        .log => translateUnary(emitter, invocation, .log),
        .log2 => translateUnary(emitter, invocation, .log2),
        .modf_struct => translateModfStruct(emitter, invocation),
        .n_clamp => translateNClamp(emitter, invocation),
        .normalize => translateNormalize(emitter, invocation),
        .pow => translateBinary(emitter, invocation, .pow),
        .radians => translateAngleScale(emitter, invocation, std.math.pi / 180.0),
        .reflect => translateReflect(emitter, invocation),
        .round => translateUnary(emitter, invocation, .round),
        .round_even => translateRoundEven(emitter, invocation),
        .s_abs => translateUnary(emitter, invocation, .integer_absolute),
        .s_clamp => translateClamp(emitter, invocation, .signed_max, .signed_min),
        .s_max => translateBinary(emitter, invocation, .signed_max),
        .s_min => translateBinary(emitter, invocation, .signed_min),
        .s_sign => translateSign(emitter, invocation, false),
        .sin => translateUnary(emitter, invocation, .sin),
        .sinh => translateUnary(emitter, invocation, .sinh),
        .smooth_step => translateSmoothStep(emitter, invocation),
        .sqrt => translateUnary(emitter, invocation, .sqrt),
        .step => translateStep(emitter, invocation),
        .tan => translateUnary(emitter, invocation, .tan),
        .tanh => translateUnary(emitter, invocation, .tanh),
        .trunc => translateUnary(emitter, invocation, .trunc),
        .u_clamp => translateClamp(emitter, invocation, .unsigned_max, .unsigned_min),
        .u_max => translateBinary(emitter, invocation, .unsigned_max),
        .u_min => translateBinary(emitter, invocation, .unsigned_min),
        .ldexp => translateBinary(emitter, invocation, .ldexp),

        else => {
            std.log.scoped(.spirv_translator).err("unsupported GLSL.std.450 instruction {t}", .{opcode});
            return error.UnsupportedExtendedInstruction;
        },
    };
}

fn translateUnary(emitter: *ext.Emitter, invocation: ext.Invocation, opcode: ir.instruction.UnaryOpcode) !ir.id.ValueId {
    if (invocation.operands.len != 1)
        return error.InvalidInstruction;

    const operand = invocation.operands[0];
    switch (opcode) {
        // Find bit results are i32
        .find_lsb, .find_s_msb, .find_u_msb => {},
        else => if (emitter.module.typeOf(operand) != invocation.result_type)
            return error.InvalidInstruction,
    }

    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .unary = .{
            .opcode = opcode,
            .operand = operand,
        },
    }, invocation.result_name)).?;
}

fn translateFract(emitter: *ext.Emitter, invocation: ext.Invocation) !ir.id.ValueId {
    _ = try validateFloatOperands(emitter, invocation, 1);
    const operand = invocation.operands[0];
    const floored = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .unary = .{
            .opcode = .floor,
            .operand = operand,
        },
    }, null)).?;

    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_subtract,
            .lhs = operand,
            .rhs = floored,
        },
    }, invocation.result_name)).?;
}

fn translateRoundEven(emitter: *ext.Emitter, invocation: ext.Invocation) !ir.id.ValueId {
    const scalar_type = try validateFloatOperands(emitter, invocation, 1);
    const value_type = invocation.result_type;
    const operand = invocation.operands[0];

    const half = try floatConstant(emitter, value_type, 0.5);
    const two = try floatConstant(emitter, value_type, 2.0);
    const boolean = try emitter.builder.internType(.boolean);

    const condition_type = if (value_type == scalar_type)
        boolean
    else
        try emitter.builder.internType(.{
            .vector = .{
                .element_type = boolean,
                .length = emitter.module.types.get(value_type).?.vector.length,
            },
        });

    const rounded = (try emitter.builder.appendInstruction(emitter.block, value_type, .{
        .unary = .{
            .opcode = .round,
            .operand = operand,
        },
    }, null)).?;

    const difference = (try emitter.builder.appendInstruction(emitter.block, value_type, .{
        .binary = .{
            .opcode = .float_subtract,
            .lhs = operand,
            .rhs = rounded,
        },
    }, null)).?;

    const distance = (try emitter.builder.appendInstruction(emitter.block, value_type, .{
        .unary = .{
            .opcode = .float_absolute,
            .operand = difference,
        },
    }, null)).?;

    const halfway = (try emitter.builder.appendInstruction(emitter.block, condition_type, .{
        .compare = .{
            .opcode = .ordered_float_equal,
            .lhs = distance,
            .rhs = half,
        },
    }, null)).?;

    const halved = (try emitter.builder.appendInstruction(emitter.block, value_type, .{
        .binary = .{
            .opcode = .float_multiply,
            .lhs = rounded,
            .rhs = half,
        },
    }, null)).?;

    const truncated = (try emitter.builder.appendInstruction(emitter.block, value_type, .{
        .unary = .{
            .opcode = .trunc,
            .operand = halved,
        },
    }, null)).?;

    const even = (try emitter.builder.appendInstruction(emitter.block, value_type, .{
        .binary = .{
            .opcode = .float_multiply,
            .lhs = truncated,
            .rhs = two,
        },
    }, null)).?;

    return (try emitter.builder.appendInstruction(emitter.block, value_type, .{
        .select = .{
            .condition = halfway,
            .true_value = even,
            .false_value = rounded,
        },
    }, invocation.result_name)).?;
}

fn translateBinary(emitter: *ext.Emitter, invocation: ext.Invocation, opcode: ir.instruction.BinaryOpcode) !ir.id.ValueId {
    if (invocation.operands.len != 2)
        return error.InvalidInstruction;
    const lhs = invocation.operands[0];
    const rhs = invocation.operands[1];

    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = opcode,
            .lhs = lhs,
            .rhs = rhs,
        },
    }, invocation.result_name)).?;
}

fn validateFloatOperands(emitter: *ext.Emitter, invocation: ext.Invocation, operand_count: usize) !ir.id.TypeId {
    if (invocation.operands.len != operand_count)
        return error.InvalidInstruction;

    const scalar_type = try floatScalarType(emitter.module, invocation.result_type);
    for (invocation.operands) |operand| {
        if (emitter.module.typeOf(operand) != invocation.result_type)
            return error.InvalidInstruction;
    }

    return scalar_type;
}

fn floatConstant(emitter: *ext.Emitter, type_id: ir.id.TypeId, comptime value: comptime_float) !ir.id.ValueId {
    const scalar_type = try floatScalarType(emitter.module, type_id);
    const scalar = emitter.module.types.get(scalar_type).?;
    const bits: u64 = switch (scalar.floating.bits) {
        16 => @as(u16, @bitCast(@as(f16, value))),
        32 => @as(u32, @bitCast(@as(f32, value))),
        64 => @as(u64, @bitCast(@as(f64, value))),
        else => return error.UnsupportedType,
    };
    const constant = try emitter.builder.internConstant(scalar_type, .{ .float_bits = bits });

    if (type_id == scalar_type)
        return constant;

    const vector = emitter.module.types.get(type_id).?.vector;
    const elements = try emitter.scratch.alloc(ir.id.ConstantId, vector.length);
    @memset(elements, emitter.module.values.get(constant).?.definition.constant);
    return emitter.builder.internConstant(type_id, .{ .composite = elements });
}

fn translateModfStruct(emitter: *ext.Emitter, invocation: ext.Invocation) !ir.id.ValueId {
    if (invocation.operands.len != 1)
        return error.InvalidInstruction;

    const operand = invocation.operands[0];
    const value_type = emitter.module.typeOf(operand) orelse return error.InvalidId;
    const result = emitter.module.types.get(invocation.result_type) orelse return error.InvalidId;

    if (result.* != .structure or result.structure.members.len != 2 or result.structure.members[0] != value_type or result.structure.members[1] != value_type)
        return error.InvalidInstruction;

    const parts = try emitModf(emitter, operand, null);

    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .composite_construct = .{
            .elements = &.{
                parts.fraction,
                parts.whole,
            },
        },
    }, invocation.result_name)).?;
}

pub fn emitModf(emitter: *ext.Emitter, operand: ir.id.ValueId, result_name: ?[]const u8) !struct { fraction: ir.id.ValueId, whole: ir.id.ValueId } {
    const value_type = emitter.module.typeOf(operand) orelse return error.InvalidId;
    const scalar_type = try floatScalarType(emitter.module, value_type);
    const zero = try floatConstant(emitter, value_type, 0.0);
    const negative_zero = try floatConstant(emitter, value_type, -0.0);
    const one = try floatConstant(emitter, value_type, 1.0);
    const boolean = try emitter.builder.internType(.boolean);

    const condition_type = if (value_type == scalar_type)
        boolean
    else
        try emitter.builder.internType(.{
            .vector = .{
                .element_type = boolean,
                .length = emitter.module.types.get(value_type).?.vector.length,
            },
        });

    const whole = (try emitter.builder.appendInstruction(emitter.block, value_type, .{
        .unary = .{
            .opcode = .trunc,
            .operand = operand,
        },
    }, null)).?;

    // Remainder by one preserves negative fractions and signed zero unlike fract
    const remainder = (try emitter.builder.appendInstruction(emitter.block, value_type, .{
        .binary = .{
            .opcode = .float_remainder,
            .lhs = operand,
            .rhs = one,
        },
    }, null)).?;

    const infinite = (try emitter.builder.appendInstruction(emitter.block, condition_type, .{
        .unary = .{
            .opcode = .is_inf,
            .operand = operand,
        },
    }, null)).?;

    const negative = (try emitter.builder.appendInstruction(emitter.block, condition_type, .{
        .compare = .{
            .opcode = .ordered_float_less,
            .lhs = operand,
            .rhs = zero,
        },
    }, null)).?;

    const infinite_fraction = (try emitter.builder.appendInstruction(emitter.block, value_type, .{
        .select = .{
            .condition = negative,
            .true_value = negative_zero,
            .false_value = zero,
        },
    }, null)).?;

    const fraction = (try emitter.builder.appendInstruction(emitter.block, value_type, .{
        .select = .{
            .condition = infinite,
            .true_value = infinite_fraction,
            .false_value = remainder,
        },
    }, result_name)).?;

    return .{ .fraction = fraction, .whole = whole };
}

fn validateIntegerOperands(emitter: *ext.Emitter, invocation: ext.Invocation, operand_count: usize) !ir.id.TypeId {
    if (invocation.operands.len != operand_count)
        return error.InvalidInstruction;

    const definition = emitter.module.types.get(invocation.result_type) orelse return error.InvalidId;

    const scalar_type = switch (definition.*) {
        .integer => invocation.result_type,
        .vector => |vector| if (vector.length >= 2) vector.element_type else return error.InvalidInstruction,
        else => return error.InvalidInstruction,
    };

    const scalar = emitter.module.types.get(scalar_type) orelse return error.InvalidId;

    if (scalar.* != .integer)
        return error.InvalidInstruction;

    if (scalar.integer.bits == 0 or scalar.integer.bits > 64)
        return error.UnsupportedType;

    for (invocation.operands) |operand| {
        if (emitter.module.typeOf(operand) != invocation.result_type)
            return error.InvalidInstruction;
    }

    return scalar_type;
}

fn integerConstant(emitter: *ext.Emitter, type_id: ir.id.TypeId, scalar_type: ir.id.TypeId, comptime value: comptime_int) !ir.id.ValueId {
    const width = emitter.module.types.get(scalar_type).?.integer.bits;
    const mask = @as(u64, std.math.maxInt(u64)) >> @as(u6, @intCast(64 - width));
    const bits = @as(u64, @bitCast(@as(i64, value))) & mask;
    const constant = try emitter.builder.internConstant(scalar_type, .{ .integer_bits = bits });

    if (type_id == scalar_type)
        return constant;

    const vector = emitter.module.types.get(type_id).?.vector;
    const elements = try emitter.scratch.alloc(ir.id.ConstantId, vector.length);
    @memset(elements, emitter.module.values.get(constant).?.definition.constant);
    return emitter.builder.internConstant(type_id, .{ .composite = elements });
}

fn translateClamp(emitter: *ext.Emitter, invocation: ext.Invocation, maximum: ir.instruction.BinaryOpcode, minimum: ir.instruction.BinaryOpcode) !ir.id.ValueId {
    if (maximum == .float_max) {
        _ = try validateFloatOperands(emitter, invocation, 3);
    } else {
        _ = try validateIntegerOperands(emitter, invocation, 3);
    }

    const lower_clamped = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = maximum,
            .lhs = invocation.operands[0],
            .rhs = invocation.operands[1],
        },
    }, null)).?;

    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = minimum,
            .lhs = lower_clamped,
            .rhs = invocation.operands[2],
        },
    }, invocation.result_name)).?;
}

fn translateSign(emitter: *ext.Emitter, invocation: ext.Invocation, comptime floating: bool) !ir.id.ValueId {
    const scalar_type = if (floating)
        try validateFloatOperands(emitter, invocation, 1)
    else
        try validateIntegerOperands(emitter, invocation, 1);

    const zero = if (floating)
        try floatConstant(emitter, invocation.result_type, 0.0)
    else
        try integerConstant(emitter, invocation.result_type, scalar_type, 0);

    const one = if (floating)
        try floatConstant(emitter, invocation.result_type, 1.0)
    else
        try integerConstant(emitter, invocation.result_type, scalar_type, 1);

    const negative_one = if (floating)
        try floatConstant(emitter, invocation.result_type, -1.0)
    else
        try integerConstant(emitter, invocation.result_type, scalar_type, -1);

    const bool_type = try emitter.builder.internType(.boolean);

    const condition_type = if (scalar_type == invocation.result_type)
        bool_type
    else
        try emitter.builder.internType(.{
            .vector = .{
                .element_type = bool_type,
                .length = emitter.module.types.get(invocation.result_type).?.vector.length,
            },
        });

    var operand = invocation.operands[0];
    var comparison_zero = zero;

    if (!floating) {
        const integer = emitter.module.types.get(scalar_type).?.integer;

        if (integer.signedness == .unsigned) {
            const signed_scalar = try emitter.builder.internType(.{
                .integer = .{
                    .bits = integer.bits,
                    .signedness = .signed,
                },
            });

            const signed_type = if (scalar_type == invocation.result_type)
                signed_scalar
            else
                try emitter.builder.internType(.{
                    .vector = .{
                        .element_type = signed_scalar,
                        .length = emitter.module.types.get(invocation.result_type).?.vector.length,
                    },
                });

            operand = (try emitter.builder.appendInstruction(emitter.block, signed_type, .{ .bitcast = operand }, null)).?;
            comparison_zero = (try emitter.builder.appendInstruction(emitter.block, signed_type, .{ .bitcast = zero }, null)).?;
        }
    }

    const negative = (try emitter.builder.appendInstruction(emitter.block, condition_type, .{
        .compare = .{
            .opcode = if (floating) .ordered_float_less else .signed_less,
            .lhs = operand,
            .rhs = comparison_zero,
        },
    }, null)).?;

    const positive = (try emitter.builder.appendInstruction(emitter.block, condition_type, .{
        .compare = .{
            .opcode = if (floating) .ordered_float_less else .signed_less,
            .lhs = comparison_zero,
            .rhs = operand,
        },
    }, null)).?;

    const nonnegative_sign = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .select = .{
            .condition = positive,
            .true_value = one,
            .false_value = zero,
        },
    }, null)).?;

    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .select = .{
            .condition = negative,
            .true_value = negative_one,
            .false_value = nonnegative_sign,
        },
    }, invocation.result_name)).?;
}

fn translateAngleScale(emitter: *ext.Emitter, invocation: ext.Invocation, comptime scale: comptime_float) !ir.id.ValueId {
    _ = try validateFloatOperands(emitter, invocation, 1);
    const factor = try floatConstant(emitter, invocation.result_type, scale);
    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_multiply,
            .lhs = invocation.operands[0],
            .rhs = factor,
        },
    }, invocation.result_name)).?;
}

fn translateFMix(emitter: *ext.Emitter, invocation: ext.Invocation) !ir.id.ValueId {
    _ = try validateFloatOperands(emitter, invocation, 3);

    const x = invocation.operands[0];
    const y = invocation.operands[1];
    const a = invocation.operands[2];

    const one = try floatConstant(emitter, invocation.result_type, 1.0);

    const complement = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_subtract,
            .lhs = one,
            .rhs = a,
        },
    }, null)).?;

    const weighted_x = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_multiply,
            .lhs = x,
            .rhs = complement,
        },
    }, null)).?;

    const weighted_y = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_multiply,
            .lhs = y,
            .rhs = a,
        },
    }, null)).?;

    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_add,
            .lhs = weighted_x,
            .rhs = weighted_y,
        },
    }, invocation.result_name)).?;
}

fn translateSmoothStep(emitter: *ext.Emitter, invocation: ext.Invocation) !ir.id.ValueId {
    _ = try validateFloatOperands(emitter, invocation, 3);

    const edge0 = invocation.operands[0];
    const edge1 = invocation.operands[1];

    const x = invocation.operands[2];

    const zero = try floatConstant(emitter, invocation.result_type, 0.0);
    const one = try floatConstant(emitter, invocation.result_type, 1.0);
    const two = try floatConstant(emitter, invocation.result_type, 2.0);
    const three = try floatConstant(emitter, invocation.result_type, 3.0);

    const offset = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_subtract,
            .lhs = x,
            .rhs = edge0,
        },
    }, null)).?;

    const width = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_subtract,
            .lhs = edge1,
            .rhs = edge0,
        },
    }, null)).?;

    const normalized = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_divide,
            .lhs = offset,
            .rhs = width,
        },
    }, null)).?;

    const lower_clamped = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_max,
            .lhs = normalized,
            .rhs = zero,
        },
    }, null)).?;

    const t = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_min,
            .lhs = lower_clamped,
            .rhs = one,
        },
    }, null)).?;

    const squared = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_multiply,
            .lhs = t,
            .rhs = t,
        },
    }, null)).?;

    const doubled = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_multiply,
            .lhs = two,
            .rhs = t,
        },
    }, null)).?;

    const factor = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_subtract,
            .lhs = three,
            .rhs = doubled,
        },
    }, null)).?;

    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_multiply,
            .lhs = squared,
            .rhs = factor,
        },
    }, invocation.result_name)).?;
}

fn translateStep(emitter: *ext.Emitter, invocation: ext.Invocation) !ir.id.ValueId {
    const scalar_type = try validateFloatOperands(emitter, invocation, 2);

    const zero = try floatConstant(emitter, invocation.result_type, 0.0);
    const one = try floatConstant(emitter, invocation.result_type, 1.0);

    const bool_type = try emitter.builder.internType(.boolean);

    const condition_type = if (scalar_type == invocation.result_type)
        bool_type
    else
        try emitter.builder.internType(.{
            .vector = .{
                .element_type = bool_type,
                .length = emitter.module.types.get(invocation.result_type).?.vector.length,
            },
        });

    const below_edge = (try emitter.builder.appendInstruction(emitter.block, condition_type, .{
        .compare = .{
            .opcode = .ordered_float_less,
            .lhs = invocation.operands[1],
            .rhs = invocation.operands[0],
        },
    }, null)).?;

    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .select = .{
            .condition = below_edge,
            .true_value = zero,
            .false_value = one,
        },
    }, invocation.result_name)).?;
}

fn translateCross(emitter: *ext.Emitter, invocation: ext.Invocation) !ir.id.ValueId {
    if (invocation.operands.len != 2)
        return error.InvalidInstruction;

    const definition = emitter.module.types.get(invocation.result_type) orelse return error.InvalidId;
    const vector = switch (definition.*) {
        .vector => |vector| vector,
        else => return error.InvalidInstruction,
    };
    if (vector.length != 3)
        return error.InvalidInstruction;

    _ = try floatScalarType(emitter.module, invocation.result_type);
    for (invocation.operands) |operand| {
        if (emitter.module.typeOf(operand) != invocation.result_type)
            return error.InvalidInstruction;
    }

    var lhs: [3]ir.id.ValueId = undefined;
    var rhs: [3]ir.id.ValueId = undefined;
    for (0..3) |index| {
        const indices = &.{@as(u32, @intCast(index))};
        lhs[index] = (try emitter.builder.appendInstruction(emitter.block, vector.element_type, .{
            .composite_extract = .{
                .composite = invocation.operands[0],
                .indices = indices,
            },
        }, null)).?;
        rhs[index] = (try emitter.builder.appendInstruction(emitter.block, vector.element_type, .{
            .composite_extract = .{
                .composite = invocation.operands[1],
                .indices = indices,
            },
        }, null)).?;
    }

    var elements: [3]ir.id.ValueId = undefined;
    for (&elements, 0..) |*element, index| {
        const j = (index + 1) % 3;
        const k = (index + 2) % 3;
        const positive = (try emitter.builder.appendInstruction(emitter.block, vector.element_type, .{
            .binary = .{
                .opcode = .float_multiply,
                .lhs = lhs[j],
                .rhs = rhs[k],
            },
        }, null)).?;
        const negative = (try emitter.builder.appendInstruction(emitter.block, vector.element_type, .{
            .binary = .{
                .opcode = .float_multiply,
                .lhs = lhs[k],
                .rhs = rhs[j],
            },
        }, null)).?;
        element.* = (try emitter.builder.appendInstruction(emitter.block, vector.element_type, .{
            .binary = .{
                .opcode = .float_subtract,
                .lhs = positive,
                .rhs = negative,
            },
        }, null)).?;
    }
    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .composite_construct = .{ .elements = &elements },
    }, invocation.result_name)).?;
}

fn translateReflect(emitter: *ext.Emitter, invocation: ext.Invocation) !ir.id.ValueId {
    if (invocation.operands.len != 2)
        return error.InvalidInstruction;

    const scalar_type = try floatScalarType(emitter.module, invocation.result_type);
    const incident = invocation.operands[0];
    const normal = invocation.operands[1];

    if (emitter.module.typeOf(incident) != invocation.result_type or emitter.module.typeOf(normal) != invocation.result_type)
        return error.InvalidInstruction;

    const is_vector = scalar_type != invocation.result_type;

    const dot = (try emitter.builder.appendInstruction(emitter.block, scalar_type, .{
        .binary = .{
            .opcode = if (is_vector) .dot else .float_multiply,
            .lhs = normal,
            .rhs = incident,
        },
    }, null)).?;

    const doubled = (try emitter.builder.appendInstruction(emitter.block, scalar_type, .{
        .binary = .{ .opcode = .float_add, .lhs = dot, .rhs = dot },
    }, null)).?;

    const scaled_normal = if (is_vector)
        try vector_helper.scale(emitter.builder, emitter.block, invocation.result_type, normal, doubled, null)
    else
        (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
            .binary = .{
                .opcode = .float_multiply,
                .lhs = normal,
                .rhs = doubled,
            },
        }, null)).?;

    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = .float_subtract,
            .lhs = incident,
            .rhs = scaled_normal,
        },
    }, invocation.result_name)).?;
}

fn translateTernary(emitter: *ext.Emitter, invocation: ext.Invocation, opcode: ir.instruction.TernaryOpcode) !ir.id.ValueId {
    if (invocation.operands.len != 3)
        return error.InvalidInstruction;
    const first = invocation.operands[0];
    const second = invocation.operands[1];
    const third = invocation.operands[2];
    if (emitter.module.typeOf(first) != invocation.result_type or
        emitter.module.typeOf(second) != invocation.result_type or
        emitter.module.typeOf(third) != invocation.result_type)
        return error.InvalidInstruction;

    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .ternary = .{
            .opcode = opcode,
            .first = first,
            .second = second,
            .third = third,
        },
    }, invocation.result_name)).?;
}

fn floatScalarType(module: *const ir.module.Module, type_id: ir.id.TypeId) !ir.id.TypeId {
    const definition = module.types.get(type_id) orelse return error.InvalidId;
    const scalar = switch (definition.*) {
        .floating => type_id,
        .vector => |vector| if (vector.length >= 2) vector.element_type else return error.InvalidInstruction,
        else => return error.InvalidInstruction,
    };

    const element = module.types.get(scalar) orelse return error.InvalidId;
    if (element.* != .floating)
        return error.InvalidInstruction;

    switch (element.floating.bits) {
        16, 32, 64 => {},
        else => return error.UnsupportedType,
    }

    return scalar;
}

fn translateDistance(emitter: *ext.Emitter, invocation: ext.Invocation) !ir.id.ValueId {
    if (invocation.operands.len != 2)
        return error.InvalidInstruction;

    const lhs = invocation.operands[0];
    const rhs = invocation.operands[1];
    const operand_type = emitter.module.typeOf(lhs) orelse return error.InvalidId;

    if (emitter.module.typeOf(rhs) != operand_type or try floatScalarType(emitter.module, operand_type) != invocation.result_type)
        return error.InvalidInstruction;

    const difference = (try emitter.builder.appendInstruction(emitter.block, operand_type, .{
        .binary = .{
            .opcode = .float_subtract,
            .lhs = lhs,
            .rhs = rhs,
        },
    }, null)).?;

    return emitLength(emitter, difference, invocation.result_type, invocation.result_name);
}

fn translateLength(emitter: *ext.Emitter, invocation: ext.Invocation) !ir.id.ValueId {
    if (invocation.operands.len != 1)
        return error.InvalidInstruction;
    const operand = invocation.operands[0];
    const operand_type = emitter.module.typeOf(operand) orelse return error.InvalidId;
    if (try floatScalarType(emitter.module, operand_type) != invocation.result_type)
        return error.InvalidInstruction;

    return emitLength(emitter, operand, invocation.result_type, invocation.result_name);
}

fn emitLength(emitter: *ext.Emitter, operand: ir.id.ValueId, result_type: ir.id.TypeId, result_name: ?[]const u8) !ir.id.ValueId {
    if (emitter.module.typeOf(operand) == result_type)
        return (try emitter.builder.appendInstruction(emitter.block, result_type, .{
            .unary = .{
                .opcode = .float_absolute,
                .operand = operand,
            },
        }, result_name)).?;

    const squared = (try emitter.builder.appendInstruction(emitter.block, result_type, .{
        .binary = .{
            .opcode = .dot,
            .lhs = operand,
            .rhs = operand,
        },
    }, null)).?;

    return (try emitter.builder.appendInstruction(emitter.block, result_type, .{
        .unary = .{
            .opcode = .sqrt,
            .operand = squared,
        },
    }, result_name)).?;
}

fn translateNormalize(emitter: *ext.Emitter, invocation: ext.Invocation) !ir.id.ValueId {
    const scalar_type = try validateFloatOperands(emitter, invocation, 1);
    const operand = invocation.operands[0];

    if (scalar_type == invocation.result_type) {
        const magnitude = (try emitter.builder.appendInstruction(emitter.block, scalar_type, .{
            .unary = .{
                .opcode = .float_absolute,
                .operand = operand,
            },
        }, null)).?;
        return (try emitter.builder.appendInstruction(emitter.block, scalar_type, .{
            .binary = .{
                .opcode = .float_divide,
                .lhs = operand,
                .rhs = magnitude,
            },
        }, invocation.result_name)).?;
    }

    const squared = (try emitter.builder.appendInstruction(emitter.block, scalar_type, .{
        .binary = .{
            .opcode = .dot,
            .lhs = operand,
            .rhs = operand,
        },
    }, null)).?;

    const inverse_length = (try emitter.builder.appendInstruction(emitter.block, scalar_type, .{
        .unary = .{
            .opcode = .inverse_sqrt,
            .operand = squared,
        },
    }, null)).?;

    return vector_helper.scale(emitter.builder, emitter.block, invocation.result_type, operand, inverse_length, invocation.result_name);
}

fn translateNClamp(emitter: *ext.Emitter, invocation: ext.Invocation) !ir.id.ValueId {
    if (invocation.operands.len != 3)
        return error.InvalidInstruction;

    const result_definition = emitter.module.types.get(invocation.result_type) orelse return error.InvalidId;
    const vector = switch (result_definition.*) {
        .vector => |value| value,
        else => return error.UnsupportedType,
    };
    const element_definition = emitter.module.types.get(vector.element_type) orelse return error.InvalidId;
    if (element_definition.* != .floating or element_definition.floating.bits != 32)
        return error.UnsupportedType;

    const input = invocation.operands[0];
    const minimum = invocation.operands[1];
    const maximum = invocation.operands[2];
    if (emitter.module.typeOf(input) != invocation.result_type or
        emitter.module.typeOf(minimum) != invocation.result_type or
        emitter.module.typeOf(maximum) != invocation.result_type)
        return error.InvalidInstruction;

    const bool_type = try emitter.builder.internType(.boolean);
    const elements = try emitter.scratch.alloc(ir.id.ValueId, vector.length);
    for (elements, 0..) |*element, index| {
        const indices = &.{@as(u32, @intCast(index))};
        const input_element = (try emitter.builder.appendInstruction(emitter.block, vector.element_type, .{
            .composite_extract = .{
                .composite = input,
                .indices = indices,
            },
        }, null)).?;
        const minimum_element = (try emitter.builder.appendInstruction(emitter.block, vector.element_type, .{
            .composite_extract = .{
                .composite = minimum,
                .indices = indices,
            },
        }, null)).?;
        const maximum_element = (try emitter.builder.appendInstruction(emitter.block, vector.element_type, .{
            .composite_extract = .{
                .composite = maximum,
                .indices = indices,
            },
        }, null)).?;
        const below_minimum = (try emitter.builder.appendInstruction(emitter.block, bool_type, .{
            .compare = .{
                .opcode = .ordered_float_less,
                .lhs = input_element,
                .rhs = minimum_element,
            },
        }, null)).?;
        const lower_clamped = (try emitter.builder.appendInstruction(emitter.block, vector.element_type, .{
            .select = .{
                .condition = below_minimum,
                .true_value = minimum_element,
                .false_value = input_element,
            },
        }, null)).?;
        const above_maximum = (try emitter.builder.appendInstruction(emitter.block, bool_type, .{
            .compare = .{
                .opcode = .ordered_float_less,
                .lhs = maximum_element,
                .rhs = lower_clamped,
            },
        }, null)).?;
        element.* = (try emitter.builder.appendInstruction(emitter.block, vector.element_type, .{
            .select = .{
                .condition = above_maximum,
                .true_value = maximum_element,
                .false_value = lower_clamped,
            },
        }, null)).?;
    }

    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .composite_construct = .{
            .elements = elements,
        },
    }, invocation.result_name)).?;
}
