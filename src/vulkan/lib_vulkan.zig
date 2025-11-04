const std = @import("std");
const vk = @import("vulkan");
const root = @import("lib.zig");

const error_set = @import("error_set.zig");
const VkError = error_set.VkError;
const toVkResult = error_set.toVkResult;

const Dispatchable = @import("Dispatchable.zig").Dispatchable;

const VulkanAllocator = @import("VulkanAllocator.zig");

const Instance = @import("Instance.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");

fn functionMapElement(name: []const u8) struct { []const u8, vk.PfnVoidFunction } {
    if (!std.meta.hasFn(@This(), name)) {
        std.log.scoped(.functionMapElement).err("Could not find function {s}", .{name});
        return .{ name, null };
    }
    return .{ name, @as(vk.PfnVoidFunction, @ptrCast(&@field(@This(), name))) };
}

pub export fn vkGetInstanceProcAddr(p_instance: vk.Instance, p_name: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    const global_pfn_map = std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
        functionMapElement("vkGetInstanceProcAddr"),
        functionMapElement("vkCreateInstance"),
    });

    const instance_pfn_map = std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
        functionMapElement("vkDestroyInstance"),
        functionMapElement("vkEnumeratePhysicalDevices"),
        functionMapElement("vkGetPhysicalDeviceProperties"),
        functionMapElement("vkGetPhysicalDeviceProperties"),
    });

    if (p_name == null) {
        return null;
    }
    const name = std.mem.span(p_name.?);

    if (std.process.hasEnvVarConstant(root.DRIVER_LOGS_ENV_NAME)) {
        std.log.scoped(.vkGetInstanceProcAddr).info("Loading {s}...", .{name});
    }

    if (global_pfn_map.get(name)) |pfn| return pfn;
    if (p_instance == .null_handle) return null;
    return if (instance_pfn_map.get(name)) |pfn| pfn else null;
}

pub export fn vkCreateInstance(p_infos: ?*const vk.InstanceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_instance: *vk.Instance) callconv(vk.vulkan_call_conv) vk.Result {
    const infos = p_infos orelse return .error_initialization_failed;
    if (infos.s_type != .instance_create_info) {
        return .error_initialization_failed;
    }
    const allocator = VulkanAllocator.init(callbacks, .instance).allocator();
    p_instance.* = (Dispatchable(Instance).create(allocator, .{infos}) catch |err| return toVkResult(err)).toVkHandle(vk.Instance);
    return .success;
}

pub export fn vkDestroyInstance(p_instance: vk.Instance, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    const allocator = VulkanAllocator.init(callbacks, .instance).allocator();
    (Dispatchable(Instance).fromHandle(p_instance) catch return).destroy(allocator);
}

pub export fn vkEnumeratePhysicalDevices(p_instance: vk.Instance, count: *u32, p_devices: ?[*]vk.PhysicalDevice) callconv(vk.vulkan_call_conv) vk.Result {
    const self = Dispatchable(Instance).fromHandleObject(p_instance) catch |err| return toVkResult(err);
    count.* = @intCast(self.physical_devices.items.len);
    if (p_devices) |devices| {
        @memcpy(devices[0..self.physical_devices.items.len], self.physical_devices.items);
    }
    return .success;
}

pub export fn vkGetPhysicalDeviceProperties(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceProperties) callconv(vk.vulkan_call_conv) void {
    const self = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch return;
    properties.* = self.props;
}

pub export fn vkGetPhysicalDeviceMemoryProperties(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceMemoryProperties) callconv(vk.vulkan_call_conv) void {
    const self = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch return;
    properties.* = self.mem_props;
}
