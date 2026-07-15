const std = @import("std");

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

fn reserve(self: *Self, len: usize) bool {
    while (true) {
        const current = self.current_bytes_allocated.load(.monotonic);
        if (len > self.bound -| current)
            return false;
        const new_current = current + len;
        if (self.current_bytes_allocated.cmpxchgWeak(current, new_current, .monotonic, .monotonic) == null) {
            _ = self.total_bytes_allocated.fetchAdd(len, .monotonic);
            while (true) {
                const peak = self.peak_concurrent_bytes_allocated.load(.monotonic);
                if (new_current <= peak)
                    break;
                if (self.peak_concurrent_bytes_allocated.cmpxchgWeak(peak, new_current, .monotonic, .monotonic) == null)
                    break;
            }
            return true;
        }
    }
}

fn release(self: *Self, len: usize) void {
    while (true) {
        const current = self.current_bytes_allocated.load(.monotonic);
        const new_current = current -| len;
        if (self.current_bytes_allocated.cmpxchgWeak(current, new_current, .monotonic, .monotonic) == null)
            return;
    }
}

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.reserve(len))
        return null;
    return self.child_allocator.rawAlloc(len, alignment, ret_addr) orelse {
        self.release(len);
        return null;
    };
}

fn resize(context: *anyopaque, ptr: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    if (new_len > ptr.len) {
        const delta = new_len - ptr.len;
        if (!self.reserve(delta))
            return false;
        if (self.child_allocator.rawResize(ptr, alignment, new_len, ret_addr))
            return true;
        self.release(delta);
        return false;
    }
    return self.child_allocator.rawResize(ptr, alignment, new_len, ret_addr);
}

fn remap(context: *anyopaque, ptr: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    if (new_len > ptr.len) {
        const delta = new_len - ptr.len;
        if (!self.reserve(delta))
            return null;
        return self.child_allocator.rawRemap(ptr, alignment, new_len, ret_addr) orelse {
            self.release(delta);
            return null;
        };
    }
    return self.child_allocator.rawRemap(ptr, alignment, new_len, ret_addr) orelse null;
}

fn free(context: *anyopaque, ptr: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.release(ptr.len);
    return self.child_allocator.rawFree(ptr, alignment, ret_addr);
}
