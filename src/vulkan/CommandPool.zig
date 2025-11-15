const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const VulkanAllocator = @import("VulkanAllocator.zig");
const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;

const CommandBuffer = @import("CommandBuffer.zig");
const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .command_pool;

pub const BUFFER_POOL_BASE_CAPACITY = 64;

owner: *Device,
flags: vk.CommandPoolCreateFlags,
queue_family_index: u32,
host_allocator: VulkanAllocator,

/// Contiguous dynamic array of command buffers with free ones
/// grouped at the end and the first free index being storesd in
/// `first_free_buffer_index`
/// When freed swaps happen to keep the free buffers at the end
buffers: std.ArrayList(*NonDispatchable(CommandBuffer)),
first_free_buffer_index: usize,

vtable: *const VTable,

pub const VTable = struct {
    allocateCommandBuffers: *const fn (*Self, *const vk.CommandBufferAllocateInfo) VkError!void,
    destroy: *const fn (*Self, std.mem.Allocator) void,
    reset: *const fn (*Self, vk.CommandPoolResetFlags) VkError!void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.CommandPoolCreateInfo) VkError!Self {
    return .{
        .owner = device,
        .flags = info.flags,
        .queue_family_index = info.queue_family_index,
        .host_allocator = VulkanAllocator.from(allocator).clone(),
        .buffers = std.ArrayList(*NonDispatchable(CommandBuffer)).initCapacity(allocator, BUFFER_POOL_BASE_CAPACITY) catch return VkError.OutOfHostMemory,
        .first_free_buffer_index = 0,
        .vtable = undefined,
    };
}

pub fn allocateCommandBuffers(self: *Self, info: *const vk.CommandBufferAllocateInfo) VkError![]*NonDispatchable(CommandBuffer) {
    if (self.buffers.items.len < info.command_buffer_count or self.first_free_buffer_index + info.command_buffer_count > self.buffers.items.len) {
        try self.vtable.allocateCommandBuffers(self, info);
    }

    const bound_up = self.first_free_buffer_index + info.command_buffer_count;
    const slice = self.buffers.items[self.first_free_buffer_index..bound_up];
    self.first_free_buffer_index += info.command_buffer_count;
    return slice;
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    for (self.buffers.items) |non_dis_cmd| {
        non_dis_cmd.object.destroy(allocator);
        non_dis_cmd.destroy(allocator);
    }
    self.buffers.deinit(allocator);
    self.vtable.destroy(self, allocator);
}

pub inline fn reset(self: *Self, flags: vk.CommandPoolResetFlags) VkError!void {
    try self.vtable.reset(self, flags);
}
