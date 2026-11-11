const std = @import("std");
const spirv = @import("spirv.zig");
const ir = @import("../ir/ir.zig");

const Constant = ir.constant.Constant;

const TypeId = ir.id.TypeId;

pub fn operandCount(opcode: spirv.Opcode) !usize {
    return switch (opcode) {
        .s_negate, .not, .logical_not, .u_convert, .s_convert, .f_convert, .quantize_to_f16, .composite_extract => 1,
        .i_add,
        .i_sub,
        .i_mul,
        .u_div,
        .s_div,
        .u_mod,
        .s_rem,
        .s_mod,
        .shift_right_logical,
        .shift_right_arithmetic,
        .shift_left_logical,
        .bitwise_or,
        .bitwise_xor,
        .bitwise_and,
        .logical_equal,
        .logical_not_equal,
        .logical_or,
        .logical_and,
        .i_equal,
        .i_not_equal,
        .u_greater_than,
        .s_greater_than,
        .u_greater_than_equal,
        .s_greater_than_equal,
        .u_less_than,
        .s_less_than,
        .u_less_than_equal,
        .s_less_than_equal,
        .composite_insert,
        .vector_shuffle,
        => 2,
        .select => 3,
        else => error.SpecializationConstantsNotApplied,
    };
}

pub fn fold(
    builder: *ir.Builder,
    scratch: std.mem.Allocator,
    opcode: spirv.Opcode,
    result_type: TypeId,
    operands: []const ir.id.ValueId,
    literals: []const u32,
) !ir.id.ValueId {
    const count = try operandCount(opcode);
    if (operands.len != count)
        return error.InvalidInstruction;
    switch (opcode) {
        .composite_extract, .composite_insert => if (literals.len == 0) return error.InvalidInstruction,
        .vector_shuffle => {},
        else => if (literals.len != 0) return error.InvalidInstruction,
    }

    var evaluator = Evaluator{ .builder = builder, .scratch = scratch };
    var constants: [3]Constant = undefined;
    for (operands, constants[0..count]) |value_id, *constant| {
        const value = (builder.module.values.get(value_id) orelse return error.InvalidId).*;
        constant.* = switch (value.definition) {
            .constant => |id| (builder.module.constants.get(id) orelse return error.InvalidId).*,
            .undef => .{ .type = value.type, .value = .undef },
            else => return error.UnsupportedConstant,
        };
    }
    const result = try evaluator.evaluate(opcode, result_type, constants[0..count], literals);
    return builder.internConstant(result_type, result.value);
}

