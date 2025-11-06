const std = @import("std");
const vk = @import("vulkan");
const root = @import("root");
const lib = @import("lib.zig");

const logger = @import("logger.zig");
const error_set = @import("error_set.zig");
const VkError = error_set.VkError;
const toVkResult = error_set.toVkResult;

const Dispatchable = @import("Dispatchable.zig").Dispatchable;

const VulkanAllocator = @import("VulkanAllocator.zig");

const Instance = @import("Instance.zig");
const Device = @import("Device.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");

// This file contains all exported Vulkan entrypoints.

fn entryPointNotFoundErrorLog(comptime scope: @Type(.enum_literal), name: []const u8) void {
    if (lib.getLogVerboseLevel() != .High) return;
    std.log.scoped(scope).err("Could not find function {s}", .{name});
}

fn functionMapEntryPoint(comptime name: []const u8) struct { []const u8, vk.PfnVoidFunction } {
    const stroll_name = std.fmt.comptimePrint("stroll{s}", .{name[2..]});

    return if (std.meta.hasFn(@This(), name))
        .{ name, @as(vk.PfnVoidFunction, @ptrCast(&@field(@This(), name))) }
    else if (std.meta.hasFn(@This(), stroll_name))
        .{ name, @as(vk.PfnVoidFunction, @ptrCast(&@field(@This(), stroll_name))) }
    else
        .{ name, null };
}

const icd_pfn_map = std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
    functionMapEntryPoint("vk_icdGetInstanceProcAddr"),
    functionMapEntryPoint("vk_icdGetPhysicalDeviceProcAddr"),
    functionMapEntryPoint("vk_icdNegotiateLoaderICDInterfaceVersion"),
});

const global_pfn_map = std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
    functionMapEntryPoint("vkCreateInstance"),
    functionMapEntryPoint("vkGetInstanceProcAddr"),
    functionMapEntryPoint("vkEnumerateInstanceExtensionProperties"),
    functionMapEntryPoint("vkEnumerateInstanceVersion"),
});

const instance_pfn_map = std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
    functionMapEntryPoint("vkDestroyInstance"),
    functionMapEntryPoint("vkEnumeratePhysicalDevices"),
    functionMapEntryPoint("vkGetDeviceProcAddr"),
});

const physical_device_pfn_map = std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
    functionMapEntryPoint("vkCreateDevice"),
    functionMapEntryPoint("vkEnumerateDeviceExtensionProperties"),
    functionMapEntryPoint("vkGetPhysicalDeviceFormatProperties"),
    functionMapEntryPoint("vkGetPhysicalDeviceFeatures"),
    functionMapEntryPoint("vkGetPhysicalDeviceImageFormatProperties"),
    functionMapEntryPoint("vkGetPhysicalDeviceProperties"),
    functionMapEntryPoint("vkGetPhysicalDeviceMemoryProperties"),
    functionMapEntryPoint("vkGetPhysicalDeviceQueueFamilyProperties"),
    functionMapEntryPoint("vkGetPhysicalDeviceSparseImageFormatProperties"),
});

const device_pfn_map = std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
    functionMapEntryPoint("vkDestroyDevice"),
});

// ICD Interface =============================================================================================================================================

pub export fn stroll_icdNegotiateLoaderICDInterfaceVersion(p_version: *u32) callconv(vk.vulkan_call_conv) vk.Result {
    p_version.* = 7;
    return .success;
}

pub export fn vk_icdGetInstanceProcAddr(p_instance: vk.Instance, p_name: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    if (p_name == null) return null;
    const name = std.mem.span(p_name.?);

    if (icd_pfn_map.get(name)) |pfn| return pfn;
    return vkGetInstanceProcAddr(p_instance, p_name);
}

pub export fn stroll_icdGetPhysicalDeviceProcAddr(_: vk.Instance, p_name: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    if (p_name == null) return null;
    const name = std.mem.span(p_name.?);

    if (physical_device_pfn_map.get(name)) |pfn| return pfn;

    entryPointNotFoundErrorLog(.vk_icdGetPhysicalDeviceProcAddr, name);
    return null;
}

