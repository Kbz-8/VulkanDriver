const std = @import("std");
const vk = @import("vulkan");
const PhysicalDevice = @import("PhysicalDevice.zig").PhysicalDevice;
const Object = @import("object.zig").Object;

pub const Instance = extern struct {
    const Self = @This();
    pub const ObjectType: vk.ObjectType = .instance;
    pub const vtable: VTable = .{};

    object: Object,
    //physical_devices: std.ArrayList(*PhysicalDevice),
    alloc_callbacks: vk.AllocationCallbacks,

    pub const VTable = struct {
        createInstance: ?vk.PfnCreateInstance = null,
        destroyInstance: ?vk.PfnDestroyInstance = null,
        enumeratePhysicalDevices: ?vk.PfnEnumeratePhysicalDevices = null,
        getInstanceProcAddr: ?vk.PfnGetInstanceProcAddr = null,
        enumerateInstanceVersion: ?vk.PfnEnumerateInstanceVersion = null,
        //enumerateInstanceLayerProperties: vk.PfnEnumerateInstanceProperties = null,
        enumerateInstanceExtensionProperties: ?vk.PfnEnumerateInstanceExtensionProperties = null,
    };
};
