const std = @import("std");
const vk = @import("vulkan");
const common = @import("common");
const PhysicalDevice = @import("PhysicalDevice.zig");

const dispatchable = common.dispatchable;

const Self = @This();
pub const ObjectType: vk.ObjectType = .instance;

common_instance: common.Instance,
physical_device: dispatchable.Dispatchable(PhysicalDevice), // Software driver only has one physical device (CPU)

pub fn create(p_infos: ?*const vk.InstanceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_instance: *vk.Instance) callconv(vk.vulkan_call_conv) vk.Result {
    const allocator = std.heap.c_allocator;

    const dispatchable_object = dispatchable.Dispatchable(Self).create(allocator, ObjectType) catch return .error_out_of_host_memory;
    common.Instance.init(&dispatchable_object.object.common_instance, p_infos, callbacks) catch return .error_initialization_failed;

    dispatchable_object.object.common_instance.vtable = .{
        .destroyInstance = destroy,
        .enumeratePhysicalDevices = enumeratePhysicalDevices,
        .enumerateInstanceVersion = null,
        //.enumerateInstanceLayerProperties = null,
        .enumerateInstanceExtensionProperties = null,
    };

    dispatchable_object.object.physical_device.init() catch return .error_initialization_failed;

    p_instance.* = @enumFromInt(dispatchable.toHandle(Self, dispatchable_object));
    return .success;
}

pub fn enumeratePhysicalDevices(p_instance: vk.Instance, count: *u32, devices: *vk.PhysicalDevice) callconv(vk.vulkan_call_conv) vk.Result {
    const dispatchable_object = common.dispatchable.fromHandle(Self, @intFromEnum(p_instance)) catch return .error_initialization_failed;
    _ = dispatchable_object;
    _ = count;
    _ = devices;
    return .success;
}

pub fn destroy(p_instance: vk.Instance, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    const allocator = std.heap.c_allocator;
    _ = callbacks;

    const dispatchable_object = common.dispatchable.fromHandle(Self, @intFromEnum(p_instance)) catch return;
    dispatchable_object.destroy(allocator);
}
