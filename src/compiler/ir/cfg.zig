const std = @import("std");
const ids = @import("id.zig");
const module_ir = @import("module.zig");

pub const Self = @This();

pub const Error = std.mem.Allocator.Error || error{
    InvalidFunction,
    MissingEntryBlock,
    InvalidBlock,
    MissingTerminator,
    CrossFunctionEdge,
};

allocator: std.mem.Allocator,
blocks: []ids.BlockId,
predecessors_by_block: []std.ArrayList(ids.BlockId),
reachable: []bool,
dominators: []bool,

pub fn init(allocator: std.mem.Allocator, module: *const module_ir.Module, function_id: ids.FunctionId) Error!Self {
    const function = module.functions.get(function_id) orelse return error.InvalidFunction;
    const entry = function.entry_block orelse return error.MissingEntryBlock;
    const blocks = try allocator.dupe(ids.BlockId, function.blocks.items);
    errdefer allocator.free(blocks);

    const predecessor_lists = try allocator.alloc(std.ArrayList(ids.BlockId), blocks.len);
    errdefer allocator.free(predecessor_lists);

    for (predecessor_lists) |*list|
        list.* = .empty;

    errdefer for (predecessor_lists) |*list| list.deinit(allocator);

    const reachable = try allocator.alloc(bool, blocks.len);
    errdefer allocator.free(reachable);
    @memset(reachable, false);

    const dominators = try allocator.alloc(bool, blocks.len * blocks.len);
    errdefer allocator.free(dominators);
    @memset(dominators, false);

    var self: Self = .{
        .allocator = allocator,
        .blocks = blocks,
        .predecessors_by_block = predecessor_lists,
        .reachable = reachable,
        .dominators = dominators,
    };

    try self.buildPredecessors(module);
    try self.buildReachability(module, entry);
    self.buildDominators(entry);

    return self;
}

pub fn deinit(self: *Self) void {
    for (self.predecessors_by_block) |*list|
        list.deinit(self.allocator);

    self.allocator.free(self.predecessors_by_block);
    self.allocator.free(self.blocks);
    self.allocator.free(self.reachable);
    self.allocator.free(self.dominators);
    self.* = undefined;
}

pub fn predecessors(self: *const Self, block: ids.BlockId) ?[]const ids.BlockId {
    const index = self.indexOf(block) orelse return null;
    return self.predecessors_by_block[index].items;
}

pub fn isReachable(self: *const Self, block: ids.BlockId) bool {
    const index = self.indexOf(block) orelse return false;
    return self.reachable[index];
}

pub fn dominates(self: *const Self, dominator: ids.BlockId, block: ids.BlockId) bool {
    const dominator_index = self.indexOf(dominator) orelse return false;
    const block_index = self.indexOf(block) orelse return false;
    return self.dominators[block_index * self.blocks.len + dominator_index];
}

fn buildPredecessors(self: *Self, module: *const module_ir.Module) Error!void {
    for (self.blocks) |source| {
        const block = module.blocks.get(source) orelse return error.InvalidBlock;
        const terminator = block.terminator orelse return error.MissingTerminator;
        switch (terminator) {
            .branch => |edge| try self.addPredecessor(edge.target, source),
            .conditional_branch => |branch| {
                try self.addPredecessor(branch.true_edge.target, source);
                try self.addPredecessor(branch.false_edge.target, source);
            },
            else => {},
        }
    }
}

fn buildReachability(self: *Self, module: *const module_ir.Module, entry: ids.BlockId) Error!void {
    var queue: std.ArrayList(ids.BlockId) = .empty;
    defer queue.deinit(self.allocator);
    try queue.append(self.allocator, entry);
    self.reachable[self.indexOf(entry) orelse return error.InvalidBlock] = true;

    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const block = module.blocks.get(queue.items[cursor]) orelse return error.InvalidBlock;
        const terminator = block.terminator orelse return error.MissingTerminator;
        switch (terminator) {
            .branch => |edge| try self.markReachable(&queue, edge.target),
            .conditional_branch => |branch| {
                try self.markReachable(&queue, branch.true_edge.target);
                try self.markReachable(&queue, branch.false_edge.target);
            },
            else => {},
        }
    }
}

fn buildDominators(self: *Self, entry: ids.BlockId) void {
    const entry_index = self.indexOf(entry).?;
    const count = self.blocks.len;

    for (0..count) |block_index| {
        if (!self.reachable[block_index]) {
            self.setDominates(block_index, block_index, true);
        } else if (block_index == entry_index) {
            self.setDominates(block_index, entry_index, true);
        } else {
            for (0..count) |candidate| {
                if (self.reachable[candidate])
                    self.setDominates(block_index, candidate, true);
            }
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (0..count) |block_index| {
            if (!self.reachable[block_index] or block_index == entry_index)
                continue;

            for (0..count) |candidate| {
                var new_value = candidate == block_index;
                if (!new_value) {
                    var saw_reachable_predecessor = false;
                    new_value = true;
                    for (self.predecessors_by_block[block_index].items) |predecessor| {
                        const predecessor_index = self.indexOf(predecessor).?;

                        if (!self.reachable[predecessor_index])
                            continue;

                        saw_reachable_predecessor = true;
                        new_value = new_value and self.getDominates(predecessor_index, candidate);
                    }
                    new_value = new_value and saw_reachable_predecessor;
                }
                if (self.getDominates(block_index, candidate) != new_value) {
                    self.setDominates(block_index, candidate, new_value);
                    changed = true;
                }
            }
        }
    }
}

fn addPredecessor(self: *Self, target: ids.BlockId, source: ids.BlockId) Error!void {
    const target_index = self.indexOf(target) orelse return error.CrossFunctionEdge;
    try self.predecessors_by_block[target_index].append(self.allocator, source);
}

fn markReachable(self: *Self, queue: *std.ArrayList(ids.BlockId), target: ids.BlockId) Error!void {
    const target_index = self.indexOf(target) orelse return error.CrossFunctionEdge;

    if (self.reachable[target_index])
        return;

    self.reachable[target_index] = true;
    try queue.append(self.allocator, target);
}

fn indexOf(self: *const Self, block: ids.BlockId) ?usize {
    for (self.blocks, 0..) |candidate, index| {
        if (candidate == block) return index;
    }
    return null;
}

fn getDominates(self: *const Self, block_index: usize, candidate_index: usize) bool {
    return self.dominators[block_index * self.blocks.len + candidate_index];
}

fn setDominates(self: *Self, block_index: usize, candidate_index: usize, value: bool) void {
    self.dominators[block_index * self.blocks.len + candidate_index] = value;
}
