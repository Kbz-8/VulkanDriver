const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .buffer;

owner: *const Device,
size: vk.DeviceSize,
offset: vk.DeviceSize,
usage: vk.BufferUsageFlags,
