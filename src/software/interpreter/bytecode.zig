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
    @"unreachable",
    array_length,
    arithmetic_shift_right,
    bitwise_and,
    bitwise_not,
    bitwise_or,
    bitwise_xor,
    branch,
    compare_equal,
    compare_not_equal,
    compare_ordered_float_equal,
    compare_ordered_float_less,
    compare_ordered_float_not_equal,
    compare_signed_less,
    compare_unordered_float_equal,
    compare_unordered_float_less,
    compare_unordered_float_not_equal,
    compare_unsigned_less,
    copy,
    discard,
    float_add,
    float_divide,
    float_modulo,
    float_multiply,
    vector_times_scalar,
    float_subtract,
    integer_add,
    integer_multiply,
    integer_subtract,
    image_read,
    image_write,
    jump_edge,
    load_buffer,
    load_workgroup,
    logical_and,
    logical_not,
    logical_or,
    logical_shift_right,
    negate_f32,
    negate_i32,
    return_void,
    select,
    shift_left,
    signed_divide,
    signed_modulo,
    store_buffer,
    store_workgroup,
    control_barrier,
    unsigned_divide,
    unsigned_modulo,
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

pub const ArrayLength = struct {
    resource: u32,
    stride: u32,
};
