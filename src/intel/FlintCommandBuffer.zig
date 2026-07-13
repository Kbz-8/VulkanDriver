const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const kmd = @import("kmd.zig");

const VkError = base.VkError;
const FlintDevice = @import("FlintDevice.zig");
const FlintDeviceMemory = @import("FlintDeviceMemory.zig");
const FlintImage = @import("FlintImage.zig");

const MemoryRange = @import("MemoryRange.zig");

const copy = @import("copy_commands.zig");
const blitter = @import("blitter.zig");

const Self = @This();
pub const Interface = base.CommandBuffer;

interface: Interface,
batch: std.ArrayList(u32),
relocations: std.ArrayList(kmd.Relocation),

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
        .batch = .empty,
        .relocations = .empty,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const command_allocator = self.interface.host_allocator.allocator();
    self.batch.deinit(command_allocator);
    self.relocations.deinit(command_allocator);
    allocator.destroy(self);
}

pub fn submitGpuBatch(self: *Self, syncs: []const kmd.SyncDependency) VkError!void {
    try self.interface.submit();
    defer self.interface.finish() catch {};

    if (self.batch.items.len == 0) return;

    const device: *FlintDevice = @alignCast(@fieldParentPtr("interface", self.interface.owner));
    const allocator = self.interface.host_allocator.allocator();
    try device.kmd.submitBatch(self.interface.owner.io(), allocator, self.batch.items, self.relocations.items, syncs);
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
    if (flags.release_resources_bit) {
        const command_allocator = self.interface.host_allocator.allocator();
        self.batch.clearAndFree(command_allocator);
        self.relocations.clearAndFree(command_allocator);
    } else {
        self.batch.clearRetainingCapacity();
        self.relocations.clearRetainingCapacity();
    }
}

pub fn emit(self: *Self, dword: u32) VkError!void {
    self.batch.append(self.interface.host_allocator.allocator(), dword) catch return VkError.OutOfHostMemory;
}

pub fn emitRelocatedAddress(self: *Self, range: MemoryRange, read: bool, write: bool) VkError!void {
    const address_offset = self.batch.items.len * @sizeOf(u32);
    try self.emit(@intCast(range.offset));
    try self.emit(0);
    self.relocations.append(self.interface.host_allocator.allocator(), .{
        .target_handle = try range.memory.allocation.handle(),
        .offset = @intCast(address_offset),
        .delta = @intCast(range.offset),
        .read = read,
        .write = write,
    }) catch return VkError.OutOfHostMemory;
}

pub fn beginQuery(interface: *Interface, pool: *base.QueryPool, query: u32, flags: vk.QueryControlFlags) VkError!void {
    _ = interface;
    _ = flags;
    try pool.begin(query);
}

pub fn endQuery(interface: *Interface, pool: *base.QueryPool, query: u32) VkError!void {
    _ = interface;
    try pool.end(query);
}

pub fn resetQueryPool(interface: *Interface, pool: *base.QueryPool, first: u32, count: u32) VkError!void {
    _ = interface;
    try pool.reset(first, count);
}

pub fn beginRenderPass(interface: *Interface, render_pass: *base.RenderPass, framebuffer: *base.Framebuffer, render_area: vk.Rect2D, clear_values: ?[]const vk.ClearValue) VkError!void {
    _ = interface;
    _ = render_pass;
    _ = framebuffer;
    _ = render_area;
    _ = clear_values;
}

pub fn bindDescriptorSets(interface: *Interface, bind_point: vk.PipelineBindPoint, first_set: u32, sets: [base.VULKAN_MAX_DESCRIPTOR_SETS]?*base.DescriptorSet, dynamic_offsets: []const u32) VkError!void {
    _ = interface;
    _ = bind_point;
    _ = first_set;
    _ = sets;
    _ = dynamic_offsets;
}

pub fn bindPipeline(interface: *Interface, bind_point: vk.PipelineBindPoint, pipeline: *base.Pipeline) VkError!void {
    _ = interface;
    _ = bind_point;
    _ = pipeline;
}

pub fn bindIndexBuffer(interface: *Interface, buffer: *base.Buffer, offset: usize, index_type: vk.IndexType) VkError!void {
    _ = interface;
    _ = buffer;
    _ = offset;
    _ = index_type;
}

pub fn bindVertexBuffer(interface: *Interface, index: usize, buffer: *base.Buffer, offset: usize) VkError!void {
    _ = interface;
    _ = index;
    _ = buffer;
    _ = offset;
}

pub fn blitImage(interface: *Interface, src: *base.Image, src_layout: vk.ImageLayout, dst: *base.Image, dst_layout: vk.ImageLayout, regions: []const vk.ImageBlit, filter: vk.Filter) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = src_layout;
    _ = dst_layout;
    if (filter != .nearest) return VkError.FeatureNotPresent;

    for (regions) |region|
        try blitter.blitImageRegion(self, src, dst, region);
}

