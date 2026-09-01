const std = @import("std");
const shader_ir = @import("shader_ir").ir;

pub const Layout = struct {
    blocks: []shader_ir.id.BlockId,
    positions: []?usize,

    pub fn empty() Layout {
        return .{ .blocks = &.{}, .positions = &.{} };
    }

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        if (self.blocks.len != 0) allocator.free(self.blocks);
        if (self.positions.len != 0) allocator.free(self.positions);
        self.* = undefined;
    }
};
