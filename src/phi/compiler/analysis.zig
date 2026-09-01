const std = @import("std");
const block_layout = @import("block_layout.zig");
const edge_copies = @import("edge_copies.zig");
const liveness = @import("liveness.zig");
const register_allocator = @import("register_allocator.zig");

pub const Analysis = struct {
    layout: block_layout.Layout = block_layout.Layout.empty(),
    liveness: liveness.Analysis = liveness.Analysis.empty(),
    allocation: register_allocator.Allocation = register_allocator.Allocation.empty(),
    edge_copy_plans: []edge_copies.Plan = &.{},

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        self.layout.deinit(allocator);
        self.liveness.deinit(allocator);
        self.allocation.deinit(allocator);
        for (self.edge_copy_plans) |*plan| plan.deinit(allocator);
        if (self.edge_copy_plans.len != 0) allocator.free(self.edge_copy_plans);
        self.* = undefined;
    }
};
