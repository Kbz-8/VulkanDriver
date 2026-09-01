const registers = @import("registers.zig");

pub const VectorElement = enum {
    i32,
    u32,
    f32,
    i64,
    u64,
    f64,
};

pub const Immediate = union(enum) {
    u8: u8,
    u32: u32,
    i32: i32,
    u64: u64,
};

pub const Memory = struct {
    base: ?registers.Gpr = null,
    index: ?registers.Gpr = null,
    scale: enum(u2) { one, two, four, eight } = .one,
    displacement: i32 = 0,
};

pub const VectorSource = union(enum) {
    register: registers.Zmm,
    memory: Memory,
};

pub const Condition = enum {
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
};
