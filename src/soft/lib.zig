const std = @import("std");
const vk = @import("vulkan");
pub const base = @import("base");

pub const Instance = @import("Instance.zig");
const Device = @import("Device.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");

pub const DRIVER_LOGS_ENV_NAME = base.DRIVER_LOGS_ENV_NAME;
pub const DRIVER_NAME = "Soft";

pub const VULKAN_VERSION = vk.makeApiVersion(0, 1, 0, 0);
pub const DRIVER_VERSION = vk.makeApiVersion(0, 0, 0, 1);
pub const DEVICE_ID = 0x600DCAFE;

pub const std_options = base.std_options;

comptime {
    _ = base;
}
