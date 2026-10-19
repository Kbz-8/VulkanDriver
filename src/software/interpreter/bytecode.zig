const std = @import("std");

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

pub const MatrixDimensions = struct {
    rows: u8,
    inner: u8,
    columns: u8,

    pub fn encode(self: MatrixDimensions) u32 {
        return @as(u32, self.rows) |
            (@as(u32, self.inner) << 8) |
            (@as(u32, self.columns) << 16);
    }

    pub fn decode(value: u32) MatrixDimensions {
        return .{
            .rows = @truncate(value),
            .inner = @truncate(value >> 8),
            .columns = @truncate(value >> 16),
        };
    }
};

/// Native-endian internal bytecode. It is not a serialized or stable ABI
pub const Instruction = extern struct {
    opcode: Opcode,
    components: u16 = 1,
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
    absolute,
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
    d_pdy,
    discard,
    dot,
    exp,
    exp2,
    float_add,
    float_divide,
    float_max,
    float_min,
    float_mix,
    float_modulo,
    float_multiply,
    float_mul_add,
    float_remainder,
    float_subtract,
    float_to_signed,
    float_to_unsigned,
    floor,
    fwidth,
    image_fetch,
    image_fetch_float,
    image_gather,
    image_read,
    image_read_float,
    image_sample_explicit_lod,
    image_sample_implicit_lod,
    image_write,
    image_write_float,
    int_max,
    int_min,
    integer_add,
    integer_add_carry,
    integer_multiply,
    integer_subtract,
    integer_subtract_borrow,
    is_inf,
    is_nan,
    jump_edge,
    length,
    load_buffer,
    load_push_constant,
    load_workgroup,
    log,
    log2,
    logical_and,
    logical_not,
    logical_or,
    logical_shift_right,
    matrix_times_matrix,
    matrix_times_scalar,
    matrix_times_vector,
    negate_f32,
    negate_i32,
    normalize,
    outer_product,
    pow,
    return_void,
    round,
    select,
    shift_left,
    sign,
    signed_divide,
    signed_modulo,
    signed_multiply_extended,
    signed_to_float,
    sin,
    sinh,
    smooth_step,
    step,
    store_buffer,
    store_workgroup,
    tan,
    tanh,
    transpose,
    unsigned_divide,
    unsigned_modulo,
    unsigned_multiply_extended,
    unsigned_to_float,
    vector_extract_dynamic,
    vector_times_matrix,
    vector_times_scalar,

    pub fn isDerivative(self: Opcode) bool {
        return switch (self) {
            .d_pdx, .d_pdy, .fwidth => true,
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
