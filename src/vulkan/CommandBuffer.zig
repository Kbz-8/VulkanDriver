const std = @import("std");
const vk = @import("vulkan");

const cmd = @import("commands.zig");

const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;
const VkError = @import("error_set.zig").VkError;
const VulkanAllocator = @import("VulkanAllocator.zig");

const Device = @import("Device.zig");

const Buffer = @import("Buffer.zig");
const CommandPool = @import("CommandPool.zig");
const Event = @import("Event.zig");
const Image = @import("Image.zig");

const COMMAND_BUFFER_BASE_CAPACITY = 256;

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
commands: std.ArrayList(cmd.Command),
state_mutex: std.Thread.Mutex,

vtable: *const VTable,
dispatch_table: *const DispatchTable,

pub const DispatchTable = struct {
    begin: *const fn (*Self, *const vk.CommandBufferBeginInfo) VkError!void,
    clearColorImage: *const fn (*Self, *Image, vk.ImageLayout, *const vk.ClearColorValue, vk.ImageSubresourceRange) VkError!void,
    copyBuffer: *const fn (*Self, *Buffer, *Buffer, []const vk.BufferCopy) VkError!void,
    copyImage: *const fn (*Self, *Image, vk.ImageLayout, *Image, vk.ImageLayout, []const vk.ImageCopy) VkError!void,
    copyImageToBuffer: *const fn (*Self, *Image, vk.ImageLayout, *Buffer, []const vk.BufferImageCopy) VkError!void,
    end: *const fn (*Self) VkError!void,
    fillBuffer: *const fn (*Self, *Buffer, vk.DeviceSize, vk.DeviceSize, u32) VkError!void,
    reset: *const fn (*Self, vk.CommandBufferResetFlags) VkError!void,
    resetEvent: *const fn (*Self, *Event, vk.PipelineStageFlags) VkError!void,
    setEvent: *const fn (*Self, *Event, vk.PipelineStageFlags) VkError!void,
    waitEvents: *const fn (*Self, []*const Event, vk.PipelineStageFlags, vk.PipelineStageFlags, []const vk.MemoryBarrier, []const vk.BufferMemoryBarrier, []const vk.ImageMemoryBarrier) VkError!void,
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
        .commands = std.ArrayList(cmd.Command).initCapacity(allocator, COMMAND_BUFFER_BASE_CAPACITY) catch return VkError.OutOfHostMemory,
        .state_mutex = .{},
        .vtable = undefined,
        .dispatch_table = undefined,
    };
}

inline fn transitionState(self: *Self, target: State, from_allowed: []const State) error{NotAllowed}!void {
    if (!std.EnumSet(State).initMany(from_allowed).contains(self.state)) {
        return error.NotAllowed;
    }
    self.state_mutex.lock();
    defer self.state_mutex.unlock();
    self.state = target;
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.cleanCommandList();
    self.commands.deinit(allocator);
    self.vtable.destroy(self, allocator);
}

pub inline fn begin(self: *Self, info: *const vk.CommandBufferBeginInfo) VkError!void {
    if (!self.pool.flags.reset_command_buffer_bit) {
        self.transitionState(.Recording, &.{.Initial}) catch return VkError.ValidationFailed;
    } else {
        self.transitionState(.Recording, &.{ .Initial, .Executable, .Invalid }) catch return VkError.ValidationFailed;
    }
    try self.dispatch_table.begin(self, info);
    self.begin_info = info.*;
}

pub inline fn end(self: *Self) VkError!void {
    self.transitionState(.Executable, &.{.Recording}) catch return VkError.ValidationFailed;
    try self.dispatch_table.end(self);
}

pub inline fn reset(self: *Self, flags: vk.CommandBufferResetFlags) VkError!void {
    if (!self.pool.flags.reset_command_buffer_bit) {
        return VkError.ValidationFailed;
    }
    defer self.cleanCommandList();

    self.transitionState(.Initial, &.{ .Initial, .Recording, .Executable, .Invalid }) catch return VkError.ValidationFailed;
    try self.dispatch_table.reset(self, flags);
}

pub inline fn submit(self: *Self) VkError!void {
    if (self.begin_info) |begin_info| {
        if (!begin_info.flags.simultaneous_use_bit) {
            self.transitionState(.Pending, &.{.Executable}) catch return VkError.ValidationFailed;
        }
    }
    self.transitionState(.Pending, &.{ .Pending, .Executable }) catch return VkError.ValidationFailed;
}

