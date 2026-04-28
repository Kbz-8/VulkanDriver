const std = @import("std");
const vk = @import("vulkan");
const lib = @import("lib.zig");

const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;
const VkError = @import("error_set.zig").VkError;
const VulkanAllocator = @import("VulkanAllocator.zig");

const Buffer = @import("Buffer.zig");
const CommandPool = @import("CommandPool.zig");
const DescriptorSet = @import("DescriptorSet.zig");
const Device = @import("Device.zig");
const Event = @import("Event.zig");
const Framebuffer = @import("Framebuffer.zig");
const Image = @import("Image.zig");
const Pipeline = @import("Pipeline.zig");
const RenderPass = @import("RenderPass.zig");

const State = enum {
    Initial,
    Recording,
    Executable,
    Pending,
    Invalid,
};

const Self = @This();
pub const ObjectType: vk.ObjectType = .command_buffer;

owner: *Device,
pool: *CommandPool,
state: State,
begin_info: ?vk.CommandBufferBeginInfo,
host_allocator: VulkanAllocator,
state_mutex: std.Io.Mutex,

vtable: *const VTable,
dispatch_table: *const DispatchTable,

pub const DispatchTable = struct {
    begin: *const fn (*Self, *const vk.CommandBufferBeginInfo) VkError!void,
    beginRenderPass: *const fn (*Self, *RenderPass, *Framebuffer, vk.Rect2D, ?[]const vk.ClearValue) VkError!void,
    bindDescriptorSets: *const fn (*Self, vk.PipelineBindPoint, u32, [lib.VULKAN_MAX_DESCRIPTOR_SETS]?*DescriptorSet, []const u32) VkError!void,
    bindPipeline: *const fn (*Self, vk.PipelineBindPoint, *Pipeline) VkError!void,
    bindVertexBuffer: *const fn (*Self, usize, *Buffer, usize) VkError!void,
    blitImage: *const fn (*Self, *Image, vk.ImageLayout, *Image, vk.ImageLayout, []const vk.ImageBlit, vk.Filter) VkError!void,
    clearAttachment: *const fn (*Self, vk.ClearAttachment, vk.ClearRect) VkError!void,
    clearColorImage: *const fn (*Self, *Image, vk.ImageLayout, *const vk.ClearColorValue, vk.ImageSubresourceRange) VkError!void,
    copyBuffer: *const fn (*Self, *Buffer, *Buffer, []const vk.BufferCopy) VkError!void,
    copyBufferToImage: *const fn (*Self, *Buffer, *Image, vk.ImageLayout, []const vk.BufferImageCopy) VkError!void,
    copyImage: *const fn (*Self, *Image, vk.ImageLayout, *Image, vk.ImageLayout, []const vk.ImageCopy) VkError!void,
    copyImageToBuffer: *const fn (*Self, *Image, vk.ImageLayout, *Buffer, []const vk.BufferImageCopy) VkError!void,
    dispatch: *const fn (*Self, u32, u32, u32) VkError!void,
    dispatchIndirect: *const fn (*Self, *Buffer, vk.DeviceSize) VkError!void,
    draw: *const fn (*Self, usize, usize, usize, usize) VkError!void,
    end: *const fn (*Self) VkError!void,
    endRenderPass: *const fn (*Self) VkError!void,
    executeCommands: *const fn (*Self, *Self) VkError!void,
    fillBuffer: *const fn (*Self, *Buffer, vk.DeviceSize, vk.DeviceSize, u32) VkError!void,
    pipelineBarrier: *const fn (*Self, vk.PipelineStageFlags, vk.PipelineStageFlags, vk.DependencyFlags, []const vk.MemoryBarrier, []const vk.BufferMemoryBarrier, []const vk.ImageMemoryBarrier) VkError!void,
    reset: *const fn (*Self, vk.CommandBufferResetFlags) VkError!void,
    resetEvent: *const fn (*Self, *Event, vk.PipelineStageFlags) VkError!void,
    setEvent: *const fn (*Self, *Event, vk.PipelineStageFlags) VkError!void,
    setViewport: *const fn (*Self, u32, []const vk.Viewport) VkError!void,
    waitEvent: *const fn (*Self, *Event, vk.PipelineStageFlags, vk.PipelineStageFlags, []const vk.MemoryBarrier, []const vk.BufferMemoryBarrier, []const vk.ImageMemoryBarrier) VkError!void,
};

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.CommandBufferAllocateInfo) VkError!Self {
    return .{
        .owner = device,
        .pool = try NonDispatchable(CommandPool).fromHandleObject(info.command_pool),
        .state = .Initial,
        .begin_info = null,
        .host_allocator = VulkanAllocator.from(allocator).cloneWithScope(.object),
        .state_mutex = .init,
        .vtable = undefined,
        .dispatch_table = undefined,
    };
}

