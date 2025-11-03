const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const soft_physical_device = @import("physical_device.zig");

const Dispatchable = base.Dispatchable;
const VulkanAllocator = base.VulkanAllocator;

const Self = @This();

export fn __vkImplInstanceInit(base_instance: *base.Instance, allocator: *const std.mem.Allocator, infos: *const vk.InstanceCreateInfo) ?*anyopaque {
    return realVkImplInstanceInit(base_instance, allocator.*, infos) catch return null;
}

// Pure Zig implementation to leverage `errdefer` and avoid memory leaks or complex resources handling
fn realVkImplInstanceInit(instance: *base.Instance, allocator: std.mem.Allocator, infos: *const vk.InstanceCreateInfo) !?*anyopaque {
    _ = infos;

    // Software driver only has one physical device (the CPU)
    const physical_device = try Dispatchable(base.PhysicalDevice).create(allocator, .{instance});
    errdefer physical_device.destroy(allocator);

    try soft_physical_device.setup(allocator, physical_device.object);

    try instance.physical_devices.append(allocator, physical_device.toVkHandle(vk.PhysicalDevice));

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    return @ptrCast(self);
}
