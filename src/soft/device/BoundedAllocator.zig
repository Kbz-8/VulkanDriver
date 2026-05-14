const std = @import("std");
const base = @import("base");

const Self = @This();

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

child_allocator: std.mem.Allocator,
bound: usize,
total_bytes_allocated: std.atomic.Value(usize),
peak_concurrent_bytes_allocated: std.atomic.Value(usize),
current_bytes_allocated: std.atomic.Value(usize),

pub fn init(child_allocator: Allocator, bound: usize) Self {
    return .{
        .child_allocator = child_allocator,
        .bound = bound,
        .total_bytes_allocated = std.atomic.Value(usize).init(0),
        .current_bytes_allocated = std.atomic.Value(usize).init(0),
        .peak_concurrent_bytes_allocated = std.atomic.Value(usize).init(0),
    };
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

pub inline fn queryFootprint(self: *Self) usize {
    return self.total_bytes_allocated.load(.monotonic);
}

pub inline fn queryPeakFootprint(self: *Self) usize {
    return self.peak_concurrent_bytes_allocated.load(.monotonic);
}

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.current_bytes_allocated.fetchAdd(len, .monotonic) >= self.bound)
        return null;
    _ = self.total_bytes_allocated.fetchAdd(len, .monotonic);
    if (self.current_bytes_allocated.load(.monotonic) > self.peak_concurrent_bytes_allocated.load(.monotonic))
        self.peak_concurrent_bytes_allocated.store(self.current_bytes_allocated.load(.monotonic), .monotonic);
    return self.child_allocator.rawAlloc(len, alignment, ret_addr);
}

fn resize(context: *anyopaque, ptr: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    _ = self.current_bytes_allocated.fetchSub(ptr.len, .monotonic);
    if (self.current_bytes_allocated.fetchAdd(new_len, .monotonic) >= self.bound)
        return false;
    _ = self.total_bytes_allocated.fetchAdd(new_len, .monotonic);
    return self.child_allocator.rawResize(ptr, alignment, new_len, ret_addr);
}

fn remap(context: *anyopaque, ptr: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    _ = self.current_bytes_allocated.fetchSub(ptr.len, .monotonic);
    if (self.current_bytes_allocated.fetchAdd(new_len, .monotonic) >= self.bound)
        return null;
    _ = self.total_bytes_allocated.fetchAdd(new_len, .monotonic);
    return self.child_allocator.rawRemap(ptr, alignment, new_len, ret_addr);
}

fn free(context: *anyopaque, ptr: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *Self = @ptrCast(@alignCast(context));
    _ = self.current_bytes_allocated.fetchSub(ptr.len, .monotonic);
    return self.child_allocator.rawFree(ptr, alignment, ret_addr);
}
