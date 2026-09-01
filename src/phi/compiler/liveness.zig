const std = @import("std");
const shader_ir = @import("shader_ir").ir;

pub const Position = u32;

pub const LiveRange = struct {
    value: shader_ir.id.ValueId,
    first: Position,
    last: Position,
};

pub const Analysis = struct {
    ranges: []LiveRange,
    value_ranges: []?usize,

    pub fn empty() Analysis {
        return .{ .ranges = &.{}, .value_ranges = &.{} };
    }

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        if (self.ranges.len != 0) allocator.free(self.ranges);
        if (self.value_ranges.len != 0) allocator.free(self.value_ranges);
        self.* = undefined;
    }
};
