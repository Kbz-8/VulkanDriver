const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const NonDispatchable = base.NonDispatchable;
const VkError = base.VkError;
const Device = base.Device;

const SoftCommandBuffer = @import("SoftCommandBuffer.zig");

const Self = @This();
pub const Interface = base.CommandPool;

interface: Interface,

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.CommandPoolCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);

    interface.vtable = &.{
        .allocateCommandBuffers = allocateCommandBuffers,
        .destroy = destroy,
        .reset = reset,
    };

    self.* = .{
        .interface = interface,
    };
    return self;
}

pub fn allocateCommandBuffers(interface: *Interface, info: *const vk.CommandBufferAllocateInfo) VkError!void {
    const allocator = interface.host_allocator.allocator();

    while (interface.buffers.capacity < interface.buffers.items.len + info.command_buffer_count) {
        interface.buffers.ensureUnusedCapacity(allocator, base.CommandPool.BUFFER_POOL_BASE_CAPACITY) catch return VkError.OutOfHostMemory;
    }

    for (0..info.command_buffer_count) |_| {
        const cmd = try SoftCommandBuffer.create(interface.owner, allocator, info);
        const non_dis_cmd = try NonDispatchable(base.CommandBuffer).wrap(allocator, &cmd.interface);
        interface.buffers.appendAssumeCapacity(non_dis_cmd);
    }
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn reset(interface: *Interface, flags: vk.CommandPoolResetFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = self;
    _ = flags;
}
