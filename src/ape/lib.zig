const std = @import("std");
const vk = @import("vulkan");
pub const base = @import("base");
pub const soft = @import("soft");

pub const c = base.c;
pub const config = base.config;

pub const ApeInstance = @import("ApeInstance.zig");

pub const Instance = ApeInstance;

pub const DRIVER_NAME = "Ape";

pub const VULKAN_VERSION = vk.makeApiVersion(
    0,
    config.ape_vulkan_version.major,
    config.ape_vulkan_version.minor,
    config.ape_vulkan_version.patch,
);

pub const std_options = base.std_options;

comptime {
    _ = base;
    _ = soft;
}

test {
    std.testing.refAllDecls(ApeInstance);
    std.testing.refAllDecls(soft);
    std.testing.refAllDecls(base);
}
