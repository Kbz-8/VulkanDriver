const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const CommandBuffer = @import("CommandBuffer.zig");
const Device = @import("Device.zig");
const Dispatchable = @import("Dispatchable.zig").Dispatchable;
const Fence = @import("Fence.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .queue;

owner: *Device,
family_index: u32,
index: u32,
flags: vk.DeviceQueueCreateFlags,

dispatch_table: *const DispatchTable,

pub const DispatchTable = struct {
    bindSparse: *const fn (*Self, []const vk.BindSparseInfo, ?*Fence) VkError!void,
    submit: *const fn (*Self, []const vk.SubmitInfo, ?*Fence) VkError!void,
    waitIdle: *const fn (*Self) VkError!void,
};

pub fn init(allocator: std.mem.Allocator, device: *Device, index: u32, family_index: u32, flags: vk.DeviceQueueCreateFlags) VkError!Self {
    std.log.scoped(.vkCreateDevice).info("Creating device queue with family index {d} and index {d}", .{ family_index, index });
    _ = allocator;
    return .{
        .owner = device,
        .family_index = family_index,
        .index = index,
        .flags = flags,
        .dispatch_table = undefined,
    };
}

pub inline fn bindSparse(self: *Self, info: []const vk.BindSparseInfo, fence: ?*Fence) VkError!void {
    try self.dispatch_table.bindSparse(self, info, fence);
}

pub inline fn submit(self: *Self, info: []const vk.SubmitInfo, fence: ?*Fence) VkError!void {
    try self.dispatch_table.submit(self, info, fence);
    for (info) |submit_info| {
        if (submit_info.p_command_buffers) |p_command_buffers| {
            for (p_command_buffers[0..submit_info.command_buffer_count]) |p_cmd| {
                const cmd = try Dispatchable(CommandBuffer).fromHandleObject(p_cmd);
                try cmd.submit();
            }
        }
    }
}

pub inline fn waitIdle(self: *Self) VkError!void {
    try self.dispatch_table.waitIdle(self);
}
