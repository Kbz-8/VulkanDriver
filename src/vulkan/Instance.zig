const std = @import("std");
const vk = @import("vulkan");
const PhysicalDevice = @import("PhysicalDevice.zig").PhysicalDevice;
const Object = @import("object.zig").Object;

pub const Instance = extern struct {
    const Self = @This();
    pub const ObjectType: vk.ObjectType = .instance;
    pub const vtable: *const VTable = .{};

    object: Object,
    //physical_devices: std.ArrayList(*PhysicalDevice),
    alloc_callbacks: vk.AllocationCallbacks,

    pub const VTable = struct {
        createInstance: ?vk.PfnCreateInstance,
        destroyInstance: ?vk.PfnDestroyInstance,
        enumeratePhysicalDevices: ?vk.PfnEnumeratePhysicalDevices,
        getInstanceProcAddr: ?vk.PfnGetInstanceProcAddr,
        enumerateInstanceVersion: ?vk.PfnEnumerateInstanceVersion,
        //enumerateInstanceLayerProperties: vk.PfnEnumerateInstanceProperties,
        enumerateInstanceExtensionProperties: ?vk.PfnEnumerateInstanceExtensionProperties,
    };
};
