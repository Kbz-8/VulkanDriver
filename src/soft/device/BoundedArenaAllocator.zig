const std = @import("std");
const base = @import("base");

const Self = @This();

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

mutex: base.SpinMutex,
arena: std.heap.ArenaAllocator,
bound: usize,

pub fn init(child_allocator: Allocator, bound: usize) Self {
    return .{
        .mutex = .{},
        .arena = .init(child_allocator),
        .bound = bound,
    };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn allocator(self: *const Self) Allocator {
    return .{
        .ptr = @ptrCast(@constCast(self)), // Ugly const cast for convenience
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

pub inline fn queryCapacity(self: *Self) usize {
    return self.arena.queryCapacity();
}

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.arena.queryCapacity() >= self.bound)
        return null;
    return self.arena.allocator().rawAlloc(len, alignment, ret_addr);
}

fn resize(context: *anyopaque, ptr: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.arena.queryCapacity() >= self.bound)
        return false;
    return self.arena.allocator().rawResize(ptr, alignment, new_len, ret_addr);
}

fn remap(context: *anyopaque, ptr: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.arena.queryCapacity() >= self.bound)
        return null;
    return self.arena.allocator().rawRemap(ptr, alignment, new_len, ret_addr);
}

fn free(context: *anyopaque, ptr: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.arena.allocator().rawFree(ptr, alignment, ret_addr);
}
