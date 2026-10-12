const std = @import("std");
const ir = @import("../../ir/ir.zig");

pub const Set = union(enum) {
    glsl_std_450,
    non_semantic: []const u8,
    unsupported: []const u8,
};

pub const Invocation = struct {
    result_type: ir.id.TypeId,
    result_name: ?[]const u8,
    opcode: u32,
    operands: []const ir.id.ValueId,
};

pub const Emitter = struct {
    module: *ir.module.Module,
    builder: *ir.Builder,
    scratch: std.mem.Allocator,
    block: ir.id.BlockId,
};