// Global functions ==========================================================================================================================================

pub export fn vkGetInstanceProcAddr(p_instance: vk.Instance, p_name: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    if (p_name == null) return null;
    const name = std.mem.span(p_name.?);

    if (global_pfn_map.get(name)) |pfn| return pfn;
    if (p_instance == .null_handle) {
        entryPointNotFoundErrorLog(.vkGetInstanceProcAddr, name);
        return null;
    }
    if (instance_pfn_map.get(name)) |pfn| return pfn;
    if (physical_device_pfn_map.get(name)) |pfn| return pfn;
    if (device_pfn_map.get(name)) |pfn| return pfn;

    entryPointNotFoundErrorLog(.vkGetInstanceProcAddr, name);
    return null;
}

pub export fn strollCreateInstance(p_infos: ?*const vk.InstanceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_instance: *vk.Instance) callconv(vk.vulkan_call_conv) vk.Result {
    const infos = p_infos orelse return .error_initialization_failed;
    if (infos.s_type != .instance_create_info) {
        return .error_initialization_failed;
    }
    std.log.scoped(.vkCreateInstance).info("Creating VkInstance", .{});
    logger.indent();
    defer logger.unindent();

    const allocator = VulkanAllocator.init(callbacks, .instance).allocator();

    // Will call impl instead of interface as root refs the impl module
    const instance = root.Instance.create(allocator, infos) catch |err| return toVkResult(err);
    instance.requestPhysicalDevices(allocator) catch |err| return toVkResult(err);

    p_instance.* = (Dispatchable(Instance).wrap(allocator, instance) catch |err| return toVkResult(err)).toVkHandle(vk.Instance);
    return .success;
}

pub export fn strollEnumerateInstanceExtensionProperties(p_layer_name: ?[*:0]const u8, property_count: *u32, properties: ?*vk.ExtensionProperties) callconv(vk.vulkan_call_conv) vk.Result {
    var name: ?[]const u8 = null;
    if (p_layer_name) |layer_name| {
        name = std.mem.span(layer_name);
    }
    Instance.enumerateExtensionProperties(name, property_count, properties) catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollEnumerateInstanceVersion(version: *u32) callconv(vk.vulkan_call_conv) vk.Result {
    Instance.enumerateVersion(version) catch |err| return toVkResult(err);
    return .success;
}

// Instance functions ========================================================================================================================================

pub export fn strollDestroyInstance(p_instance: vk.Instance, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    std.log.scoped(.vkDestroyInstance).info("Destroying VkInstance", .{});
    logger.indent();
    defer logger.unindent();

    const allocator = VulkanAllocator.init(callbacks, .instance).allocator();
    const dispatchable = Dispatchable(Instance).fromHandle(p_instance) catch return;
    dispatchable.object.deinit(allocator) catch {};
    dispatchable.destroy(allocator);
}

pub export fn strollEnumeratePhysicalDevices(p_instance: vk.Instance, count: *u32, p_devices: ?[*]vk.PhysicalDevice) callconv(vk.vulkan_call_conv) vk.Result {
    const self = Dispatchable(Instance).fromHandleObject(p_instance) catch |err| return toVkResult(err);
    count.* = @intCast(self.physical_devices.items.len);
    if (p_devices) |devices| {
        for (0..count.*) |i| {
            devices[i] = self.physical_devices.items[i].toVkHandle(vk.PhysicalDevice);
        }
    }
    return .success;
}

// Physical Device functions =================================================================================================================================

pub export fn strollCreateDevice(p_physical_device: vk.PhysicalDevice, p_infos: ?*const vk.DeviceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_device: *vk.Device) callconv(vk.vulkan_call_conv) vk.Result {
    const infos = p_infos orelse return .error_initialization_failed;
    if (infos.s_type != .device_create_info) {
        return .error_initialization_failed;
    }
    const allocator = VulkanAllocator.init(callbacks, .instance).allocator();
    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);
    std.log.scoped(.vkCreateDevice).info("Creating VkDevice from {s}", .{physical_device.props.device_name});
    logger.indent();
    defer logger.unindent();

    const device = physical_device.createDevice(allocator, infos) catch |err| return toVkResult(err);
    p_device.* = (Dispatchable(Device).wrap(allocator, device) catch |err| return toVkResult(err)).toVkHandle(vk.Device);
    return .success;
}

