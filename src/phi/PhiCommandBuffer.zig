const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("lib.zig");
const proto = lib.proto;

const VkError = base.VkError;
const PhiDeviceMemory = @import("PhiDeviceMemory.zig");

const Self = @This();
pub const Interface = base.CommandBuffer;

interface: Interface,
cmd_count: usize,
serialized_cmd_count: usize,
commands: std.ArrayList(u8),

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.CommandBufferAllocateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);
    interface.vtable = &.{ .destroy = destroy };
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
        .cmd_count = 0,
        .serialized_cmd_count = 0,
        .commands = .empty,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.commands.deinit(allocator);
    allocator.destroy(self);
}

pub fn begin(interface: *Interface, info: *const vk.CommandBufferBeginInfo) VkError!void {
    _ = interface;
    _ = info;
}

pub fn end(interface: *Interface) VkError!void {
    _ = interface;
}

pub fn reset(interface: *Interface, flags: vk.CommandBufferResetFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count = 0;
    self.serialized_cmd_count = 0;
    self.commands.clearRetainingCapacity();
    _ = flags;
}

fn appendCommand(self: *Self, comptime T: type, command_type: c_int, payload: T) VkError!void {
    const allocator = self.interface.host_allocator.allocator();
    const header: proto.PhiCmdHeader = .{
        .magic = proto.PHI_COMMAND_MAGIC,
        .type = @intCast(command_type),
    };
    self.commands.appendSlice(allocator, std.mem.asBytes(&header)) catch return VkError.OutOfHostMemory;
    self.commands.appendSlice(allocator, std.mem.asBytes(&payload)) catch return VkError.OutOfHostMemory;
    self.cmd_count += 1;
    self.serialized_cmd_count += 1;
}

fn remoteMemory(buffer: *base.Buffer) VkError!*PhiDeviceMemory {
    const memory = buffer.memory orelse return VkError.ValidationFailed;
    const phi_memory: *PhiDeviceMemory = @alignCast(@fieldParentPtr("interface", memory));
    if (phi_memory.remote_handle == 0) {
        return VkError.ValidationFailed;
    }
    return phi_memory;
}

pub fn beginQuery(interface: *Interface, pool: *base.QueryPool, query: u32, flags: vk.QueryControlFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = flags;
    try pool.begin(query);
}

pub fn endQuery(interface: *Interface, pool: *base.QueryPool, query: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    try pool.end(query);
}

pub fn resetQueryPool(interface: *Interface, pool: *base.QueryPool, first: u32, count: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    try pool.reset(first, count);
}

pub fn beginRenderPass(interface: *Interface, render_pass: *base.RenderPass, framebuffer: *base.Framebuffer, render_area: vk.Rect2D, clear_values: ?[]const vk.ClearValue) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = render_pass;
    _ = framebuffer;
    _ = render_area;
    _ = clear_values;
}

pub fn bindDescriptorSets(interface: *Interface, bind_point: vk.PipelineBindPoint, first_set: u32, sets: [base.vulkan_max_descriptor_sets]?*base.DescriptorSet, dynamic_offsets: []const u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = bind_point;
    _ = first_set;
    _ = sets;
    _ = dynamic_offsets;
}

pub fn bindPipeline(interface: *Interface, bind_point: vk.PipelineBindPoint, pipeline: *base.Pipeline) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = bind_point;
    _ = pipeline;
}

pub fn bindIndexBuffer(interface: *Interface, buffer: *base.Buffer, offset: usize, index_type: vk.IndexType) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = buffer;
    _ = offset;
    _ = index_type;
}

pub fn bindVertexBuffer(interface: *Interface, index: usize, buffer: *base.Buffer, offset: usize) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = index;
    _ = buffer;
    _ = offset;
}

pub fn blitImage(interface: *Interface, src: *base.Image, src_layout: vk.ImageLayout, dst: *base.Image, dst_layout: vk.ImageLayout, regions: []const vk.ImageBlit, filter: vk.Filter) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = src;
    _ = src_layout;
    _ = dst;
    _ = dst_layout;
    _ = regions;
    _ = filter;
}