const Evaluator = struct {
    builder: *ir.Builder,
    scratch: std.mem.Allocator,

    fn typeData(self: *Evaluator, ty: TypeId) !ir.types.Type {
        return (self.builder.module.types.get(ty) orelse return error.InvalidId).*;
    }

    fn intern(self: *Evaluator, constant: Constant) !ir.id.ConstantId {
        const value_id = try self.builder.internConstant(constant.type, constant.value);
        return (self.builder.module.values.get(value_id) orelse return error.InvalidId).definition.constant;
    }

    fn length(self: *Evaluator, ty: TypeId) !usize {
        return switch (try self.typeData(ty)) {
            .vector => |v| v.length,
            .matrix => |m| m.column_count,
            .array => |a| a.length,
            .structure => |s| s.members.len,
            else => error.UnsupportedConstant,
        };
    }

    fn elementType(self: *Evaluator, ty: TypeId, index: usize) !TypeId {
        if (index >= try self.length(ty))
            return error.InvalidInstruction;
        return switch (try self.typeData(ty)) {
            .vector => |v| v.element_type,
            .matrix => |m| m.element_type,
            .array => |a| a.element_type,
            .structure => |s| s.members[index],
            else => unreachable,
        };
    }

    fn element(self: *Evaluator, composite: Constant, index: usize) !Constant {
        const ty = try self.elementType(composite.type, index);
        return switch (composite.value) {
            .composite => |elements| blk: {
                if (elements.len != try self.length(composite.type))
                    return error.InvalidInstruction;
                const child = (self.builder.module.constants.get(elements[index]) orelse return error.InvalidId).*;
                if (child.type != ty)
                    return error.UnsupportedConstant;
                break :blk child;
            },
            .null => .{ .type = ty, .value = .null },
            .undef => .{ .type = ty, .value = .undef },
            else => error.UnsupportedConstant,
        };
    }

    fn insert(self: *Evaluator, composite: Constant, object: Constant, indexes: []const u32) anyerror!Constant {
        if (indexes.len == 0) {
            if (composite.type != object.type)
                return error.UnsupportedConstant;
            return object;
        }
        const index = indexes[0];
        const child = try self.element(composite, index);
        const replacement = try self.insert(child, object, indexes[1..]);
        const elements = try self.scratch.alloc(ir.id.ConstantId, try self.length(composite.type));
        for (elements, 0..) |*element_id, i|
            element_id.* = try self.intern(if (i == index) replacement else try self.element(composite, i));
        return .{ .type = composite.type, .value = .{ .composite = elements } };
    }

    fn evaluate(self: *Evaluator, opcode: spirv.Opcode, ty: TypeId, args: []const Constant, literals: []const u32) anyerror!Constant {
        const result_type = try self.typeData(ty);
        switch (opcode) {
            .composite_extract => {
                var result = args[0];
                for (literals) |index|
                    result = try self.element(result, index);
                if (result.type != ty)
                    return error.UnsupportedConstant;
                return result;
            },
            .composite_insert => {
                if (args[1].type != ty)
                    return error.UnsupportedConstant;
                return self.insert(args[1], args[0], literals);
            },
            .vector_shuffle => {
                if (result_type != .vector or literals.len != result_type.vector.length)
                    return error.InvalidInstruction;
                const left_type = try self.typeData(args[0].type);
                const right_type = try self.typeData(args[1].type);
                if (left_type != .vector or right_type != .vector or
                    left_type.vector.element_type != result_type.vector.element_type or
                    right_type.vector.element_type != result_type.vector.element_type)
                    return error.UnsupportedConstant;
                const left_length = left_type.vector.length;
                const elements = try self.scratch.alloc(ir.id.ConstantId, literals.len);
                for (literals, elements) |selector, *element_id| {
                    const child: Constant = if (selector == std.math.maxInt(u32))
                        .{ .type = result_type.vector.element_type, .value = .undef }
                    else if (selector < left_length)
                        try self.element(args[0], selector)
                    else
                        try self.element(args[1], selector - left_length);
                    element_id.* = try self.intern(child);
                }
                return .{ .type = ty, .value = .{ .composite = elements } };
            },
            .select => {
                if (args[1].type != ty or args[2].type != ty)
                    return error.UnsupportedConstant;
                if (try self.typeData(args[0].type) == .boolean) {
                    if (args[0].value == .undef)
                        return .{ .type = ty, .value = .undef };
                    return if (try boolean(args[0])) args[1] else args[2];
                }
            },
            else => {},
        }

        if (result_type == .vector) {
            const vector = result_type.vector;
            const elements = try self.scratch.alloc(ir.id.ConstantId, vector.length);
            for (elements, 0..) |*element_id, i| {
                var children: [3]Constant = undefined;
                for (args, children[0..args.len]) |arg, *child| {
                    const arg_type = try self.typeData(arg.type);
                    if (arg_type != .vector or arg_type.vector.length != vector.length)
                        return error.UnsupportedConstant;
                    child.* = try self.element(arg, i);
                }
                element_id.* = try self.intern(try self.evaluate(opcode, vector.element_type, children[0..args.len], &.{}));
            }
            return .{ .type = ty, .value = .{ .composite = elements } };
        }

        for (args) |arg| {
            if (arg.value == .undef)
                return .{ .type = ty, .value = .undef };
        }
        if (opcode == .quantize_to_f16) {
            if (result_type != .floating or result_type.floating.bits != 32 or args[0].type != ty)
                return error.UnsupportedConstant;
            const bits: u32 = switch (args[0].value) {
                .float_bits => |bits| @truncate(bits),
                .null => 0,
                else => return error.UnsupportedConstant,
            };

            return .{
                .type = ty,
                .value = .{
                    .float_bits = quantizeToF16(bits),
                },
            };
        }
        if (opcode == .f_convert) {
            const source_type = try self.typeData(args[0].type);
            if (result_type != .floating or source_type != .floating)
                return error.UnsupportedConstant;

            const bits: u64 = switch (args[0].value) {
                .float_bits => |bits| bits,
                .null => 0,
                else => return error.UnsupportedConstant,
            };

            const number: f64 = switch (source_type.floating.bits) {
                16 => @floatCast(@as(f16, @bitCast(@as(u16, @truncate(bits))))),
                32 => @floatCast(@as(f32, @bitCast(@as(u32, @truncate(bits))))),
                64 => @bitCast(bits),
                else => return error.UnsupportedConstant,
            };

            return .{
                .type = ty,
                .value = .{
                    .float_bits = switch (result_type.floating.bits) {
                        16 => @as(u16, @bitCast(@as(f16, @floatCast(number)))),
                        32 => @as(u32, @bitCast(@as(f32, @floatCast(number)))),
                        64 => @as(u64, @bitCast(number)),
                        else => return error.UnsupportedConstant,
                    },
                },
            };
        }
        switch (opcode) {
            .logical_not, .logical_equal, .logical_not_equal, .logical_or, .logical_and => {
                if (result_type != .boolean or try self.typeData(args[0].type) != .boolean)
                    return error.UnsupportedConstant;

                const lhs = try boolean(args[0]);
                const rhs = if (args.len == 2) blk: {
                    if (try self.typeData(args[1].type) != .boolean)
                        return error.UnsupportedConstant;
                    break :blk try boolean(args[1]);
                } else false;

                return .{
                    .type = ty,
                    .value = .{
                        .boolean = switch (opcode) {
                            .logical_not => !lhs,
                            .logical_equal => lhs == rhs,
                            .logical_not_equal => lhs != rhs,
                            .logical_or => lhs or rhs,
                            .logical_and => lhs and rhs,
                            else => unreachable,
                        },
                    },
                };
            },
            else => {},
        }

        const lhs_type = try self.typeData(args[0].type);
        if (lhs_type != .integer)
            return error.UnsupportedConstant;
        const width = lhs_type.integer.bits;
        const lhs = try integer(args[0], width);
        const signed_lhs = signed(lhs, width);
        if (opcode == .s_convert or opcode == .u_convert) {
            if (result_type != .integer)
                return error.UnsupportedConstant;
            return integerResult(ty, result_type.integer.bits, if (opcode == .s_convert) signed_lhs else @as(i128, lhs));
        }

        var rhs: u64 = 0;
        var signed_rhs: i128 = 0;
        const shift = opcode == .shift_left_logical or opcode == .shift_right_logical or opcode == .shift_right_arithmetic;
        if (args.len == 2) {
            const rhs_type = try self.typeData(args[1].type);
            if (rhs_type != .integer or (!shift and args[0].type != args[1].type))
                return error.UnsupportedConstant;
            rhs = try integer(args[1], rhs_type.integer.bits);
            signed_rhs = signed(rhs, rhs_type.integer.bits);
        }

        switch (opcode) {
            .i_equal,
            .i_not_equal,
            .u_greater_than,
            .s_greater_than,
            .u_greater_than_equal,
            .s_greater_than_equal,
            .u_less_than,
            .s_less_than,
            .u_less_than_equal,
            .s_less_than_equal,
            => {
                if (result_type != .boolean)
                    return error.UnsupportedConstant;
                return .{ .type = ty, .value = .{ .boolean = switch (opcode) {
                    .i_equal => lhs == rhs,
                    .i_not_equal => lhs != rhs,
                    .u_greater_than => lhs > rhs,
                    .s_greater_than => signed_lhs > signed_rhs,
                    .u_greater_than_equal => lhs >= rhs,
                    .s_greater_than_equal => signed_lhs >= signed_rhs,
                    .u_less_than => lhs < rhs,
                    .s_less_than => signed_lhs < signed_rhs,
                    .u_less_than_equal => lhs <= rhs,
                    .s_less_than_equal => signed_lhs <= signed_rhs,
                    else => unreachable,
                } } };
            },
            else => {},
        }
        if (result_type != .integer or ty != args[0].type)
            return error.UnsupportedConstant;

        if ((shift and rhs >= width) or ((opcode == .u_div or opcode == .s_div or opcode == .u_mod or opcode == .s_rem or opcode == .s_mod) and rhs == 0))
            return .{ .type = ty, .value = .undef };

        const bits: u64 = switch (opcode) {
            .i_add => lhs +% rhs,
            .i_sub => lhs -% rhs,
            .i_mul => lhs *% rhs,
            .s_negate => 0 -% lhs,
            .not => ~lhs,
            .bitwise_or => lhs | rhs,
            .bitwise_xor => lhs ^ rhs,
            .bitwise_and => lhs & rhs,
            .shift_left_logical => lhs << @intCast(rhs),
            .shift_right_logical => lhs >> @intCast(rhs),
            .shift_right_arithmetic => return integerResult(ty, width, signed_lhs >> @intCast(rhs)),
            .u_div => lhs / rhs,
            .u_mod => lhs % rhs,
            .s_div => return integerResult(ty, width, @divTrunc(signed_lhs, signed_rhs)),
            .s_rem, .s_mod => {
                const divisor = if (signed_rhs < 0) -signed_rhs else signed_rhs;
                var remainder = @rem(signed_lhs, divisor);
                if (opcode == .s_mod and remainder != 0 and (remainder < 0) != (signed_rhs < 0))
                    remainder += signed_rhs;
                return integerResult(ty, width, remainder);
            },
            else => return error.SpecializationConstantsNotApplied,
        };
        return integerResult(ty, width, bits);
    }
};

