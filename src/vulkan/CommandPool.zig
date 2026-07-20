const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const VulkanAllocator = @import("VulkanAllocator.zig");
const Dispatchable = @import("Dispatchable.zig").Dispatchable;

const CommandBuffer = @import("CommandBuffer.zig");
const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .command_pool;

/// Base capacity of the command buffer pool.
/// Every increase of the capacity will be by this amount.
pub const buffer_pool_base_capacity = 64;

owner: *Device,
flags: vk.CommandPoolCreateFlags,
queue_family_index: u32,
host_allocator: VulkanAllocator,

/// Contiguous dynamic array of command buffers with free ones
/// grouped at the end.
/// When freed swaps happen to keep the free buffers at the end.
buffers: std.ArrayList(*Dispatchable(CommandBuffer)),

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
        .buffers = std.ArrayList(*Dispatchable(CommandBuffer)).initCapacity(allocator, buffer_pool_base_capacity) catch return VkError.OutOfHostMemory,
        .first_free_buffer_index = 0,
        // SAFETY: the backend assigns the vtable before returning the command pool.
        .vtable = undefined,
    };
}

pub fn allocateCommandBuffers(self: *Self, info: *const vk.CommandBufferAllocateInfo) VkError![]*Dispatchable(CommandBuffer) {
    const allocator = self.host_allocator.allocator();

    if (self.buffers.items.len < self.first_free_buffer_index + info.command_buffer_count) {
        while (self.buffers.capacity < self.buffers.items.len + info.command_buffer_count) {
            self.buffers.ensureUnusedCapacity(allocator, buffer_pool_base_capacity) catch return VkError.OutOfHostMemory;
        }
        const original_len = self.buffers.items.len;
        errdefer {
            for (self.buffers.items[original_len..]) |dis_cmd| {
                dis_cmd.intrusiveDestroy(allocator);
            }
            self.buffers.shrinkRetainingCapacity(original_len);
        }
        for (0..info.command_buffer_count) |_| {
            const cmd = try self.vtable.createCommandBuffer(self, allocator, info);
            var cmd_owned = true;
            errdefer if (cmd_owned) cmd.destroy(allocator);
            const dis_cmd = try Dispatchable(CommandBuffer).wrap(allocator, cmd);
            cmd_owned = false;
            var dis_cmd_owned = true;
            errdefer if (dis_cmd_owned) dis_cmd.intrusiveDestroy(allocator);
            self.buffers.appendAssumeCapacity(dis_cmd);
            dis_cmd_owned = false;
        }
    }

    const bound_up = self.first_free_buffer_index + info.command_buffer_count;
    const slice = self.buffers.items[self.first_free_buffer_index..bound_up];
    self.first_free_buffer_index += info.command_buffer_count;
    return slice;
}

pub fn freeCommandBuffers(self: *Self, cmds: []*Dispatchable(CommandBuffer)) VkError!void {
    // Ugly method but it works well
    var len: usize = 0;
    for (cmds) |cmd| {
        if (std.mem.indexOfScalar(*Dispatchable(CommandBuffer), self.buffers.items, cmd)) |i| {
            try cmd.object.resetFromPool(.{ .release_resources_bit = true });
            const save = self.buffers.orderedRemove(i);
            self.buffers.appendAssumeCapacity(save);
            len += 1;
        }
    }
    const new_first_free_buffer_index, const has_overflown = @subWithOverflow(self.first_free_buffer_index, len);
    if (has_overflown == 0) {
        self.first_free_buffer_index = new_first_free_buffer_index;
    }
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    for (self.buffers.items) |dis_cmd| {
        dis_cmd.intrusiveDestroy(allocator);
    }
    self.buffers.deinit(allocator);
    self.vtable.destroy(self, allocator);
}

pub fn reset(self: *Self, flags: vk.CommandPoolResetFlags) VkError!void {
    try self.vtable.reset(self, flags);

    self.first_free_buffer_index = 0;

    for (self.buffers.items) |dis_cmd| {
        _ = dis_cmd.object.resetFromPool(.{ .release_resources_bit = flags.release_resources_bit }) catch @panic("Caught an error while handling an error");
    }
}
