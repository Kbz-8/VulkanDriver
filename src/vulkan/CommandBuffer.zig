const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const CommandPool = @import("CommandPool.zig");
const Device = @import("Device.zig");
const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;

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

vtable: *const VTable,
dispatch_table: *const DispatchTable,

pub const DispatchTable = struct {
    begin: *const fn (*Self, *const vk.CommandBufferBeginInfo) VkError!void,
    end: *const fn (*Self) VkError!void,
    reset: *const fn (*Self, vk.CommandBufferResetFlags) VkError!void,
};

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.CommandBufferAllocateInfo) VkError!Self {
    _ = allocator;
    return .{
        .owner = device,
        .pool = try NonDispatchable(CommandPool).fromHandleObject(info.command_pool),
        .state = .Initial,
        .begin_info = null,
        .vtable = undefined,
        .dispatch_table = undefined,
    };
}

inline fn transitionState(self: *Self, target: State, from_allowed: std.EnumSet(State)) error{NotAllowed}!void {
    if (!from_allowed.contains(self.state)) {
        return error.NotAllowed;
    }
    self.state = target;
}

inline fn transitionStateNotAllowed(self: *Self, target: State, from_not_allowed: std.EnumSet(State)) error{NotAllowed}!void {
    if (from_not_allowed.contains(self.state)) {
        return error.NotAllowed;
    }
    self.state = target;
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}

pub inline fn begin(self: *Self, info: *const vk.CommandBufferBeginInfo) VkError!void {
    if (!self.pool.flags.reset_command_buffer_bit) {
        self.transitionState(.Recording, .initOne(.Initial)) catch return VkError.ValidationFailed;
    } else {
        self.transitionStateNotAllowed(.Recording, .initMany(&.{ .Recording, .Pending })) catch return VkError.ValidationFailed;
    }
    try self.dispatch_table.begin(self, info);
    self.begin_info = info.*;
}

pub inline fn end(self: *Self) VkError!void {
    self.transitionState(.Executable, .initOne(.Recording)) catch return VkError.ValidationFailed;
    try self.dispatch_table.end(self);
}

pub inline fn reset(self: *Self, flags: vk.CommandBufferResetFlags) VkError!void {
    if (!self.pool.flags.reset_command_buffer_bit) {
        return VkError.ValidationFailed;
    }
    self.transitionStateNotAllowed(.Initial, .initOne(.Pending)) catch return VkError.ValidationFailed;
    try self.dispatch_table.reset(self, flags);
}

pub inline fn submit(self: *Self) VkError!void {
    self.transitionState(.Initial, .initMany(&.{ .Pending, .Executable })) catch return VkError.ValidationFailed;
    if (self.begin_info) |begin_info| {
        if (!begin_info.flags.simultaneous_use_bit) {
            self.transitionStateNotAllowed(.Initial, .initOne(.Pending)) catch return VkError.ValidationFailed;
        }
    }
}
