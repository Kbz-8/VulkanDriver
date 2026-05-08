const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Atomic based spin mutex
const AtomicMutex = struct {
    mutex: std.atomic.Mutex = .unlocked,

    fn lock(self: *@This()) void {
        if (self.mutex.tryLock()) {
            @branchHint(.likely);
            return;
        }

        while (true) {
            if (self.mutex.tryLock()) {
                return;
            }
        }
    }

    fn unlock(self: *@This()) void {
        self.mutex.unlock();
    }
};

var mutex: AtomicMutex = .{};
var child_allocator: std.mem.Allocator = if (builtin.link_libc) std.heap.c_allocator else std.heap.smp_allocator;

pub const fallback_host_allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &vtable,
};

const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn alloc(_: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    mutex.lock();
    defer mutex.unlock();
    return child_allocator.rawAlloc(len, alignment, ret_addr);
}

fn resize(_: *anyopaque, ptr: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    mutex.lock();
    defer mutex.unlock();
    return child_allocator.rawResize(ptr, alignment, new_len, ret_addr);
}

fn remap(_: *anyopaque, ptr: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    mutex.lock();
    defer mutex.unlock();
    return child_allocator.rawRemap(ptr, alignment, new_len, ret_addr);
}

fn free(_: *anyopaque, ptr: []u8, alignment: Alignment, ret_addr: usize) void {
    mutex.lock();
    defer mutex.unlock();
    return child_allocator.rawFree(ptr, alignment, ret_addr);
}
