const std = @import("std");
const vk = @import("vulkan");

const cmd = @import("commands.zig");

const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;
const VkError = @import("error_set.zig").VkError;
const VulkanAllocator = @import("VulkanAllocator.zig");

const Device = @import("Device.zig");

const Buffer = @import("Buffer.zig");
const CommandPool = @import("CommandPool.zig");

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
    copyBuffer: *const fn (*Self, *Buffer, *Buffer, []const vk.BufferCopy) VkError!void,
    end: *const fn (*Self) VkError!void,
    fillBuffer: *const fn (*Self, *Buffer, vk.DeviceSize, vk.DeviceSize, u32) VkError!void,
    reset: *const fn (*Self, vk.CommandBufferResetFlags) VkError!void,
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
        .host_allocator = VulkanAllocator.from(allocator).clone(),
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
    _ = allocator;
    for (self.commands.items) |command| {
        switch (command) {
            else => {},
        }
    }
}

// Commands ====================================================================================================

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

pub inline fn copyBuffer(self: *Self, src: *Buffer, dst: *Buffer, regions: []const vk.BufferCopy) VkError!void {
    const allocator = self.host_allocator.allocator();
    self.commands.append(allocator, .{ .CopyBuffer = .{
        .src = src,
        .dst = dst,
        .regions = regions,
    } }) catch return VkError.OutOfHostMemory;
    try self.dispatch_table.copyBuffer(self, src, dst, regions);
}
