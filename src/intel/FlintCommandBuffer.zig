const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const kmd = @import("kmd.zig");

const VkError = base.VkError;
const FlintDevice = @import("FlintDevice.zig");
const FlintDescriptorSet = @import("FlintDescriptorSet.zig");
const FlintPipeline = @import("FlintPipeline.zig");

const MemoryRange = @import("MemoryRange.zig");

const copy = @import("copy_commands.zig");
const blitter = @import("blitter.zig");
const gen9_dispatch = @import("compiler/targets/gen9/compute/dispatch.zig");

const Self = @This();
pub const Interface = base.CommandBuffer;

interface: Interface,
batch: std.ArrayList(u32),
relocations: std.ArrayList(kmd.Relocation),
gpu_allocations: std.ArrayList(kmd.Memory),
engine: ?kmd.Engine,
bound_compute_pipeline: ?*FlintPipeline,
bound_compute_descriptor_sets: [base.vulkan_max_descriptor_sets]?*FlintDescriptorSet,

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
        .gpu_allocations = .empty,
        .engine = null,
        .bound_compute_pipeline = null,
        .bound_compute_descriptor_sets = @splat(null),
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const command_allocator = self.interface.host_allocator.allocator();
    self.releaseGpuAllocations();
    self.batch.deinit(command_allocator);
    self.relocations.deinit(command_allocator);
    self.gpu_allocations.deinit(command_allocator);
    allocator.destroy(self);
}

pub fn submitGpuBatch(self: *Self, syncs: []const kmd.SyncDependency) VkError!void {
    try self.interface.submit();
    defer self.interface.finish() catch @panic("Caught an error while handling an error");

    // Empty command buffers still need a no-op submission to carry queue synchronization.
    const device: *FlintDevice = @alignCast(@fieldParentPtr("interface", self.interface.owner));
    const allocator = self.interface.host_allocator.allocator();
    try device.kmd.submitBatch(self.interface.owner.io(), allocator, self.engine orelse .blitter, self.batch.items, self.relocations.items, syncs);
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
    self.releaseGpuAllocations();
    if (flags.release_resources_bit) {
        const command_allocator = self.interface.host_allocator.allocator();
        self.batch.clearAndFree(command_allocator);
        self.relocations.clearAndFree(command_allocator);
        self.gpu_allocations.clearAndFree(command_allocator);
    } else {
        self.batch.clearRetainingCapacity();
        self.relocations.clearRetainingCapacity();
        self.gpu_allocations.clearRetainingCapacity();
    }
    self.engine = null;
    self.bound_compute_pipeline = null;
    self.bound_compute_descriptor_sets = @splat(null);
}

fn releaseGpuAllocations(self: *Self) void {
    const device: *FlintDevice = @alignCast(@fieldParentPtr("interface", self.interface.owner));
    for (self.gpu_allocations.items) |*allocation|
        allocation.deinit(&device.kmd, self.interface.owner.io());
    self.gpu_allocations.clearRetainingCapacity();
}

pub fn requireEngine(self: *Self, engine: kmd.Engine) VkError!void {
    if (self.engine) |current| {
        if (current != engine)
            return VkError.FeatureNotPresent;
    } else {
        self.engine = engine;
    }
}

pub fn emit(self: *Self, dword: u32) VkError!void {
    self.batch.append(self.interface.host_allocator.allocator(), dword) catch return VkError.OutOfHostMemory;
}

fn emitSlice(self: *Self, words: []const u32) VkError!void {
    self.batch.appendSlice(self.interface.host_allocator.allocator(), words) catch return VkError.OutOfHostMemory;
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
        .domain = if ((self.engine orelse .blitter) == .render) .render else .none,
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

pub fn bindDescriptorSets(interface: *Interface, bind_point: vk.PipelineBindPoint, first_set: u32, sets: [base.vulkan_max_descriptor_sets]?*base.DescriptorSet, dynamic_offsets: []const u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    if (bind_point != .compute)
        return;

    if (dynamic_offsets.len != 0)
        return VkError.FeatureNotPresent;

    if (first_set >= base.vulkan_max_descriptor_sets)
        return VkError.ValidationFailed;

    for (sets, 0..) |set, index| {
        const base_set = set orelse break;
        const destination = first_set + index;

        if (destination >= base.vulkan_max_descriptor_sets)
            return VkError.ValidationFailed;

        self.bound_compute_descriptor_sets[destination] = @alignCast(@fieldParentPtr("interface", base_set));
    }
}

pub fn bindPipeline(interface: *Interface, bind_point: vk.PipelineBindPoint, pipeline: *base.Pipeline) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    if (bind_point != .compute)
        return;

    const flint_pipeline: *FlintPipeline = @alignCast(@fieldParentPtr("interface", pipeline));
    self.bound_compute_pipeline = flint_pipeline;
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
    try dispatchBase(interface, 0, 0, 0, group_count_x, group_count_y, group_count_z);
}