pub fn clearAttachment(interface: *Interface, attachment: vk.ClearAttachment, rect: vk.ClearRect) VkError!void {
    _ = interface;
    _ = attachment;
    _ = rect;
}

pub fn clearColorImage(interface: *Interface, image: *base.Image, layout: vk.ImageLayout, color: *const vk.ClearColorValue, range: vk.ImageSubresourceRange) VkError!void {
    _ = interface;
    _ = image;
    _ = layout;
    _ = color;
    _ = range;
}

pub fn clearDepthStencilImage(interface: *Interface, image: *base.Image, layout: vk.ImageLayout, value: *const vk.ClearDepthStencilValue, range: vk.ImageSubresourceRange) VkError!void {
    _ = interface;
    _ = image;
    _ = layout;
    _ = value;
    _ = range;
}

pub fn copyBuffer(interface: *Interface, src: *base.Buffer, dst: *base.Buffer, regions: []const vk.BufferCopy) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    for (regions) |region| {
        const src_range = try copy.copyRangeFromRegion(src, region.src_offset, region.size);
        const dst_range = try copy.copyRangeFromRegion(dst, region.dst_offset, region.size);
        try copy.emitLinearCopy(self, src_range, dst_range);
    }
}

pub fn copyBufferToImage(interface: *Interface, src: *base.Buffer, dst: *base.Image, dst_layout: vk.ImageLayout, regions: []const vk.BufferImageCopy) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = dst_layout;
    for (regions) |region|
        try copy.copyBufferImage(self, src, dst, region, true);
}

pub fn copyImage(interface: *Interface, src: *base.Image, src_layout: vk.ImageLayout, dst: *base.Image, dst_layout: vk.ImageLayout, regions: []const vk.ImageCopy) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = src_layout;
    _ = dst_layout;
    for (regions) |region|
        try copy.copyImage(self, src, dst, region);
}

pub fn copyImageToBuffer(interface: *Interface, src: *base.Image, src_layout: vk.ImageLayout, dst: *base.Buffer, regions: []const vk.BufferImageCopy) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = src_layout;
    for (regions) |region|
        try copy.copyBufferImage(self, dst, src, region, false);
}

pub fn copyQueryPoolResults(interface: *Interface, pool: *base.QueryPool, first: u32, count: u32, dst: *base.Buffer, offset: vk.DeviceSize, stride: vk.DeviceSize, flags: vk.QueryResultFlags) VkError!void {
    _ = interface;
    _ = pool;
    _ = first;
    _ = count;
    _ = dst;
    _ = offset;
    _ = stride;
    _ = flags;
}

pub fn dispatch(interface: *Interface, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    _ = interface;
    _ = group_count_x;
    _ = group_count_y;
    _ = group_count_z;
}

pub fn dispatchBase(interface: *Interface, base_group_x: u32, base_group_y: u32, base_group_z: u32, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    _ = interface;
    _ = base_group_x;
    _ = base_group_y;
    _ = base_group_z;
    _ = group_count_x;
    _ = group_count_y;
    _ = group_count_z;
}

pub fn setDeviceMask(interface: *Interface, device_mask: u32) VkError!void {
    _ = interface;
    _ = device_mask;
}

pub fn dispatchIndirect(interface: *Interface, buffer: *base.Buffer, offset: vk.DeviceSize) VkError!void {
    _ = interface;
    _ = buffer;
    _ = offset;
}

pub fn draw(interface: *Interface, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize) VkError!void {
    _ = interface;
    _ = vertex_count;
    _ = instance_count;
    _ = first_vertex;
    _ = first_instance;
}

pub fn drawIndexed(interface: *Interface, index_count: usize, instance_count: usize, first_index: usize, vertex_offset: i32, first_instance: usize) VkError!void {
    _ = interface;
    _ = index_count;
    _ = instance_count;
    _ = first_index;
    _ = vertex_offset;
    _ = first_instance;
}

pub fn drawIndexedIndirect(interface: *Interface, buffer: *base.Buffer, offset: usize, count: usize, stride: usize) VkError!void {
    _ = interface;
    _ = buffer;
    _ = offset;
    _ = count;
    _ = stride;
}

pub fn drawIndirect(interface: *Interface, buffer: *base.Buffer, offset: usize, count: usize, stride: usize) VkError!void {
    _ = interface;
    _ = buffer;
    _ = offset;
    _ = count;
    _ = stride;
}

pub fn endRenderPass(interface: *Interface) VkError!void {
    _ = interface;
}

pub fn executeCommands(interface: *Interface, commands: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const secondary: *Self = @alignCast(@fieldParentPtr("interface", commands));
    const allocator = self.interface.host_allocator.allocator();
    const relocation_offset = self.batch.items.len * @sizeOf(u32);

    self.batch.appendSlice(allocator, secondary.batch.items) catch return VkError.OutOfHostMemory;
    for (secondary.relocations.items) |relocation| {
        self.relocations.append(allocator, .{
            .target_handle = relocation.target_handle,
            .offset = relocation.offset + relocation_offset,
            .delta = relocation.delta,
            .read = relocation.read,
            .write = relocation.write,
        }) catch return VkError.OutOfHostMemory;
    }
}

