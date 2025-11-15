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
        .createCommandBuffer = createCommandBuffer,
        .destroy = destroy,
        .reset = reset,
    };

    self.* = .{
        .interface = interface,
    };
    return self;
}

pub fn createCommandBuffer(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.CommandBufferAllocateInfo) VkError!*base.CommandBuffer {
    const cmd = try SoftCommandBuffer.create(interface.owner, allocator, info);
    return &cmd.interface;
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