pub fn clearAttachment(interface: *Interface, attachment: vk.ClearAttachment, rect: vk.ClearRect) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = attachment;
    _ = rect;
}

pub fn clearColorImage(interface: *Interface, image: *base.Image, layout: vk.ImageLayout, color: *const vk.ClearColorValue, range: vk.ImageSubresourceRange) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = image;
    _ = layout;
    _ = color;
    _ = range;
}

pub fn clearDepthStencilImage(interface: *Interface, image: *base.Image, layout: vk.ImageLayout, value: *const vk.ClearDepthStencilValue, range: vk.ImageSubresourceRange) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = image;
    _ = layout;
    _ = value;
    _ = range;
}

pub fn copyBuffer(interface: *Interface, src: *base.Buffer, dst: *base.Buffer, regions: []const vk.BufferCopy) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const src_memory = try remoteMemory(src);
    const dst_memory = try remoteMemory(dst);

    for (regions) |region| {
        const src_offset, const src_overflow = @addWithOverflow(src.offset, region.src_offset);
        const dst_offset, const dst_overflow = @addWithOverflow(dst.offset, region.dst_offset);
        if (src_overflow != 0 or dst_overflow != 0) {
            return VkError.ValidationFailed;
        }

        try self.appendCommand(proto.PhiCmdCopyBuffer, proto.PHI_CMD_COPY_BUFFER, .{
            .size = region.size,
            .src_memory = @intCast(src_memory.remote_handle),
            .dst_memory = @intCast(dst_memory.remote_handle),
            .src_offset = src_offset,
            .dst_offset = dst_offset,
        });
    }
}

pub fn copyBufferToImage(interface: *Interface, src: *base.Buffer, dst: *base.Image, dst_layout: vk.ImageLayout, regions: []const vk.BufferImageCopy) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = src;
    _ = dst;
    _ = dst_layout;
    _ = regions;
}

pub fn copyImage(interface: *Interface, src: *base.Image, src_layout: vk.ImageLayout, dst: *base.Image, dst_layout: vk.ImageLayout, regions: []const vk.ImageCopy) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = src;
    _ = src_layout;
    _ = dst;
    _ = dst_layout;
    _ = regions;
}

pub fn copyImageToBuffer(interface: *Interface, src: *base.Image, src_layout: vk.ImageLayout, dst: *base.Buffer, regions: []const vk.BufferImageCopy) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = src;
    _ = src_layout;
    _ = dst;
    _ = regions;
}

pub fn copyQueryPoolResults(interface: *Interface, pool: *base.QueryPool, first: u32, count: u32, dst: *base.Buffer, offset: vk.DeviceSize, stride: vk.DeviceSize, flags: vk.QueryResultFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = pool;
    _ = first;
    _ = count;
    _ = dst;
    _ = offset;
    _ = stride;
    _ = flags;
}

pub fn dispatch(interface: *Interface, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = group_count_x;
    _ = group_count_y;
    _ = group_count_z;
}

pub fn dispatchBase(interface: *Interface, base_group_x: u32, base_group_y: u32, base_group_z: u32, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = base_group_x;
    _ = base_group_y;
    _ = base_group_z;
    _ = group_count_x;
    _ = group_count_y;
    _ = group_count_z;
}

pub fn setDeviceMask(interface: *Interface, device_mask: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = device_mask;
}

pub fn dispatchIndirect(interface: *Interface, buffer: *base.Buffer, offset: vk.DeviceSize) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = buffer;
    _ = offset;
}

pub fn draw(interface: *Interface, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = vertex_count;
    _ = instance_count;
    _ = first_vertex;
    _ = first_instance;
}

pub fn drawIndexed(interface: *Interface, index_count: usize, instance_count: usize, first_index: usize, vertex_offset: i32, first_instance: usize) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = index_count;
    _ = instance_count;
    _ = first_index;
    _ = vertex_offset;
    _ = first_instance;
}

pub fn drawIndexedIndirect(interface: *Interface, buffer: *base.Buffer, offset: usize, count: usize, stride: usize) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = buffer;
    _ = offset;
    _ = count;
    _ = stride;
}

pub fn drawIndirect(interface: *Interface, buffer: *base.Buffer, offset: usize, count: usize, stride: usize) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = buffer;
    _ = offset;
    _ = count;
    _ = stride;
}

