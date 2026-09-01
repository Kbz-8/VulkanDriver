const std = @import("std");
const shader_ir = @import("shader_ir").ir;

pub const Copy = struct {
    source: shader_ir.id.ValueId,
    destination: shader_ir.id.ValueId,
};

pub const Plan = struct {
    predecessor: shader_ir.id.BlockId,
    successor: shader_ir.id.BlockId,
    copies: []Copy,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.copies);
        self.* = undefined;
    }
};
