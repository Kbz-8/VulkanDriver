//! A Zig allocator from VkAllocationCallbacks.
//! Falls back on c_allocator if callbacks passed are null

const std = @import("std");
const vk = @import("vulkan");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Self = @This();

var fallback_allocator: std.heap.ThreadSafeAllocator = .{ .child_allocator = std.heap.c_allocator };

callbacks: ?vk.AllocationCallbacks,
scope: vk.SystemAllocationScope,

pub fn init(callbacks: ?*const vk.AllocationCallbacks, scope: vk.SystemAllocationScope) Self {
    const deref_callbacks = if (callbacks) |c| c.* else null;
    return .{
        .callbacks = deref_callbacks,
        .scope = scope,
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

pub fn from(a: Allocator) *Self {
    const self: *Self = @ptrCast(@alignCast(a.ptr));
    return self;
}

pub fn clone(self: *Self) Self {
    return self.cloneWithScope(self.scope);
}

pub fn cloneWithScope(self: *Self, scope: vk.SystemAllocationScope) Self {
    return .{
        .callbacks = self.callbacks,
        .scope = scope,
    };
}

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));

    if (self.callbacks) |callbacks| {
        if (callbacks.pfn_allocation) |pfn_allocation| {
            return @ptrCast(pfn_allocation(self.callbacks.?.p_user_data, len, alignment.toByteUnits(), self.scope));
        }
    }

    return getFallbackAllocator().rawAlloc(len, alignment, ret_addr);
}

fn resize(context: *anyopaque, ptr: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    return if (self.callbacks != null)
        new_len <= ptr.len
    else
        getFallbackAllocator().rawResize(ptr, alignment, new_len, ret_addr);
}

fn remap(context: *anyopaque, ptr: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.callbacks) |callbacks| {
        if (callbacks.pfn_reallocation) |pfn_reallocation| {
            return @ptrCast(pfn_reallocation(self.callbacks.?.p_user_data, ptr.ptr, new_len, alignment.toByteUnits(), self.scope));
        }
    }
    return getFallbackAllocator().rawRemap(ptr, alignment, new_len, ret_addr);
}

fn free(context: *anyopaque, ptr: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.callbacks) |callbacks| {
        if (callbacks.pfn_free) |pfn_free| {
            pfn_free(self.callbacks.?.p_user_data, ptr.ptr);
        }
    }
    getFallbackAllocator().rawFree(ptr, alignment, ret_addr);
}

inline fn getFallbackAllocator() std.mem.Allocator {
    return fallback_allocator.allocator();
}
