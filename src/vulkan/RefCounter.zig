const std = @import("std");

const Self = @This();

count: std.atomic.Value(usize),

pub const init: Self = .{ .count = std.atomic.Value(usize).init(0) };

pub inline fn ref(self: *Self) void {
    _ = self.count.fetchAdd(1, .monotonic);
}

pub inline fn unref(self: *Self) void {
    _ = self.count.fetchSub(1, .monotonic);
}

pub inline fn hasRefs(self: *Self) bool {
    return self.getRefsCount() == 0;
}

pub inline fn getRefsCount(self: *Self) usize {
    return self.count.load(.acquire);
}
