const std = @import("std");
const shader_ir = @import("shader_ir").ir;
const registers = @import("imci/registers.zig");

pub const StackSlot = struct {
    offset: u32,
    size: u32,
    alignment: u32,
};

pub const VectorComponent = struct {
    chunks: []const registers.Zmm,
};

pub const VectorLocation = struct {
    components: []const VectorComponent,
};

pub const Immediate = union(enum) {
    integer: u64,
    float: u64,
};

pub const Location = union(enum) {
    immediate: Immediate,
    vector: VectorLocation,
    mask: registers.Mask,
    stack: StackSlot,
};

pub const Constraints = struct {
    temporary_vectors: u8 = 0,
    temporary_masks: u8 = 0,
    temporary_gprs: u8 = 0,
};

pub const Allocation = struct {
    value_locations: []?Location,
    stack_size: u32,
    scratch_vector: ?registers.Zmm,
    scratch_mask: ?registers.Mask,

    pub fn empty() Allocation {
        return .{
            .value_locations = &.{},
            .stack_size = 0,
            .scratch_vector = null,
            .scratch_mask = null,
        };
    }

    pub fn location(self: *const Allocation, value: shader_ir.id.ValueId) ?Location {
        if (value.index() >= self.value_locations.len) return null;
        return self.value_locations[value.index()];
    }

    pub fn deinit(self: *Allocation, allocator: std.mem.Allocator) void {
        if (self.value_locations.len != 0) allocator.free(self.value_locations);
        self.* = undefined;
    }
};
