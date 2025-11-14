const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const VulkanAllocator = @import("VulkanAllocator.zig");
const CommandBuffer = @import("CommandBuffer.zig");
const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .command_pool;

const BUFFER_POOL_BASE_CAPACITY = 64;

owner: *Device,
flags: vk.CommandPoolCreateFlags,
queue_family_index: u32,
buffers: std.ArrayList(*CommandBuffer),
first_free_buffer_index: usize,
host_allocator: VulkanAllocator,

vtable: *const VTable,

pub const VTable = struct {
    allocateCommandBuffers: *const fn (*Self, *const vk.CommandBufferAllocateInfo) VkError![]*CommandBuffer,
    destroy: *const fn (*Self, std.mem.Allocator) void,
    reset: *const fn (*Self, vk.CommandPoolResetFlags) VkError!void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.CommandPoolCreateInfo) VkError!Self {
    return .{
        .owner = device,
        .flags = info.flags,
        .queue_family_index = info.queue_family_index,
        .buffers = std.ArrayList(*CommandBuffer).initCapacity(allocator, BUFFER_POOL_BASE_CAPACITY) catch return VkError.OutOfHostMemory,
        .host_allocator = VulkanAllocator.from(allocator).clone(),
        .first_free_buffer_index = 0,
        .vtable = undefined,
    };
}

pub inline fn allocateCommandBuffers(self: *Self, info: *const vk.CommandBufferAllocateInfo) VkError![]*CommandBuffer {
    return self.vtable.allocateCommandBuffers(self, info);
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.buffers.deinit(allocator);
    self.vtable.destroy(self, allocator);
}

pub inline fn reset(self: *Self, flags: vk.CommandPoolResetFlags) VkError!void {
    try self.vtable.reset(self, flags);
}