inline fn transitionState(self: *Self, target: State, from_allowed: []const State) error{NotAllowed}!void {
    if (!std.EnumSet(State).initMany(from_allowed).contains(self.state)) {
        return error.NotAllowed;
    }
    const io = self.owner.io();

    self.state_mutex.lockUncancelable(io);
    defer self.state_mutex.unlock(io);

    self.state = target;
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}

pub fn begin(self: *Self, info: *const vk.CommandBufferBeginInfo) VkError!void {
    if (!self.pool.flags.reset_command_buffer_bit) {
        self.transitionState(.Recording, &.{.Initial}) catch return VkError.ValidationFailed;
    } else {
        try self.reset(.{});
        self.transitionState(.Recording, &.{ .Initial, .Recording, .Executable, .Invalid }) catch return VkError.ValidationFailed;
    }
    try self.dispatch_table.begin(self, info);
    self.begin_info = info.*;
}

pub fn end(self: *Self) VkError!void {
    self.transitionState(.Executable, &.{.Recording}) catch return VkError.ValidationFailed;
    try self.dispatch_table.end(self);
    self.begin_info = null;
}

pub fn reset(self: *Self, flags: vk.CommandBufferResetFlags) VkError!void {
    if (!self.pool.flags.reset_command_buffer_bit) {
        return VkError.ValidationFailed;
    }

    self.transitionState(.Initial, &.{ .Initial, .Recording, .Executable, .Invalid }) catch return VkError.ValidationFailed;
    try self.dispatch_table.reset(self, flags);
}

pub fn submit(self: *Self) VkError!void {
    if (self.begin_info) |begin_info| {
        if (!begin_info.flags.simultaneous_use_bit) {
            self.transitionState(.Pending, &.{.Executable}) catch return VkError.ValidationFailed;
            return;
        }
    }
    self.transitionState(.Pending, &.{ .Pending, .Executable }) catch return VkError.ValidationFailed;
}

pub fn finish(self: *Self) VkError!void {
    if (self.begin_info) |begin_info| {
        if (!begin_info.flags.one_time_submit_bit) {
            self.transitionState(.Invalid, &.{.Pending}) catch return VkError.ValidationFailed;
            return;
        }
    }
    self.transitionState(.Executable, &.{.Pending}) catch return VkError.ValidationFailed;
}

// Commands ====================================================================================================

pub inline fn beginRenderPass(self: *Self, render_pass: *RenderPass, framebuffer: *Framebuffer, render_area: vk.Rect2D, clear_values: ?[]const vk.ClearValue) VkError!void {
    try self.dispatch_table.beginRenderPass(self, render_pass, framebuffer, render_area, clear_values);
}

pub fn bindDescriptorSets(self: *Self, bind_point: vk.PipelineBindPoint, first_set: u32, sets: []const vk.DescriptorSet, dynamic_offsets: []const u32) VkError!void {
    std.debug.assert(sets.len < lib.VULKAN_MAX_DESCRIPTOR_SETS);
    var inner_sets = [_]?*DescriptorSet{null} ** lib.VULKAN_MAX_DESCRIPTOR_SETS;
    for (sets, inner_sets[0..sets.len]) |set, *inner_set| {
        inner_set.* = try NonDispatchable(DescriptorSet).fromHandleObject(set);
    }
    try self.dispatch_table.bindDescriptorSets(self, bind_point, first_set, inner_sets, dynamic_offsets);
}

pub inline fn bindPipeline(self: *Self, bind_point: vk.PipelineBindPoint, pipeline: *Pipeline) VkError!void {
    try self.dispatch_table.bindPipeline(self, bind_point, pipeline);
}

pub inline fn bindVertexBuffer(self: *Self, index: usize, buffer: *Buffer, offset: usize) VkError!void {
    try self.dispatch_table.bindVertexBuffer(self, index, buffer, offset);
}

pub inline fn blitImage(self: *Self, src: *Image, src_layout: vk.ImageLayout, dst: *Image, dst_layout: vk.ImageLayout, regions: []const vk.ImageBlit, filter: vk.Filter) VkError!void {
    try self.dispatch_table.blitImage(self, src, src_layout, dst, dst_layout, regions, filter);
}

