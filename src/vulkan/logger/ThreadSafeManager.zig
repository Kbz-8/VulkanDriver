const std = @import("std");
const Manager = @import("Manager.zig");

const Self = @This();

managers: std.AutoArrayHashMapUnmanaged(std.Thread.Id, Manager),
allocator: std.heap.ThreadSafeAllocator,
mutex: std.Thread.Mutex,

pub const init: Self = .{
    .managers = .empty,
    .allocator = .{ .child_allocator = std.heap.c_allocator },
    .mutex = .{},
};

pub fn get(self: *Self) *Manager {
    const allocator = self.allocator.allocator();

    self.mutex.lock();
    defer self.mutex.unlock();

    return (self.managers.getOrPutValue(allocator, std.Thread.getCurrentId(), .init) catch @panic("Out of memory")).value_ptr;
}

pub fn deinit(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var it = self.managers.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit();
    }
    self.managers.deinit(self.allocator.allocator());
}
