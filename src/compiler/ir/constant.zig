const ids = @import("id.zig");

pub const ConstantId = ids.ConstantId;
pub const TypeId = ids.TypeId;

pub const ConstantValue = union(enum) {
    boolean: bool,
    integer_bits: u64,
    float_bits: u64,
    null,
    undef,
    composite: []const ConstantId,
};

pub const Constant = struct {
    type: TypeId,
    value: ConstantValue,
};
