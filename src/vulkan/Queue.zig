const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const Device = @import("Device.zig");
const Fence = @import("Fence.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .queue;

owner: *const Device,
family_index: u32,
index: u32,
flags: vk.DeviceQueueCreateFlags,

dispatch_table: *const DispatchTable,

pub const DispatchTable = struct {
    bindSparse: *const fn (*Self, []*const vk.BindSparseInfo, ?*Fence) VkError!void,
    submit: *const fn (*Self, []*const vk.SubmitInfo, ?*Fence) VkError!void,
    waitIdle: *const fn (*Self) VkError!void,
};

pub fn init(allocator: std.mem.Allocator, device: *const Device, index: u32, info: vk.DeviceQueueCreateInfo) VkError!Self {
    _ = allocator;
    return .{
        .owner = device,
        .family_index = info.queueFamilyIndex,
        .index = index,
        .flags = info.flags,
        .dispatch_table = undefined,
    };
}

pub inline fn bindSparse(self: *Self, info: []*const vk.BindSparseInfo, fence: ?*Fence) VkError!void {
    try self.dispatch_table.bindSparse(self, info, fence);
}

pub inline fn submit(self: *Self, info: []*const vk.SubmitInfo, fence: ?*Fence) VkError!void {
    try self.dispatch_table.submit(self, info, fence);
}

pub inline fn waitIdle(self: *Self) VkError!void {
    try self.dispatch_table.waitIdle(self);
}
