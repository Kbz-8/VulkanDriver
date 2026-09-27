const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;

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
        .beginQuery = beginQuery,
        .beginRenderPass = beginRenderPass,
        .bindDescriptorSets = bindDescriptorSets,
        .bindPipeline = bindPipeline,
        .bindIndexBuffer = bindIndexBuffer,
        .bindVertexBuffer = bindVertexBuffer,
        .blitImage = blitImage,
        .clearAttachment = clearAttachment,
        .clearColorImage = clearColorImage,
        .clearDepthStencilImage = clearDepthStencilImage,
        .copyBuffer = copyBuffer,
        .copyBufferToImage = copyBufferToImage,
        .copyImage = copyImage,
        .copyImageToBuffer = copyImageToBuffer,
        .copyQueryPoolResults = copyQueryPoolResults,
        .dispatch = dispatch,
        .dispatchBase = dispatchBase,
        .dispatchIndirect = dispatchIndirect,
        .draw = draw,
        .drawIndexed = drawIndexed,
        .drawIndexedIndirect = drawIndexedIndirect,
        .drawIndirect = drawIndirect,
        .end = end,
        .endQuery = endQuery,
        .endRenderPass = endRenderPass,
        .executeCommands = executeCommands,
        .fillBuffer = fillBuffer,
        .nextSubpass = nextSubpass,
        .pipelineBarrier = pipelineBarrier,
        .pushConstants = pushConstants,
        .reset = reset,
        .resetQueryPool = resetQueryPool,
        .resetEvent = resetEvent,
        .resolveImage = resolveImage,
        .setEvent = setEvent,
        .setBlendConstants = setBlendConstants,
        .setDepthBias = setDepthBias,
        .setDepthBounds = setDepthBounds,
        .setDeviceMask = setDeviceMask,
        .setLineWidth = setLineWidth,
        .setScissor = setScissor,
        .setStencilCompareMask = setStencilCompareMask,
        .setStencilReference = setStencilReference,
        .setStencilWriteMask = setStencilWriteMask,
        .setViewport = setViewport,
        .updateBuffer = updateBuffer,
        .waitEvent = waitEvent,
        .writeTimestamp = writeTimestamp,
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

pub fn begin(_: *Interface, _: *const vk.CommandBufferBeginInfo) VkError!void {
    return;
}

pub fn beginQuery(_: *Interface, _: *base.QueryPool, _: u32, _: vk.QueryControlFlags) VkError!void {
    return;
}

pub fn beginRenderPass(_: *Interface, _: *base.RenderPass, _: *base.Framebuffer, _: vk.Rect2D, _: ?[]const vk.ClearValue) VkError!void {
    return;
}

pub fn bindDescriptorSets(_: *Interface, _: vk.PipelineBindPoint, _: u32, _: [base.vulkan_max_descriptor_sets]?*base.DescriptorSet, _: []const u32) VkError!void {
    return;
}

pub fn bindPipeline(_: *Interface, _: vk.PipelineBindPoint, _: *base.Pipeline) VkError!void {
    return;
}

pub fn bindIndexBuffer(_: *Interface, _: *base.Buffer, _: usize, _: vk.IndexType) VkError!void {
    return;
}

pub fn bindVertexBuffer(_: *Interface, _: usize, _: *base.Buffer, _: usize) VkError!void {
    return;
}

pub fn blitImage(_: *Interface, _: *base.Image, _: vk.ImageLayout, _: *base.Image, _: vk.ImageLayout, _: []const vk.ImageBlit, _: vk.Filter) VkError!void {
    return;
}

pub fn clearAttachment(_: *Interface, _: vk.ClearAttachment, _: vk.ClearRect) VkError!void {
    return;
}

pub fn clearColorImage(_: *Interface, _: *base.Image, _: vk.ImageLayout, _: *const vk.ClearColorValue, _: vk.ImageSubresourceRange) VkError!void {
    return;
}

pub fn clearDepthStencilImage(_: *Interface, _: *base.Image, _: vk.ImageLayout, _: *const vk.ClearDepthStencilValue, _: vk.ImageSubresourceRange) VkError!void {
    return;
}

pub fn copyBuffer(_: *Interface, _: *base.Buffer, _: *base.Buffer, _: []const vk.BufferCopy) VkError!void {
    return;
}

pub fn copyBufferToImage(_: *Interface, _: *base.Buffer, _: *base.Image, _: vk.ImageLayout, _: []const vk.BufferImageCopy) VkError!void {
    return;
}

pub fn copyImage(_: *Interface, _: *base.Image, _: vk.ImageLayout, _: *base.Image, _: vk.ImageLayout, _: []const vk.ImageCopy) VkError!void {
    return;
}

pub fn copyImageToBuffer(_: *Interface, _: *base.Image, _: vk.ImageLayout, _: *base.Buffer, _: []const vk.BufferImageCopy) VkError!void {
    return;
}