pub fn clearAttachment(self: *Self, attachment: vk.ClearAttachment, rect: vk.ClearRect) VkError!void {
    try self.dispatch_table.clearAttachment(self, attachment, rect);
}

pub fn clearColorImage(self: *Self, image: *Image, layout: vk.ImageLayout, color: *const vk.ClearColorValue, ranges: []const vk.ImageSubresourceRange) VkError!void {
    for (ranges) |range| {
        try self.dispatch_table.clearColorImage(self, image, layout, color, range);
    }
}

pub inline fn copyBuffer(self: *Self, src: *Buffer, dst: *Buffer, regions: []const vk.BufferCopy) VkError!void {
    try self.dispatch_table.copyBuffer(self, src, dst, regions);
}

pub inline fn copyBufferToImage(self: *Self, src: *Buffer, dst: *Image, dst_layout: vk.ImageLayout, regions: []const vk.BufferImageCopy) VkError!void {
    try self.dispatch_table.copyBufferToImage(self, src, dst, dst_layout, regions);
}

pub inline fn copyImage(self: *Self, src: *Image, src_layout: vk.ImageLayout, dst: *Image, dst_layout: vk.ImageLayout, regions: []const vk.ImageCopy) VkError!void {
    try self.dispatch_table.copyImage(self, src, src_layout, dst, dst_layout, regions);
}

pub inline fn copyImageToBuffer(self: *Self, src: *Image, src_layout: vk.ImageLayout, dst: *Buffer, regions: []const vk.BufferImageCopy) VkError!void {
    try self.dispatch_table.copyImageToBuffer(self, src, src_layout, dst, regions);
}

pub inline fn dispatch(self: *Self, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    try self.dispatch_table.dispatch(self, group_count_x, group_count_y, group_count_z);
}

pub inline fn dispatchIndirect(self: *Self, buffer: *Buffer, offset: vk.DeviceSize) VkError!void {
    try self.dispatch_table.dispatchIndirect(self, buffer, offset);
}

pub inline fn draw(self: *Self, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize) VkError!void {
    try self.dispatch_table.draw(self, vertex_count, instance_count, first_vertex, first_instance);
}

pub inline fn endRenderPass(self: *Self) VkError!void {
    try self.dispatch_table.endRenderPass(self);
}

pub inline fn executeCommands(self: *Self, commands: *Self) VkError!void {
    try self.dispatch_table.executeCommands(self, commands);
}

pub inline fn fillBuffer(self: *Self, buffer: *Buffer, offset: vk.DeviceSize, size: vk.DeviceSize, data: u32) VkError!void {
    try self.dispatch_table.fillBuffer(self, buffer, offset, size, data);
}

pub inline fn pipelineBarrier(
    self: *Self,
    src_stage: vk.PipelineStageFlags,
    dst_stage: vk.PipelineStageFlags,
    dependency: vk.DependencyFlags,
    memory_barriers: []const vk.MemoryBarrier,
    buffer_barriers: []const vk.BufferMemoryBarrier,
    image_barriers: []const vk.ImageMemoryBarrier,
) VkError!void {
    try self.dispatch_table.pipelineBarrier(self, src_stage, dst_stage, dependency, memory_barriers, buffer_barriers, image_barriers);
}

pub inline fn resetEvent(self: *Self, event: *Event, stage: vk.PipelineStageFlags) VkError!void {
    try self.dispatch_table.resetEvent(self, event, stage);
}

pub inline fn setEvent(self: *Self, event: *Event, stage: vk.PipelineStageFlags) VkError!void {
    try self.dispatch_table.setEvent(self, event, stage);
}

pub inline fn setViewport(self: *Self, first: u32, viewports: []const vk.Viewport) VkError!void {
    try self.dispatch_table.setViewport(self, first, viewports);
}

pub inline fn waitEvent(
    self: *Self,
    event: *Event,
    src_stage: vk.PipelineStageFlags,
    dst_stage: vk.PipelineStageFlags,
    memory_barriers: []const vk.MemoryBarrier,
    buffer_barriers: []const vk.BufferMemoryBarrier,
    image_barriers: []const vk.ImageMemoryBarrier,
) VkError!void {
    try self.dispatch_table.waitEvent(self, event, src_stage, dst_stage, memory_barriers, buffer_barriers, image_barriers);
}
