const std = @import("std");
const Manager = @import("Manager.zig");

const Self = @This();

managers: std.AutoArrayHashMapUnmanaged(std.Thread.Id, Manager),
allocator: std.mem.Allocator,
mutex: std.Io.Mutex,
io: std.Io,

pub fn init(io: std.Io, allocator: std.mem.Allocator) Self {
    return .{
        .managers = .empty,
        .allocator = allocator,
        .mutex = .init,
        .io = io,
    };
}

pub fn get(self: *Self) *Manager {
    const allocator = self.allocator.allocator();

    self.mutex.lock();
    defer self.mutex.unlock();

    return (self.managers.getOrPutValue(allocator, std.Thread.getCurrentId(), .init) catch @panic("Out of memory")).value_ptr;
}

pub fn deinit(self: *Self) void {
    self.mutex.lockUncancelable();
    defer self.mutex.unlock();

    if (self.managers.getPtr(std.Thread.getCurrentId())) |manager| {
        manager.deinit();
        _ = self.managers.orderedRemove(std.Thread.getCurrentId());
    }
    if (self.managers.count() == 0) {
        self.managers.deinit(self.allocator);
    }
}
