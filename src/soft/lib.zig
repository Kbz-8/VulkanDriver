const std = @import("std");
const vk = @import("vulkan");
pub const base = @import("base");

pub const SoftInstance = @import("SoftInstance.zig");
pub const SoftDevice = @import("SoftDevice.zig");
pub const SoftPhysicalDevice = @import("SoftPhysicalDevice.zig");
pub const SoftQueue = @import("SoftQueue.zig");

pub const SoftDeviceMemory = @import("SoftDeviceMemory.zig");
pub const SoftFence = @import("SoftFence.zig");

pub const Instance = SoftInstance;

pub const DRIVER_LOGS_ENV_NAME = base.DRIVER_LOGS_ENV_NAME;
pub const DRIVER_NAME = "Soft";

pub const VULKAN_VERSION = vk.makeApiVersion(0, 1, 0, 0);
pub const DRIVER_VERSION = vk.makeApiVersion(0, 0, 0, 1);
pub const DEVICE_ID = 0x600DCAFE;

pub const std_options = base.std_options;

test {
    std.testing.refAllDeclsRecursive(@This());
}