/// Round f32 to binary16 (nearest, ties to even), flush half subnormals, then widen
fn quantizeToF16(bits: u32) u32 {
    const sign = bits & 0x80000000;
    const magnitude = bits & 0x7fffffff;
    if (magnitude >= 0x7f800000) {
        // Keep infinities and preserve NaNs as NaNs, including tiny payloads
        return if (magnitude == 0x7f800000) bits else bits | 0x00400000;
    }

    if (magnitude < 0x38800000) {
        // Flush after rounding: the midpoint below 2^-14 rounds up to the even
        // smallest normal half. All other half subnormals become signed zero
        return sign | @as(u32, if (magnitude >= 0x387fe000) 0x38800000 else 0);
    }

    // The midpoint above the largest finite half rounds to infinity
    if (magnitude >= 0x477ff000)
        return sign | 0x7f800000;

    // Normal halves retain ten fraction bits, dropping thirteen f32 bits
    const rounded = magnitude + 0x00000fff + ((magnitude >> 13) & 1);
    return sign | (rounded & 0x7fffe000);
}

fn mask(width: u16) !u64 {
    if (width == 0 or width > 64)
        return error.UnsupportedConstant;
    return @as(u64, std.math.maxInt(u64)) >> @intCast(64 - width);
}

fn integer(constant: Constant, width: u16) !u64 {
    const bits = switch (constant.value) {
        .integer_bits => |bits| bits,
        .null => 0,
        else => return error.UnsupportedConstant,
    };
    return bits & try mask(width);
}

fn signed(bits: u64, width: u16) i128 {
    const sign_bit = @as(u64, 1) << @intCast(width - 1);
    return if (bits & sign_bit != 0) @as(i128, bits) - (@as(i128, 1) << @intCast(width)) else bits;
}

fn integerResult(ty: TypeId, width: u16, number: i128) !Constant {
    const bits: u64 = @truncate(@as(u128, @bitCast(number)));
    return .{ .type = ty, .value = .{ .integer_bits = bits & try mask(width) } };
}

fn boolean(constant: Constant) !bool {
    return switch (constant.value) {
        .boolean => |value| value,
        .null => false,
        else => error.UnsupportedConstant,
    };
}