fn cleanCommandList(self: *Self) void {
    const allocator = self.host_allocator.allocator();
    for (self.commands.items) |command| {
        switch (command) {
            .CopyBuffer => |data| allocator.free(data.regions),
            .CopyImage => |data| allocator.free(data.regions),
            .CopyImageToBuffer => |data| allocator.free(data.regions),
            else => {},
        }
    }
}

// Commands ====================================================================================================

pub inline fn clearColorImage(self: *Self, image: *Image, layout: vk.ImageLayout, color: *const vk.ClearColorValue, ranges: []const vk.ImageSubresourceRange) VkError!void {
    const allocator = self.host_allocator.allocator();
    for (ranges) |range| {
        self.commands.append(allocator, .{ .ClearColorImage = .{
            .image = image,
            .layout = layout,
            .clear_color = color.*,
            .range = range,
        } }) catch return VkError.OutOfHostMemory;
        try self.dispatch_table.clearColorImage(self, image, layout, color, range);
    }
}

pub inline fn copyBuffer(self: *Self, src: *Buffer, dst: *Buffer, regions: []const vk.BufferCopy) VkError!void {
    const allocator = self.host_allocator.allocator();
    self.commands.append(allocator, .{ .CopyBuffer = .{
        .src = src,
        .dst = dst,
        .regions = allocator.dupe(vk.BufferCopy, regions) catch return VkError.OutOfHostMemory,
    } }) catch return VkError.OutOfHostMemory;
    try self.dispatch_table.copyBuffer(self, src, dst, regions);
}

pub inline fn copyImage(self: *Self, src: *Image, src_layout: vk.ImageLayout, dst: *Image, dst_layout: vk.ImageLayout, regions: []const vk.ImageCopy) VkError!void {
    const allocator = self.host_allocator.allocator();
    self.commands.append(allocator, .{ .CopyImage = .{
        .src = src,
        .src_layout = src_layout,
        .dst = dst,
        .dst_layout = dst_layout,
        .regions = allocator.dupe(vk.ImageCopy, regions) catch return VkError.OutOfHostMemory,
    } }) catch return VkError.OutOfHostMemory;
    try self.dispatch_table.copyImage(self, src, src_layout, dst, dst_layout, regions);
}

pub inline fn copyImageToBuffer(self: *Self, src: *Image, src_layout: vk.ImageLayout, dst: *Buffer, regions: []const vk.BufferImageCopy) VkError!void {
    const allocator = self.host_allocator.allocator();
    self.commands.append(allocator, .{ .CopyImageToBuffer = .{
        .src = src,
        .src_layout = src_layout,
        .dst = dst,
        .regions = allocator.dupe(vk.BufferImageCopy, regions) catch return VkError.OutOfHostMemory,
    } }) catch return VkError.OutOfHostMemory;
    try self.dispatch_table.copyImageToBuffer(self, src, src_layout, dst, regions);
}

pub inline fn fillBuffer(self: *Self, buffer: *Buffer, offset: vk.DeviceSize, size: vk.DeviceSize, data: u32) VkError!void {
    const allocator = self.host_allocator.allocator();
    self.commands.append(allocator, .{ .FillBuffer = .{
        .buffer = buffer,
        .offset = offset,
        .size = if (size == vk.WHOLE_SIZE) buffer.size else size,
        .data = data,
    } }) catch return VkError.OutOfHostMemory;
    try self.dispatch_table.fillBuffer(self, buffer, offset, size, data);
}

pub inline fn resetEvent(self: *Self, event: *Event, stage: vk.PipelineStageFlags) VkError!void {
    try self.dispatch_table.resetEvent(self, event, stage);
}

pub inline fn setEvent(self: *Self, event: *Event, stage: vk.PipelineStageFlags) VkError!void {
    try self.dispatch_table.setEvent(self, event, stage);
}

pub inline fn waitEvents(self: *Self, events: []*const Event, src_stage: vk.PipelineStageFlags, dst_stage: vk.PipelineStageFlags, memory_barriers: []const vk.MemoryBarrier, buffer_barriers: []const vk.BufferMemoryBarrier, image_barriers: []const vk.ImageMemoryBarrier) VkError!void {
    try self.dispatch_table.waitEvents(self, events, src_stage, dst_stage, memory_barriers, buffer_barriers, image_barriers);
}
