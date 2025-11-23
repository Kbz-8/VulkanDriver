const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;
const Device = base.Device;

const Self = @This();
pub const Interface = base.CommandBuffer;

interface: Interface,

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.CommandBufferAllocateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);

    interface.vtable = &.{
        .destroy = destroy,
    };

    interface.dispatch_table = &.{
        .begin = begin,
        .copyBuffer = copyBuffer,
        .end = end,
        .fillBuffer = fillBuffer,
        .reset = reset,
    };

    self.* = .{
        .interface = interface,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn begin(interface: *Interface, info: *const vk.CommandBufferBeginInfo) VkError!void {
    // No-op
    _ = interface;
    _ = info;
}

pub fn end(interface: *Interface) VkError!void {
    // No-op
    _ = interface;
}

pub fn reset(interface: *Interface, flags: vk.CommandBufferResetFlags) VkError!void {
    // No-op
    _ = interface;
    _ = flags;
}

// Commands ====================================================================================================

pub fn fillBuffer(interface: *Interface, buffer: *base.Buffer, offset: vk.DeviceSize, size: vk.DeviceSize, data: u32) VkError!void {
    // No-op
    _ = interface;
    _ = buffer;
    _ = offset;
    _ = size;
    _ = data;
}

pub fn copyBuffer(interface: *Interface, src: *base.Buffer, dst: *base.Buffer, regions: []const vk.BufferCopy) VkError!void {
    // No-op
    _ = interface;
    _ = src;
    _ = dst;
    _ = regions;
}
