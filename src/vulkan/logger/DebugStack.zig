const std = @import("std");

const Self = @This();

pub const Element = struct {
    log: [512]u8,
    indent_level: usize,
    log_level: std.log.Level,
};

stack: std.ArrayList(Element),
allocator: std.mem.Allocator = std.heap.c_allocator,

pub const empty: Self = .{
    .stack = .empty,
};

pub fn pushBack(self: *Self, element: Element) !void {
    try self.stack.append(self.allocator, element);
}

pub fn popBack(self: *Self) ?Element {
    return self.stack.pop();
}

pub fn popFront(self: *Self) Element {
    return self.stack.orderedRemove(0);
}

pub fn getLastOrNull(self: *Self) ?Element {
    return self.stack.getLastOrNull();
}

pub inline fn len(self: *Self) usize {
    return self.stack.items.len;
}

pub fn deinit(self: *Self) void {
    self.stack.deinit(self.allocator);
    self.* = .empty;
}