pub fn endRenderPass(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
}

pub fn executeCommands(interface: *Interface, commands: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = commands;
}

pub fn fillBuffer(interface: *Interface, buffer: *base.Buffer, offset: vk.DeviceSize, size: vk.DeviceSize, data: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;

    const memory = try remoteMemory(buffer);

    try self.appendCommand(proto.PhiCmdFillBuffer, proto.PHI_CMD_FILL_BUFFER, .{
        .size = if (size == vk.WHOLE_SIZE) buffer.size - offset else size,
        .memory = @intCast(memory.remote_handle),
        .offset = offset,
        .data = data,
    });
}

pub fn updateBuffer(interface: *Interface, buffer: *base.Buffer, offset: vk.DeviceSize, data: []const u8) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = buffer;
    _ = offset;
    _ = data;
}

pub fn nextSubpass(interface: *Interface, contents: vk.SubpassContents) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = contents;
}

pub fn pipelineBarrier(interface: *Interface, src_stage: vk.PipelineStageFlags, dst_stage: vk.PipelineStageFlags, dependency: vk.DependencyFlags, memory: []const vk.MemoryBarrier, buffers: []const vk.BufferMemoryBarrier, images: []const vk.ImageMemoryBarrier) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = src_stage;
    _ = dst_stage;
    _ = dependency;
    _ = memory;
    _ = buffers;
    _ = images;
}

pub fn pushConstants(interface: *Interface, stages: vk.ShaderStageFlags, offset: u32, blob: []const u8) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = stages;
    _ = offset;
    _ = blob;
}

pub fn resetEvent(interface: *Interface, event: *base.Event, stage: vk.PipelineStageFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = stage;
    try event.reset();
}

pub fn resolveImage(interface: *Interface, src: *base.Image, src_layout: vk.ImageLayout, dst: *base.Image, dst_layout: vk.ImageLayout, region: vk.ImageResolve) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = src;
    _ = src_layout;
    _ = dst;
    _ = dst_layout;
    _ = region;
}

pub fn setEvent(interface: *Interface, event: *base.Event, stage: vk.PipelineStageFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = stage;
    try event.signal();
}

pub fn setScissor(interface: *Interface, first: u32, scissor: []const vk.Rect2D) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = first;
    _ = scissor;
}

pub fn setViewport(interface: *Interface, first: u32, viewports: []const vk.Viewport) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = first;
    _ = viewports;
}

pub fn setBlendConstants(interface: *Interface, constants: [4]f32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = constants;
}

pub fn setDepthBias(interface: *Interface, constant_factor: f32, clamp: f32, slope_factor: f32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = constant_factor;
    _ = clamp;
    _ = slope_factor;
}

pub fn setDepthBounds(interface: *Interface, min: f32, max: f32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = min;
    _ = max;
}

pub fn setLineWidth(interface: *Interface, width: f32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = width;
}

pub fn setStencilCompareMask(interface: *Interface, face_mask: vk.StencilFaceFlags, compare_mask: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = face_mask;
    _ = compare_mask;
}

pub fn setStencilReference(interface: *Interface, face_mask: vk.StencilFaceFlags, reference: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = face_mask;
    _ = reference;
}

pub fn setStencilWriteMask(interface: *Interface, face_mask: vk.StencilFaceFlags, write_mask: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = face_mask;
    _ = write_mask;
}

pub fn waitEvent(interface: *Interface, event: *base.Event, src_stage: vk.PipelineStageFlags, dst_stage: vk.PipelineStageFlags, memory_barriers: []const vk.MemoryBarrier, buffer_barriers: []const vk.BufferMemoryBarrier, image_barriers: []const vk.ImageMemoryBarrier) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = event;
    _ = src_stage;
    _ = dst_stage;
    _ = memory_barriers;
    _ = buffer_barriers;
    _ = image_barriers;
}

pub fn writeTimestamp(interface: *Interface, stage: vk.PipelineStageFlags, pool: *base.QueryPool, query: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.cmd_count += 1;
    _ = stage;
    try pool.writeTimestamp(query, 0);
}
