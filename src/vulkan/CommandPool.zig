const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const VulkanAllocator = @import("VulkanAllocator.zig");
const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;

const CommandBuffer = @import("CommandBuffer.zig");
const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .command_pool;

/// Base capacity of the command buffer pool.
/// Every increase of the capacity will be by this amount.
pub const BUFFER_POOL_BASE_CAPACITY = 64;

owner: *Device,
flags: vk.CommandPoolCreateFlags,
queue_family_index: u32,
host_allocator: VulkanAllocator,

/// Contiguous dynamic array of command buffers with free ones
/// grouped at the end.
/// When freed swaps happen to keep the free buffers at the end.
buffers: std.ArrayList(*NonDispatchable(CommandBuffer)),

/// Index of the first free command buffer.
first_free_buffer_index: usize,

vtable: *const VTable,

pub const VTable = struct {
    createCommandBuffer: *const fn (*Self, std.mem.Allocator, *const vk.CommandBufferAllocateInfo) VkError!*CommandBuffer,
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
    const allocator = self.host_allocator.allocator();

    if (self.buffers.items.len < self.first_free_buffer_index + info.command_buffer_count) {
        while (self.buffers.capacity < self.buffers.items.len + info.command_buffer_count) {
            self.buffers.ensureUnusedCapacity(allocator, BUFFER_POOL_BASE_CAPACITY) catch return VkError.OutOfHostMemory;
        }
        for (0..info.command_buffer_count) |_| {
            const cmd = try self.vtable.createCommandBuffer(self, allocator, info);
            const non_dis_cmd = try NonDispatchable(CommandBuffer).wrap(allocator, cmd);
            self.buffers.appendAssumeCapacity(non_dis_cmd);
        }
    }

    const bound_up = self.first_free_buffer_index + info.command_buffer_count;
    const slice = self.buffers.items[self.first_free_buffer_index..bound_up];
    self.first_free_buffer_index += info.command_buffer_count;
    return slice;
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
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
