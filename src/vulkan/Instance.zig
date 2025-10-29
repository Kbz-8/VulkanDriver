const std = @import("std");
const vk = @import("vulkan");
const PhysicalDevice = @import("PhysicalDevice").PhysicalDevice;
const Object = @import("object.zig").Object;

pub const Instance = extern struct {
    const Self = @This();
    const ObjectType: vk.ObjectType = .instance;

    object: Object,
    physical_devices: std.ArrayList(*PhysicalDevice),
    alloc_callbacks: vk.AllocationCallbacks,
};
