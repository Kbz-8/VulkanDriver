const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const FlintCommandBuffer = @import("FlintCommandBuffer.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Queue;

interface: Interface,

pub fn create(allocator: std.mem.Allocator, device: *base.Device, index: u32, family_index: u32, flags: vk.DeviceQueueCreateFlags) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, device, index, family_index, flags);
    interface.dispatch_table = &.{
        .bindSparse = bindSparse,
        .submit = submit,
        .waitIdle = waitIdle,
    };

    self.* = .{ .interface = interface };
    return &self.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn bindSparse(interface: *Interface, info: []const vk.BindSparseInfo, fence: ?*base.Fence) VkError!void {
    _ = interface;
    _ = info;
    _ = fence;
    return VkError.FeatureNotPresent;
}

pub fn submit(interface: *Interface, infos: []Interface.SubmitInfo, fence: ?*base.Fence) VkError!void {
    _ = interface;
    for (infos) |info| {
        for (info.wait_semaphores.items) |semaphore| {
            try semaphore.wait();
        }

        for (info.command_buffers.items) |command_buffer| {
            const intel_command_buffer: *FlintCommandBuffer = @alignCast(@fieldParentPtr("interface", command_buffer));
            _ = intel_command_buffer;
        }

        for (info.signal_semaphores.items) |semaphore| {
            try semaphore.signal();
        }
    }
    if (fence) |value| {
        try value.signal();
    }
}

pub fn waitIdle(interface: *Interface) VkError!void {
    _ = interface;
}
