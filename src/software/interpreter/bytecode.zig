const std = @import("std");

pub const Register = u16;
pub const invalid_register = std.math.maxInt(Register);

pub const ValueKind = enum(u8) {
    boolean,
    signed_integer,
    unsigned_integer,
    floating,
};

pub const Span = struct {
    base: Register,
    components: u8,
    kind: ValueKind,

    pub fn sameShape(a: Span, b: Span) bool {
        return a.components == b.components and a.kind == b.kind;
    }
};

/// Native-endian internal bytecode. It is not a serialized or stable ABI.
pub const Instruction = extern struct {
    opcode: Opcode,
    components: u16 = 1,
    a: Register = invalid_register,
    b: Register = invalid_register,
    c: Register = invalid_register,
    d: Register = invalid_register,
    immediate: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Instruction) == 16);
}

pub const Opcode = enum(u16) {
    copy,
    negate_i32,
    negate_f32,
    logical_not,
    bitwise_not,
    integer_add,
    integer_subtract,
    integer_multiply,
    unsigned_divide,
    signed_divide,
    unsigned_modulo,
    signed_modulo,
    float_add,
    float_subtract,
    float_multiply,
    float_divide,
    float_modulo,
    shift_left,
    logical_shift_right,
    arithmetic_shift_right,
    bitwise_and,
    bitwise_or,
    bitwise_xor,
    logical_and,
    logical_or,
    compare_equal,
    compare_not_equal,
    compare_unsigned_less,
    compare_signed_less,
    compare_ordered_float_equal,
    compare_unordered_float_equal,
    compare_ordered_float_not_equal,
    compare_unordered_float_not_equal,
    compare_ordered_float_less,
    compare_unordered_float_less,
    select,
    load_buffer,
    store_buffer,
    jump_edge,
    branch,
    return_void,
    discard,
    @"unreachable",
};

pub const Copy = struct {
    destination: Register,
    source: Register,
    components: u8,
    scratch_base: Register,
};

pub const Edge = struct {
    target_block: u32,
    target_pc: u32 = 0,
    first_copy: u32,
    copy_count: u16,
};

pub const Branch = struct {
    true_edge: u32,
    false_edge: u32,
};
