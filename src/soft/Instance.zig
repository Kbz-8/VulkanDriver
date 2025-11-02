const std = @import("std");
const vk = @import("vulkan");
const common = @import("common");
const PhysicalDevice = @import("PhysicalDevice.zig");

const dispatchable = common.dispatchable;

const Self = @This();
pub const ObjectType: vk.ObjectType = .instance;

common_instance: common.Instance,
physical_device: vk.PhysicalDevice, // Software driver only has one physical device (CPU)

pub fn create(p_infos: ?*const vk.InstanceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_instance: *vk.Instance) callconv(vk.vulkan_call_conv) vk.Result {
    const allocator = std.heap.c_allocator;

    const dispatchable_instance = dispatchable.Dispatchable(Self).create(allocator) catch return .error_out_of_host_memory;
    const instance = dispatchable_instance.object;
    common.Instance.init(&instance.common_instance, p_infos, callbacks) catch return .error_initialization_failed;

    instance.common_instance.vtable = .{
        .destroyInstance = destroy,
        .enumeratePhysicalDevices = enumeratePhysicalDevices,
        .enumerateInstanceVersion = null,
        //.enumerateInstanceLayerProperties = null,
        .enumerateInstanceExtensionProperties = null,
        .getPhysicalDeviceProperties = PhysicalDevice.getProperties,
    };

    const dispatchable_physical_device = dispatchable.Dispatchable(PhysicalDevice).create(allocator) catch return .error_out_of_host_memory;
    PhysicalDevice.init(dispatchable_physical_device.object) catch return .error_initialization_failed;
    instance.physical_device = @enumFromInt(dispatchable_physical_device.toHandle());

    p_instance.* = @enumFromInt(dispatchable_instance.toHandle());
    return .success;
}

pub fn enumeratePhysicalDevices(p_instance: vk.Instance, count: *u32, p_devices: ?[*]vk.PhysicalDevice) callconv(vk.vulkan_call_conv) vk.Result {
    const instance = dispatchable.fromHandleObject(Self, @intFromEnum(p_instance)) catch return .error_initialization_failed;
    count.* = 1;
    if (p_devices) |devices| {
        devices[0] = instance.physical_device;
    }
    return .success;
}

pub fn destroy(p_instance: vk.Instance, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    const allocator = std.heap.c_allocator;
    _ = callbacks;

    const dispatchable_instance = dispatchable.fromHandle(Self, @intFromEnum(p_instance)) catch return;
    const dispatchable_physical_device = dispatchable.fromHandle(PhysicalDevice, @intFromEnum(dispatchable_instance.object.physical_device)) catch return;
    dispatchable_physical_device.destroy(allocator);
    dispatchable_instance.destroy(allocator);
}
