const std = @import("std");

pub const Slot = u64;

pub const Register = enum(u16) {
    invalid_register = std.math.maxInt(u16),
    _,
};

pub const ValueKind = enum(u8) {
    boolean,
    signed_integer,
    unsigned_integer,
    floating,
    /// Heterogeneous aggregate words; only typed children have a scalar interpretation.
    mixed,
};

pub const Span = struct {
    base: Register,
    components: u8,
    kind: ValueKind,

    pub fn sameShape(a: Span, b: Span) bool {
        return a.components == b.components and a.kind == b.kind;
    }
};

/// Native-endian internal bytecode. It is not a serialized or stable ABI
pub const Instruction = extern struct {
    opcode: Opcode,
    components: u8 = 1,
    scalar_bits: u8 = 32,
    a: Register = .invalid_register,
    b: Register = .invalid_register,
    c: Register = .invalid_register,
    d: Register = .invalid_register,
    immediate: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Instruction) == 16);
}

pub const Opcode = enum(u16) {
    @"unreachable",
    acos,
    acosh,
    all,
    any,
    arithmetic_shift_right,
    array_length,
    asin,
    asinh,
    atan,
    atan2,
    atanh,
    bit_count,
    bit_field_extract_signed,
    bit_field_extract_unsigned,
    bit_field_insert,
    bit_reverse,
    bitwise_and,
    bitwise_not,
    bitwise_or,
    bitwise_xor,
    branch,
    ceil,
    compare_equal,
    compare_not_equal,
    compare_ordered_float_equal,
    compare_ordered_float_less,
    compare_ordered_float_less_equal,
    compare_ordered_float_not_equal,
    compare_signed_less,
    compare_unordered_float_equal,
    compare_unordered_float_less,
    compare_unordered_float_not_equal,
    compare_unsigned_less,
    control_barrier,
    copy,
    cos,
    cosh,
    d_pdx,
    d_pdx_coarse,
    d_pdx_fine,
    d_pdy,
    discard,
    dot,
    exp,
    exp2,
    find_lsb,
    find_s_msb,
    find_u_msb,
    float_absolute,
    float_add,

    float_divide,
    float_max,
    float_min,
    float_modulo,
    float_mul_add,
    float_multiply,
    float_remainder,

    float_subtract,
    float_to_signed,
    float_to_unsigned,
    floor,
    fract,
    fwidth,
    fwidth_coarse,
    fwidth_fine,
    image_fetch,
    image_fetch_float,
    image_gather,
    image_read,
    image_read_float,
    image_sample_explicit_lod,
    image_sample_implicit_lod,
    image_size_query_lod,
    image_write,
    image_write_float,
    integer_absolute,
    integer_add,
    integer_add_carry,
    integer_multiply,

    integer_subtract,
    integer_subtract_borrow,
    inverse_sqrt,
    is_inf,
    is_nan,
    jump_edge,
    ldexp,

    load_buffer,
    load_push_constant,
    load_workgroup,
    log,
    log2,
    logical_and,
    logical_not,
    logical_or,
    logical_shift_right,
    negate_f32,
    negate_i32,

    pow,
    return_void,
    round,
    select,
    shift_left,

    signed_divide,
    signed_max,
    signed_min,
    signed_modulo,
    signed_multiply_extended,
    signed_to_float,
    sin,
    sinh,
    sqrt,
    store_buffer,
    store_workgroup,
    tan,
    tanh,
    trunc,

    unsigned_divide,
    unsigned_max,
    unsigned_min,
    unsigned_modulo,
    unsigned_multiply_extended,
    unsigned_to_float,
    vector_extract_dynamic,

    pub fn isDerivative(self: Opcode) bool {
        return switch (self) {
            .d_pdx,
            .d_pdx_coarse,
            .d_pdx_fine,
            .d_pdy,
            .fwidth,
            .fwidth_coarse,
            .fwidth_fine,
            => true,
            else => false,
        };
    }
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
