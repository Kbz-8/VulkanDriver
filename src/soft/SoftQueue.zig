const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const SoftDeviceMemory = @import("SoftDeviceMemory.zig");
const SoftFence = @import("SoftFence.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Queue;

interface: Interface,
mutex: std.Thread.Mutex,
