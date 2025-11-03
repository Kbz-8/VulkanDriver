const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const Instance = @import("Instance.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");

pub const VULKAN_VERSION = vk.makeApiVersion(0, 1, 0, 0);
pub const DRIVER_VERSION = vk.makeApiVersion(0, 0, 0, 1);
pub const DEVICE_ID = 0x600DCAFE;

comptime {
    _ = base;
    _ = Instance;
    _ = PhysicalDevice;
}
