const std = @import("std");
const vk = @import("vulkan");
pub const base = @import("base");

pub const Executor = @import("Executor.zig");

pub const SoftInstance = @import("SoftInstance.zig");
pub const SoftDevice = @import("SoftDevice.zig");
pub const SoftPhysicalDevice = @import("SoftPhysicalDevice.zig");
pub const SoftQueue = @import("SoftQueue.zig");

pub const SoftBuffer = @import("SoftBuffer.zig");
pub const SoftCommandBuffer = @import("SoftCommandBuffer.zig");
pub const SoftCommandPool = @import("SoftCommandPool.zig");
pub const SoftDeviceMemory = @import("SoftDeviceMemory.zig");
pub const SoftFence = @import("SoftFence.zig");

pub const Instance = SoftInstance;

pub const DRIVER_LOGS_ENV_NAME = base.DRIVER_LOGS_ENV_NAME;
pub const DRIVER_NAME = "Soft";

pub const VULKAN_VERSION = vk.makeApiVersion(0, 1, 0, 0);
pub const DRIVER_VERSION = vk.makeApiVersion(0, 0, 0, 1);
pub const DEVICE_ID = 0x600DCAFE;

/// Generic system memory.
pub const MEMORY_TYPE_GENERIC_BIT = 0;

/// 16 bytes for 128-bit vector types.
pub const MEMORY_REQUIREMENTS_ALIGNMENT = 16;

/// Vulkan 1.2 requires buffer offset alignment to be at most 256.
pub const MIN_TEXEL_BUFFER_ALIGNMENT = 256;
/// Vulkan 1.2 requires buffer offset alignment to be at most 256.
pub const MIN_UNIFORM_BUFFER_ALIGNMENT = 256;
/// Vulkan 1.2 requires buffer offset alignment to be at most 256.
pub const MIN_STORAGE_BUFFER_ALIGNMENT = 256;

pub const std_options = base.std_options;

comptime {
    _ = base;
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