pub fn copyQueryPoolResults(_: *Interface, _: *base.QueryPool, _: u32, _: u32, _: *base.Buffer, _: vk.DeviceSize, _: vk.DeviceSize, _: vk.QueryResultFlags) VkError!void {
    return;
}

pub fn dispatch(_: *Interface, _: u32, _: u32, _: u32) VkError!void {
    return;
}

pub fn dispatchBase(_: *Interface, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32) VkError!void {
    return;
}

pub fn dispatchIndirect(_: *Interface, _: *base.Buffer, _: vk.DeviceSize) VkError!void {
    return;
}

pub fn draw(_: *Interface, _: usize, _: usize, _: usize, _: usize) VkError!void {
    return;
}

pub fn drawIndexed(_: *Interface, _: usize, _: usize, _: usize, _: i32, _: usize) VkError!void {
    return;
}

pub fn drawIndexedIndirect(_: *Interface, _: *base.Buffer, _: usize, _: usize, _: usize) VkError!void {
    return;
}

pub fn drawIndirect(_: *Interface, _: *base.Buffer, _: usize, _: usize, _: usize) VkError!void {
    return;
}

pub fn end(_: *Interface) VkError!void {
    return;
}

pub fn endQuery(_: *Interface, _: *base.QueryPool, _: u32) VkError!void {
    return;
}

pub fn endRenderPass(_: *Interface) VkError!void {
    return;
}

pub fn executeCommands(_: *Interface, _: *Interface) VkError!void {
    return;
}

pub fn fillBuffer(_: *Interface, _: *base.Buffer, _: vk.DeviceSize, _: vk.DeviceSize, _: u32) VkError!void {
    return;
}

pub fn nextSubpass(_: *Interface, _: vk.SubpassContents) VkError!void {
    return;
}

pub fn pipelineBarrier(_: *Interface, _: vk.PipelineStageFlags, _: vk.PipelineStageFlags, _: vk.DependencyFlags, _: []const vk.MemoryBarrier, _: []const vk.BufferMemoryBarrier, _: []const vk.ImageMemoryBarrier) VkError!void {
    return;
}

pub fn pushConstants(_: *Interface, _: vk.ShaderStageFlags, _: u32, _: []const u8) VkError!void {
    return;
}

pub fn reset(_: *Interface, _: vk.CommandBufferResetFlags) VkError!void {
    return;
}

pub fn resetQueryPool(_: *Interface, _: *base.QueryPool, _: u32, _: u32) VkError!void {
    return;
}

pub fn resetEvent(_: *Interface, _: *base.Event, _: vk.PipelineStageFlags) VkError!void {
    return;
}

pub fn resolveImage(_: *Interface, _: *base.Image, _: vk.ImageLayout, _: *base.Image, _: vk.ImageLayout, _: vk.ImageResolve) VkError!void {
    return;
}

pub fn setEvent(_: *Interface, _: *base.Event, _: vk.PipelineStageFlags) VkError!void {
    return;
}

pub fn setBlendConstants(_: *Interface, _: [4]f32) VkError!void {
    return;
}

pub fn setDepthBias(_: *Interface, _: f32, _: f32, _: f32) VkError!void {
    return;
}

pub fn setDepthBounds(_: *Interface, _: f32, _: f32) VkError!void {
    return;
}

pub fn setDeviceMask(_: *Interface, _: u32) VkError!void {
    return;
}

pub fn setLineWidth(_: *Interface, _: f32) VkError!void {
    return;
}

pub fn setScissor(_: *Interface, _: u32, _: []const vk.Rect2D) VkError!void {
    return;
}

pub fn setStencilCompareMask(_: *Interface, _: vk.StencilFaceFlags, _: u32) VkError!void {
    return;
}

pub fn setStencilReference(_: *Interface, _: vk.StencilFaceFlags, _: u32) VkError!void {
    return;
}

pub fn setStencilWriteMask(_: *Interface, _: vk.StencilFaceFlags, _: u32) VkError!void {
    return;
}

pub fn setViewport(_: *Interface, _: u32, _: []const vk.Viewport) VkError!void {
    return;
}

pub fn updateBuffer(_: *Interface, _: *base.Buffer, _: vk.DeviceSize, _: []const u8) VkError!void {
    return;
}

pub fn waitEvent(_: *Interface, _: *base.Event, _: vk.PipelineStageFlags, _: vk.PipelineStageFlags, _: []const vk.MemoryBarrier, _: []const vk.BufferMemoryBarrier, _: []const vk.ImageMemoryBarrier) VkError!void {
    return;
}

pub fn writeTimestamp(_: *Interface, _: vk.PipelineStageFlags, _: *base.QueryPool, _: u32) VkError!void {
    return;
}
