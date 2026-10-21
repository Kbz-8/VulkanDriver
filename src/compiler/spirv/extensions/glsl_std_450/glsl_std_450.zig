const std = @import("std");
const ir = @import("../../../ir/ir.zig");
const ext = @import("../types.zig");

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
        .degrees => translateUnary(emitter, invocation, .degrees),
        .exp => translateUnary(emitter, invocation, .exp),
        .exp2 => translateUnary(emitter, invocation, .exp2),
        .f_abs => translateUnary(emitter, invocation, .float_absolute),
        .f_clamp => translateFClamp(emitter, invocation),
        .f_max => translateBinary(emitter, invocation, .float_max),
        .f_min => translateBinary(emitter, invocation, .float_min),
        .f_mix => translateTernary(emitter, invocation, .float_mix),
        .f_sign => translateUnary(emitter, invocation, .float_sign),
        .floor => translateUnary(emitter, invocation, .floor),
        .fma => translateTernary(emitter, invocation, .float_mul_add),
        .fract => translateUnary(emitter, invocation, .fract),
        .length => translateLength(emitter, invocation),
        .log => translateUnary(emitter, invocation, .log),
        .log2 => translateUnary(emitter, invocation, .log2),
        .n_clamp => translateNClamp(emitter, invocation),
        .normalize => translateUnary(emitter, invocation, .normalize),
        .pow => translateBinary(emitter, invocation, .pow),
        .radians => translateUnary(emitter, invocation, .radians),
        .reflect => translateReflect(emitter, invocation),
        .round => translateUnary(emitter, invocation, .round),
        .s_abs => translateUnary(emitter, invocation, .integer_absolute),
        .s_sign => translateUnary(emitter, invocation, .integer_sign),
        .sin => translateUnary(emitter, invocation, .sin),
        .sinh => translateUnary(emitter, invocation, .sinh),
        .smooth_step => translateTernary(emitter, invocation, .smooth_step),
        .sqrt => translateUnary(emitter, invocation, .sqrt),
        .step => translateBinary(emitter, invocation, .step),
        .tan => translateUnary(emitter, invocation, .tan),
        .tanh => translateUnary(emitter, invocation, .tanh),
        .trunc => translateUnary(emitter, invocation, .trunc),
        .u_max => translateBinary(emitter, invocation, .unsigned_max),
        .u_min => translateBinary(emitter, invocation, .unsigned_min),

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
    if (emitter.module.typeOf(operand) != invocation.result_type)
        return error.InvalidInstruction;

    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .unary = .{
            .opcode = opcode,
            .operand = operand,
        },
    }, invocation.result_name)).?;
}

fn translateBinary(emitter: *ext.Emitter, invocation: ext.Invocation, opcode: ir.instruction.BinaryOpcode) !ir.id.ValueId {
    if (invocation.operands.len != 2)
        return error.InvalidInstruction;
    const lhs = invocation.operands[0];
    const rhs = invocation.operands[1];
    if (emitter.module.typeOf(lhs) != invocation.result_type or emitter.module.typeOf(rhs) != invocation.result_type)
        return error.InvalidInstruction;

    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = opcode,
            .lhs = lhs,
            .rhs = rhs,
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

    const scaled_normal = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{
            .opcode = if (is_vector) .vector_times_scalar else .float_multiply,
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
        .vector => |vector| vector.element_type,
        else => return error.InvalidInstruction,
    };
    const element = module.types.get(scalar) orelse return error.InvalidId;
    if (element.* != .floating)
        return error.InvalidInstruction;
    return scalar;
}

fn translateLength(emitter: *ext.Emitter, invocation: ext.Invocation) !ir.id.ValueId {
    if (invocation.operands.len != 1)
        return error.InvalidInstruction;
    const operand = invocation.operands[0];
    const operand_type = emitter.module.typeOf(operand) orelse return error.InvalidId;
    if (try floatScalarType(emitter.module, operand_type) != invocation.result_type)
        return error.InvalidInstruction;
    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .unary = .{ .opcode = .length, .operand = operand },
    }, invocation.result_name)).?;
}

fn translateFClamp(emitter: *ext.Emitter, invocation: ext.Invocation) !ir.id.ValueId {
    if (invocation.operands.len != 3)
        return error.InvalidInstruction;
    _ = try floatScalarType(emitter.module, invocation.result_type);
    for (invocation.operands) |operand| {
        if (emitter.module.typeOf(operand) != invocation.result_type)
            return error.InvalidInstruction;
    }
    const lower = (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{ .opcode = .float_max, .lhs = invocation.operands[0], .rhs = invocation.operands[1] },
    }, null)).?;
    return (try emitter.builder.appendInstruction(emitter.block, invocation.result_type, .{
        .binary = .{ .opcode = .float_min, .lhs = lower, .rhs = invocation.operands[2] },
    }, invocation.result_name)).?;
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
