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
    bindSparse: *const fn (*Self, u32, *const vk.BindSparseInfo, ?*Fence) VkError!void,
    submit: *const fn (*Self, u32, *const vk.SubmitInfo, ?*Fence) VkError!void,
    waitIdle: *const fn (*Self) VkError!void,
};