pub fn dispatchBase(interface: *Interface, base_group_x: u32, base_group_y: u32, base_group_z: u32, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    if (group_count_x == 0 or group_count_y == 0 or group_count_z == 0)
        return;
    if (base_group_x != 0 or base_group_y != 0 or base_group_z != 0 or
        group_count_x != 1 or group_count_y != 1 or group_count_z != 1)
        return VkError.FeatureNotPresent;

    const pipeline = self.bound_compute_pipeline orelse return VkError.ValidationFailed;
    const artifact = pipeline.computeArtifact() orelse return VkError.FeatureNotPresent;
    const kernel = artifact.kernel orelse return VkError.FeatureNotPresent;
    if (!std.mem.eql(u32, &artifact.program.workgroup_size, &.{ 1, 1, 1 }) or
        artifact.program.program_data.scratch_size_bytes != 0)
        return VkError.FeatureNotPresent;

    var ranges: [gen9_dispatch.max_surfaces]?MemoryRange = @splat(null);
    var sizes: [gen9_dispatch.max_surfaces]u64 = @splat(0);
    for (artifact.resources.bindings) |resource| {
        if (resource.set >= base.vulkan_max_descriptor_sets or @as(usize, resource.binding_table_index) >= gen9_dispatch.max_storage_surfaces)
            return VkError.ValidationFailed;

        const descriptor_set = self.bound_compute_descriptor_sets[resource.set] orelse return VkError.ValidationFailed;
        const expected_layout = pipeline.interface.layout.set_layouts[resource.set] orelse return VkError.ValidationFailed;
        if (descriptor_set.interface.layout != expected_layout)
            return VkError.ValidationFailed;

        const descriptor = try descriptor_set.getBuffer(resource.binding, 0);
        const buffer = descriptor.buffer orelse return VkError.ValidationFailed;
        if (!buffer.usage.storage_buffer_bit or buffer.memory == null)
            return VkError.ValidationFailed;

        const range = try MemoryRange.fromBuffer(buffer, descriptor.offset, descriptor.size);
        ranges[resource.binding_table_index] = range;
        sizes[resource.binding_table_index] = range.size;
    }

    const old_engine = self.engine;
    try self.requireEngine(.render);
    const old_batch_len = self.batch.items.len;
    const old_relocation_len = self.relocations.items.len;
    const old_allocation_len = self.gpu_allocations.items.len;
    errdefer {
        self.engine = old_engine;
        self.batch.items.len = old_batch_len;
        self.relocations.items.len = old_relocation_len;
        while (self.gpu_allocations.items.len > old_allocation_len) {
            const device: *FlintDevice = @alignCast(@fieldParentPtr("interface", self.interface.owner));
            self.gpu_allocations.items[self.gpu_allocations.items.len - 1].deinit(&device.kmd, self.interface.owner.io());
            self.gpu_allocations.items.len -= 1;
        }
    }

    const device: *FlintDevice = @alignCast(@fieldParentPtr("interface", self.interface.owner));
    var state = try device.kmd.allocateMemory(self.interface.owner.io(), gen9_dispatch.page_size);
    var state_owned = true;
    errdefer if (state_owned) state.deinit(&device.kmd, self.interface.owner.io());

    const mapped = try state.map(&device.kmd, self.interface.owner.io(), 0, gen9_dispatch.page_size);
    const state_layout = gen9_dispatch.writeState(mapped, kernel, sizes[0..artifact.resources.bindings.len]) catch |err| switch (err) {
        error.StateTooLarge,
        error.UnsupportedBufferSize,
        error.EmptyBuffer,
        error.TooManySurfaces,
        => return VkError.FeatureNotPresent,
    };
    state.unmap();
    try state.flushRange(&device.kmd, self.interface.owner.io(), 0, state_layout.size);
    const state_handle = try state.handle();

    self.gpu_allocations.append(self.interface.host_allocator.allocator(), state) catch return VkError.OutOfHostMemory;
    state_owned = false;

    for (0..@as(usize, state_layout.storage_surface_count)) |index| {
        const range = ranges[index] orelse return VkError.ValidationFailed;
        if (range.offset > std.math.maxInt(u32))
            return VkError.FeatureNotPresent;
        self.relocations.append(self.interface.host_allocator.allocator(), .{
            .source_handle = state_handle,
            .target_handle = try range.memory.allocation.handle(),
            .offset = state_layout.surface_address_offsets[index],
            .delta = @intCast(range.offset),
            .read = true,
            .write = true,
            .domain = .render,
        }) catch return VkError.OutOfHostMemory;
    }

    const size_table_surface = @as(usize, state_layout.storage_surface_count);
    self.relocations.append(self.interface.host_allocator.allocator(), .{
        .source_handle = state_handle,
        .target_handle = state_handle,
        .offset = state_layout.surface_address_offsets[size_table_surface],
        .delta = state_layout.size_table_offset,
        .read = true,
        .write = false,
        .domain = .render,
    }) catch return VkError.OutOfHostMemory;

    try self.emitSlice(&gen9_dispatch.pipeControl(gen9_dispatch.pipe_control.cs_stall |
        gen9_dispatch.pipe_control.dc_flush |
        gen9_dispatch.pipe_control.render_target_flush |
        gen9_dispatch.pipe_control.depth_flush));
    try self.emitSlice(&gen9_dispatch.pipeControl(gen9_dispatch.pipe_control.cs_stall |
        gen9_dispatch.pipe_control.texture_invalidate |
        gen9_dispatch.pipe_control.constant_invalidate |
        gen9_dispatch.pipe_control.state_invalidate |
        gen9_dispatch.pipe_control.instruction_invalidate));
    try self.emitSlice(&gen9_dispatch.ccStatePointers);
    try self.emitSlice(&gen9_dispatch.pipelineSelectGpgpu);
    try self.emitSlice(&gen9_dispatch.pipeControl(gen9_dispatch.pipe_control.cs_stall |
        gen9_dispatch.pipe_control.dc_flush |
        gen9_dispatch.pipe_control.render_target_flush));

    const sba_start = self.batch.items.len * @sizeOf(u32);
    try self.emitSlice(&gen9_dispatch.stateBaseAddress());
    inline for (.{
        .{ 4, kmd.Domain.render },
        .{ 6, kmd.Domain.render },
        .{ 10, kmd.Domain.instruction },
    }) |base_address| {
        self.relocations.append(self.interface.host_allocator.allocator(), .{
            .target_handle = state_handle,
            .offset = sba_start + base_address[0] * @sizeOf(u32),
            .delta = gen9_dispatch.base_address_delta,
            .read = true,
            .domain = base_address[1],
        }) catch return VkError.OutOfHostMemory;
    }

    try self.emitSlice(&gen9_dispatch.pipeControl(gen9_dispatch.pipe_control.cs_stall |
        gen9_dispatch.pipe_control.texture_invalidate |
        gen9_dispatch.pipe_control.constant_invalidate |
        gen9_dispatch.pipe_control.state_invalidate |
        gen9_dispatch.pipe_control.instruction_invalidate));
    try self.emitSlice(&gen9_dispatch.pipeControl(gen9_dispatch.pipe_control.cs_stall));
    try self.emitSlice(&gen9_dispatch.mediaVfeState());
    try self.emitSlice(&gen9_dispatch.interfaceDescriptorLoad(state_layout.interface_descriptor_offset));
    try self.emitSlice(&gen9_dispatch.gpgpuWalker(.{ 1, 1, 1 }, 1));
    try self.emitSlice(&gen9_dispatch.mediaStateFlush);
    try self.emitSlice(&gen9_dispatch.pipeControl(gen9_dispatch.pipe_control.cs_stall |
        gen9_dispatch.pipe_control.dc_flush));
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
    if (secondary.gpu_allocations.items.len != 0)
        return VkError.FeatureNotPresent;
    if (secondary.engine) |engine|
        try self.requireEngine(engine);

    const allocator = self.interface.host_allocator.allocator();
    const relocation_offset = self.batch.items.len * @sizeOf(u32);
    self.batch.appendSlice(allocator, secondary.batch.items) catch return VkError.OutOfHostMemory;
    for (secondary.relocations.items) |relocation| {
        self.relocations.append(allocator, .{
            .source_handle = relocation.source_handle,
            .target_handle = relocation.target_handle,
            .offset = relocation.offset + if (relocation.source_handle == null) relocation_offset else 0,
            .delta = relocation.delta,
            .read = relocation.read,
            .write = relocation.write,
            .domain = relocation.domain,
        }) catch return VkError.OutOfHostMemory;
    }
}

pub fn fillBuffer(interface: *Interface, buffer: *base.Buffer, offset: vk.DeviceSize, size: vk.DeviceSize, data: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    try self.requireEngine(.blitter);
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
