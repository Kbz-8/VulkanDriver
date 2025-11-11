//! A Zig allocator from VkAllocationCallbacks.
//! Falls back on c_allocator if callbacks passed are null

const std = @import("std");
const vk = @import("vulkan");
const builtin = @import("builtin");
const DRIVER_DEBUG_ALLOCATOR_ENV_NAME = @import("lib.zig").DRIVER_DEBUG_ALLOCATOR_ENV_NAME;

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Self = @This();

pub var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

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
    if (self.callbacks != null) {
        return .{
            .ptr = @constCast(self),
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    return if (std.process.hasEnvVarConstant(DRIVER_DEBUG_ALLOCATOR_ENV_NAME) or builtin.mode == std.builtin.OptimizeMode.Debug)
        debug_allocator.allocator()
    else
        std.heap.c_allocator;
}

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.callbacks.?.pfn_allocation) |pfn_allocation| {
        return @ptrCast(pfn_allocation(self.callbacks.?.p_user_data, len, alignment.toByteUnits(), self.scope));
    }
    @panic("Null PFN_vkAllocationFunction passed to VkAllocationCallbacks");
}

fn resize(context: *anyopaque, ptr: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
    _ = alignment;
    _ = context;
    return new_len <= ptr.len;
}

fn remap(context: *anyopaque, ptr: []u8, alignment: Alignment, new_len: usize, _: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.callbacks.?.pfn_reallocation) |pfn_reallocation| {
        return @ptrCast(pfn_reallocation(self.callbacks.?.p_user_data, ptr.ptr, new_len, alignment.toByteUnits(), self.scope));
    }
    @panic("Null PFN_vkReallocationFunction passed to VkAllocationCallbacks");
}

fn free(context: *anyopaque, ptr: []u8, alignment: Alignment, _: usize) void {
    _ = alignment;
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.callbacks.?.pfn_free) |pfn_free| {
        return pfn_free(self.callbacks.?.p_user_data, ptr.ptr);
    }
    @panic("Null PFN_vkFreeFunction passed to VkAllocationCallbacks");
}
