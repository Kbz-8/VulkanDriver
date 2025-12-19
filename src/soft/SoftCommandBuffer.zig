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
        .clearColorImage = clearColorImage,
        .copyBuffer = copyBuffer,
        .copyImage = copyImage,
        .end = end,
        .fillBuffer = fillBuffer,
        .reset = reset,
        .resetEvent = resetEvent,
        .setEvent = setEvent,
        .waitEvents = waitEvents,
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

pub fn clearColorImage(interface: *Interface, image: *base.Image, layout: vk.ImageLayout, color: *const vk.ClearColorValue, range: vk.ImageSubresourceRange) VkError!void {
    // No-op
    _ = interface;
    _ = image;
    _ = layout;
    _ = color;
    _ = range;
}

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

pub fn copyImage(interface: *Interface, src: *base.Image, src_layout: vk.ImageLayout, dst: *base.Image, dst_layout: vk.ImageLayout, regions: []const vk.ImageCopy) VkError!void {
    // No-op
    _ = interface;
    _ = src;
    _ = src_layout;
    _ = dst;
    _ = dst_layout;
    _ = regions;
}

pub fn resetEvent(interface: *Interface, event: *base.Event, stage: vk.PipelineStageFlags) VkError!void {
    // No-op
    _ = interface;
    _ = event;
    _ = stage;
}

pub fn setEvent(interface: *Interface, event: *base.Event, stage: vk.PipelineStageFlags) VkError!void {
    // No-op
    _ = interface;
    _ = event;
    _ = stage;
}

pub fn waitEvents(interface: *Interface, events: []*const base.Event, src_stage: vk.PipelineStageFlags, dst_stage: vk.PipelineStageFlags, memory_barriers: []const vk.MemoryBarrier, buffer_barriers: []const vk.BufferMemoryBarrier, image_barriers: []const vk.ImageMemoryBarrier) VkError!void {
    // No-op
    _ = interface;
    _ = events;
    _ = src_stage;
    _ = dst_stage;
    _ = memory_barriers;
    _ = buffer_barriers;
    _ = image_barriers;
}
