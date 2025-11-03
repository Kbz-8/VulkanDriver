const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const PhysicalDevice = @import("PhysicalDevice.zig");

const dispatchable = base.dispatchable;
const VulkanAllocator = base.VulkanAllocator;

const Self = @This();

export fn __vkImplInstanceInit(base_instance: *base.Instance, allocator: *const std.mem.Allocator) ?*anyopaque {
    return realVkImplInstanceInit(base_instance, allocator.*) catch return null;
}

// Pure Zig implementation to leverage `errdefer` and avoid memory leaks or complex resources handling
fn realVkImplInstanceInit(base_instance: *base.Instance, allocator: std.mem.Allocator) !?*anyopaque {
    base_instance.dispatch_table = .{
        .destroyInstance = deinit,
        .enumerateInstanceVersion = null,
        //.enumerateInstanceLayerProperties = null,
        .enumerateInstanceExtensionProperties = null,
    };

    // Software driver only has one physical device (the CPU)
    const dispatchable_physical_device = try PhysicalDevice.init(base_instance, allocator);
    errdefer dispatchable_physical_device.destroy(allocator);

    try base_instance.physical_devices.append(allocator, @enumFromInt(dispatchable_physical_device.toHandle()));

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    return @ptrCast(self);
}

pub fn deinit(base_instance: *const base.Instance, allocator: std.mem.Allocator) !void {
    for (base_instance.physical_devices.items) |physical_device| {
        const dispatchable_physical_device = try dispatchable.fromHandle(base.PhysicalDevice, @intFromEnum(physical_device));
        dispatchable_physical_device.destroy(allocator);
    }
}