pub fn fillBuffer(interface: *Interface, buffer: *base.Buffer, offset: vk.DeviceSize, size: vk.DeviceSize, data: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const dst_range = try copy.fillRange(buffer, offset, size);

    var filled: vk.DeviceSize = 0;
    while (filled < dst_range.size) {
        const dst_chunk: MemoryRange = .{ .memory = dst_range.memory, .offset = dst_range.offset + filled, .size = @sizeOf(u32) };

        try self.emit(kmd.mi_store_data_imm_dword);
        try self.emitRelocatedAddress(dst_chunk, false, true);
        try self.emit(data);

        filled += @sizeOf(u32);
    }
}

pub fn updateBuffer(interface: *Interface, buffer: *base.Buffer, offset: vk.DeviceSize, data: []const u8) VkError!void {
    _ = interface;
    _ = buffer;
    _ = offset;
    _ = data;
}

pub fn nextSubpass(interface: *Interface, contents: vk.SubpassContents) VkError!void {
    _ = interface;
    _ = contents;
}

pub fn pipelineBarrier(interface: *Interface, src_stage: vk.PipelineStageFlags, dst_stage: vk.PipelineStageFlags, dependency: vk.DependencyFlags, memory: []const vk.MemoryBarrier, buffers: []const vk.BufferMemoryBarrier, images: []const vk.ImageMemoryBarrier) VkError!void {
    _ = interface;
    _ = src_stage;
    _ = dst_stage;
    _ = dependency;
    _ = memory;
    _ = buffers;
    _ = images;
}

pub fn pushConstants(interface: *Interface, stages: vk.ShaderStageFlags, offset: u32, blob: []const u8) VkError!void {
    _ = interface;
    _ = stages;
    _ = offset;
    _ = blob;
}

pub fn resetEvent(interface: *Interface, event: *base.Event, stage: vk.PipelineStageFlags) VkError!void {
    _ = interface;
    _ = stage;
    try event.reset();
}

pub fn resolveImage(interface: *Interface, src: *base.Image, src_layout: vk.ImageLayout, dst: *base.Image, dst_layout: vk.ImageLayout, region: vk.ImageResolve) VkError!void {
    _ = interface;
    _ = src;
    _ = src_layout;
    _ = dst;
    _ = dst_layout;
    _ = region;
}

pub fn setEvent(interface: *Interface, event: *base.Event, stage: vk.PipelineStageFlags) VkError!void {
    _ = interface;
    _ = stage;
    try event.signal();
}

pub fn setScissor(interface: *Interface, first: u32, scissor: []const vk.Rect2D) VkError!void {
    _ = interface;
    _ = first;
    _ = scissor;
}

pub fn setViewport(interface: *Interface, first: u32, viewports: []const vk.Viewport) VkError!void {
    _ = interface;
    _ = first;
    _ = viewports;
}

pub fn setBlendConstants(interface: *Interface, constants: [4]f32) VkError!void {
    _ = interface;
    _ = constants;
}

pub fn setDepthBias(interface: *Interface, constant_factor: f32, clamp: f32, slope_factor: f32) VkError!void {
    _ = interface;
    _ = constant_factor;
    _ = clamp;
    _ = slope_factor;
}

pub fn setDepthBounds(interface: *Interface, min: f32, max: f32) VkError!void {
    _ = interface;
    _ = min;
    _ = max;
}

pub fn setLineWidth(interface: *Interface, width: f32) VkError!void {
    _ = interface;
    _ = width;
}

pub fn setStencilCompareMask(interface: *Interface, face_mask: vk.StencilFaceFlags, compare_mask: u32) VkError!void {
    _ = interface;
    _ = face_mask;
    _ = compare_mask;
}

pub fn setStencilReference(interface: *Interface, face_mask: vk.StencilFaceFlags, reference: u32) VkError!void {
    _ = interface;
    _ = face_mask;
    _ = reference;
}

pub fn setStencilWriteMask(interface: *Interface, face_mask: vk.StencilFaceFlags, write_mask: u32) VkError!void {
    _ = interface;
    _ = face_mask;
    _ = write_mask;
}

pub fn waitEvent(interface: *Interface, event: *base.Event, src_stage: vk.PipelineStageFlags, dst_stage: vk.PipelineStageFlags, memory_barriers: []const vk.MemoryBarrier, buffer_barriers: []const vk.BufferMemoryBarrier, image_barriers: []const vk.ImageMemoryBarrier) VkError!void {
    _ = interface;
    _ = event;
    _ = src_stage;
    _ = dst_stage;
    _ = memory_barriers;
    _ = buffer_barriers;
    _ = image_barriers;
}

pub fn writeTimestamp(interface: *Interface, stage: vk.PipelineStageFlags, pool: *base.QueryPool, query: u32) VkError!void {
    _ = interface;
    _ = stage;
    try pool.writeTimestamp(query, 0);
}