pub export fn strollEnumerateDeviceExtensionProperties(p_physical_device: vk.PhysicalDevice, p_layer_name: ?[*:0]const u8, property_count: *u32, properties: ?*vk.ExtensionProperties) callconv(vk.vulkan_call_conv) vk.Result {
    var name: ?[]const u8 = null;
    if (p_layer_name) |layer_name| {
        name = std.mem.span(layer_name);
    }
    _ = p_physical_device;
    property_count.* = 0;
    _ = properties;
    return .success;
}

pub export fn strollGetPhysicalDeviceFormatProperties(p_physical_device: vk.PhysicalDevice, format: vk.Format, properties: *vk.FormatProperties) callconv(vk.vulkan_call_conv) void {
    const self = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch return;
    properties.* = self.getFormatProperties(format) catch return;
}

pub export fn strollGetPhysicalDeviceFeatures(p_physical_device: vk.PhysicalDevice, features: *vk.PhysicalDeviceFeatures) callconv(vk.vulkan_call_conv) void {
    const self = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch return;
    features.* = self.features;
}

pub export fn strollGetPhysicalDeviceImageFormatProperties(p_physical_device: vk.PhysicalDevice, format: vk.Format, image_type: vk.ImageType, tiling: vk.ImageTiling, usage: vk.ImageUsageFlags, flags: vk.ImageCreateFlags, properties: *vk.ImageFormatProperties) callconv(vk.vulkan_call_conv) vk.Result {
    const self = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);
    properties.* = self.getImageFormatProperties(format, image_type, tiling, usage, flags) catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollGetPhysicalDeviceProperties(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceProperties) callconv(vk.vulkan_call_conv) void {
    const self = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch return;
    properties.* = self.props;
}

pub export fn strollGetPhysicalDeviceMemoryProperties(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceMemoryProperties) callconv(vk.vulkan_call_conv) void {
    const self = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch return;
    properties.* = self.mem_props;
}

pub export fn strollGetPhysicalDeviceQueueFamilyProperties(p_physical_device: vk.PhysicalDevice, count: *u32, properties: ?[*]vk.QueueFamilyProperties) callconv(vk.vulkan_call_conv) void {
    const self = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch return;
    count.* = @intCast(self.queue_family_props.items.len);
    if (properties) |props| {
        @memcpy(props[0..count.*], self.queue_family_props.items[0..count.*]);
    }
}

pub export fn strollGetPhysicalDeviceSparseImageFormatProperties(
    p_physical_device: vk.PhysicalDevice,
    format: vk.Format,
    image_type: vk.ImageType,
    samples: vk.SampleCountFlags,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    flags: vk.ImageCreateFlags,
    properties: *vk.SparseImageFormatProperties,
) callconv(vk.vulkan_call_conv) vk.Result {
    const self = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);
    properties.* = self.getSparseImageFormatProperties(format, image_type, samples, tiling, usage, flags) catch |err| return toVkResult(err);
    return .success;
}

// Device functions ==========================================================================================================================================

pub export fn strollDestroyDevice(p_device: vk.Device, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    const allocator = VulkanAllocator.init(callbacks, .device).allocator();
    const dispatchable = Dispatchable(Device).fromHandle(p_device) catch return;
    std.log.scoped(.vkDestroyDevice).info("Destroying VkDevice created from {s}", .{dispatchable.object.physical_device.props.device_name});
    logger.indent();
    defer logger.unindent();

    dispatchable.object.destroy(allocator) catch return;
    dispatchable.destroy(allocator);
}

pub export fn strollGetDeviceProcAddr(p_device: vk.Device, p_name: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    if (p_name == null) return null;
    const name = std.mem.span(p_name.?);

    if (p_device == .null_handle) return null;
    if (device_pfn_map.get(name)) |pfn| return pfn;

    entryPointNotFoundErrorLog(.vkGetDeviceProcAddr, name);
    return null;
}
