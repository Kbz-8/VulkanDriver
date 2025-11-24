//! This file contains all exported Vulkan entrypoints.

const std = @import("std");
const vk = @import("vulkan");
const root = @import("root");
const lib = @import("lib.zig");
const builtin = @import("builtin");

const logger = @import("logger.zig");
const error_set = @import("error_set.zig");
const VkError = error_set.VkError;
const toVkResult = error_set.toVkResult;
const errorLogger = error_set.errorLogger;

const Dispatchable = @import("Dispatchable.zig").Dispatchable;
const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;

const VulkanAllocator = @import("VulkanAllocator.zig");

const Instance = @import("Instance.zig");
const Device = @import("Device.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");
const Queue = @import("Queue.zig");

const Buffer = @import("Buffer.zig");
const CommandBuffer = @import("CommandBuffer.zig");
const CommandPool = @import("CommandPool.zig");
const DeviceMemory = @import("DeviceMemory.zig");
const Fence = @import("Fence.zig");
const Image = @import("Image.zig");
const ImageView = @import("ImageView.zig");

fn entryPointBeginLogTrace(comptime scope: @Type(.enum_literal)) void {
    std.log.scoped(scope).debug("Calling {s}...", .{@tagName(scope)});
    logger.indent();
}

fn entryPointEndLogTrace() void {
    logger.unindent();
}

fn entryPointNotFoundErrorLog(comptime scope: @Type(.enum_literal), name: []const u8) void {
    if (lib.getLogVerboseLevel() != .TooMuch) return;
    std.log.scoped(scope).err("Could not find function {s}", .{name});
}

fn functionMapEntryPoint(comptime name: []const u8) struct { []const u8, vk.PfnVoidFunction } {
    // Mapping 'vkFnName' to 'strollFnName'
    const stroll_name = std.fmt.comptimePrint("stroll{s}", .{name[2..]});

    return if (std.meta.hasFn(@This(), name))
        .{ name, @as(vk.PfnVoidFunction, @ptrCast(&@field(@This(), name))) }
    else if (std.meta.hasFn(@This(), stroll_name))
        .{ name, @as(vk.PfnVoidFunction, @ptrCast(&@field(@This(), stroll_name))) }
    else
        @compileError("Invalid entry point name");
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
    functionMapEntryPoint("vkAllocateCommandBuffers"),
    functionMapEntryPoint("vkAllocateMemory"),
    functionMapEntryPoint("vkBeginCommandBuffer"),
    functionMapEntryPoint("vkBindBufferMemory"),
    functionMapEntryPoint("vkBindImageMemory"),
    functionMapEntryPoint("vkCmdClearColorImage"),
    functionMapEntryPoint("vkCmdCopyBuffer"),
    functionMapEntryPoint("vkCmdCopyImage"),
    functionMapEntryPoint("vkCmdFillBuffer"),
    functionMapEntryPoint("vkCreateCommandPool"),
    functionMapEntryPoint("vkCreateBuffer"),
    functionMapEntryPoint("vkCreateFence"),
    functionMapEntryPoint("vkCreateImage"),
    functionMapEntryPoint("vkCreateImageView"),
    functionMapEntryPoint("vkDestroyBuffer"),
    functionMapEntryPoint("vkDestroyCommandPool"),
    functionMapEntryPoint("vkDestroyDevice"),
    functionMapEntryPoint("vkDestroyFence"),
    functionMapEntryPoint("vkDestroyImage"),
    functionMapEntryPoint("vkDestroyImageView"),
    functionMapEntryPoint("vkEndCommandBuffer"),
    functionMapEntryPoint("vkFreeCommandBuffers"),
    functionMapEntryPoint("vkFreeMemory"),
    functionMapEntryPoint("vkGetBufferMemoryRequirements"),
    functionMapEntryPoint("vkGetDeviceQueue"),
    functionMapEntryPoint("vkGetFenceStatus"),
    functionMapEntryPoint("vkGetImageMemoryRequirements"),
    functionMapEntryPoint("vkMapMemory"),
    functionMapEntryPoint("vkUnmapMemory"),
    functionMapEntryPoint("vkResetCommandBuffer"),
    functionMapEntryPoint("vkResetFences"),
    functionMapEntryPoint("vkQueueBindSparse"),
    functionMapEntryPoint("vkQueueSubmit"),
    functionMapEntryPoint("vkQueueWaitIdle"),
    functionMapEntryPoint("vkWaitForFences"),
});

// ICD Interface =============================================================================================================================================

pub export fn stroll_icdNegotiateLoaderICDInterfaceVersion(p_version: *u32) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vk_icdNegociateLoaderICDInterfaceVersion);
    defer entryPointEndLogTrace();

    p_version.* = 7;
    return .success;
}

pub export fn vk_icdGetInstanceProcAddr(p_instance: vk.Instance, p_name: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    if (lib.getLogVerboseLevel() == .TooMuch) {
        entryPointBeginLogTrace(.vk_icdGetInstanceProcAddr);
    }
    defer entryPointEndLogTrace();

    if (p_name == null) return null;
    const name = std.mem.span(p_name.?);

    if (icd_pfn_map.get(name)) |pfn| return pfn;
    return vkGetInstanceProcAddr(p_instance, p_name);
}

pub export fn stroll_icdGetPhysicalDeviceProcAddr(_: vk.Instance, p_name: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    if (lib.getLogVerboseLevel() == .TooMuch) {
        entryPointBeginLogTrace(.vk_icdGetPhysicalDeviceProcAddr);
    }
    defer entryPointEndLogTrace();

    if (p_name == null) return null;
    const name = std.mem.span(p_name.?);

    if (physical_device_pfn_map.get(name)) |pfn| return pfn;

    entryPointNotFoundErrorLog(.vk_icdGetPhysicalDeviceProcAddr, name);
    return null;
}

// Global functions ==========================================================================================================================================

pub export fn vkGetInstanceProcAddr(p_instance: vk.Instance, p_name: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    if (lib.getLogVerboseLevel() == .TooMuch) {
        entryPointBeginLogTrace(.vkGetInstanceProcAddr);
    }
    defer entryPointEndLogTrace();

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

pub export fn strollCreateInstance(p_info: ?*const vk.InstanceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_instance: *vk.Instance) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateInstance);
    defer entryPointEndLogTrace();

    const info = p_info orelse return .error_validation_failed;
    if (info.s_type != .instance_create_info) {
        return .error_validation_failed;
    }
    const allocator = VulkanAllocator.init(callbacks, .instance).allocator();

    var instance: *lib.Instance = undefined;
    if (!builtin.is_test) {
        // Will call impl instead of interface as root refs the impl module
        instance = root.Instance.create(allocator, info) catch |err| return toVkResult(err);
    }
    instance.requestPhysicalDevices(allocator) catch |err| return toVkResult(err);

    p_instance.* = (Dispatchable(Instance).wrap(allocator, instance) catch |err| return toVkResult(err)).toVkHandle(vk.Instance);
    return .success;
}

pub export fn strollEnumerateInstanceExtensionProperties(p_layer_name: ?[*:0]const u8, property_count: *u32, properties: ?*vk.ExtensionProperties) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkEnumerateInstanceExtensionProperties);
    defer entryPointEndLogTrace();

    var name: ?[]const u8 = null;
    if (p_layer_name) |layer_name| {
        name = std.mem.span(layer_name);
    }
    Instance.enumerateExtensionProperties(name, property_count, properties) catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollEnumerateInstanceVersion(version: *u32) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkEnumerateInstanceVersion);
    defer entryPointEndLogTrace();

    Instance.enumerateVersion(version) catch |err| return toVkResult(err);
    return .success;
}

// Instance functions ========================================================================================================================================

pub export fn strollDestroyInstance(p_instance: vk.Instance, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    defer logger.freeInnerDebugStack();

    entryPointBeginLogTrace(.vkDestroyInstance);
    defer entryPointEndLogTrace();

    const allocator = VulkanAllocator.init(callbacks, .instance).allocator();
    const dispatchable = Dispatchable(Instance).fromHandle(p_instance) catch |err| return errorLogger(err);
    dispatchable.object.deinit(allocator) catch |err| return errorLogger(err);
    dispatchable.destroy(allocator);

    if (std.process.hasEnvVarConstant(lib.DRIVER_DEBUG_ALLOCATOR_ENV_NAME) or builtin.mode == std.builtin.OptimizeMode.Debug) {
        // All host memory allocations should've been freed by now
        if (!VulkanAllocator.debug_allocator.detectLeaks()) {
            std.log.scoped(.vkDestroyInstance).debug("No memory leaks detected", .{});
        }
    }
}

pub export fn strollEnumeratePhysicalDevices(p_instance: vk.Instance, count: *u32, p_devices: ?[*]vk.PhysicalDevice) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkEnumeratePhysicalDevices);
    defer entryPointEndLogTrace();

    const instance = Dispatchable(Instance).fromHandleObject(p_instance) catch |err| return toVkResult(err);
    count.* = @intCast(instance.physical_devices.items.len);
    if (p_devices) |devices| {
        for (0..count.*) |i| {
            devices[i] = instance.physical_devices.items[i].toVkHandle(vk.PhysicalDevice);
        }
    }
    return .success;
}

// Physical Device functions =================================================================================================================================

pub export fn strollCreateDevice(p_physical_device: vk.PhysicalDevice, p_info: ?*const vk.DeviceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_device: *vk.Device) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateDevice);
    defer entryPointEndLogTrace();

    const info = p_info orelse return .error_validation_failed;
    if (info.s_type != .device_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .device).allocator();
    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);

    std.log.scoped(.vkCreateDevice).debug("Using VkPhysicalDevice named {s}", .{physical_device.props.device_name});

    const device = physical_device.createDevice(allocator, info) catch |err| return toVkResult(err);
    p_device.* = (Dispatchable(Device).wrap(allocator, device) catch |err| return toVkResult(err)).toVkHandle(vk.Device);
    return .success;
}

pub export fn strollEnumerateDeviceExtensionProperties(p_physical_device: vk.PhysicalDevice, p_layer_name: ?[*:0]const u8, property_count: *u32, properties: ?*vk.ExtensionProperties) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkEnumerateDeviceExtensionProperties);
    defer entryPointEndLogTrace();

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
    entryPointBeginLogTrace(.vkGetPhysicalDeviceFormatProperties);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    properties.* = physical_device.getFormatProperties(format) catch |err| return errorLogger(err);
}

pub export fn strollGetPhysicalDeviceFeatures(p_physical_device: vk.PhysicalDevice, features: *vk.PhysicalDeviceFeatures) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceFeatures);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    features.* = physical_device.features;
}

pub export fn strollGetPhysicalDeviceImageFormatProperties(
    p_physical_device: vk.PhysicalDevice,
    format: vk.Format,
    image_type: vk.ImageType,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    flags: vk.ImageCreateFlags,
    properties: *vk.ImageFormatProperties,
) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceImageFormatProperties);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);
    properties.* = physical_device.getImageFormatProperties(format, image_type, tiling, usage, flags) catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollGetPhysicalDeviceProperties(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceProperties) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceProperties);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    properties.* = physical_device.props;
}

pub export fn strollGetPhysicalDeviceMemoryProperties(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceMemoryProperties) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceMemoryProperties);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    properties.* = physical_device.mem_props;
}

pub export fn strollGetPhysicalDeviceQueueFamilyProperties(p_physical_device: vk.PhysicalDevice, count: *u32, properties: ?[*]vk.QueueFamilyProperties) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceQueueFamilyProperties);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    count.* = @intCast(physical_device.queue_family_props.items.len);
    if (properties) |props| {
        @memcpy(props[0..count.*], physical_device.queue_family_props.items[0..count.*]);
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
    entryPointBeginLogTrace(.vkGetPhysicalDeviceSparseImageFormatProperties);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);
    properties.* = physical_device.getSparseImageFormatProperties(format, image_type, samples, tiling, usage, flags) catch |err| return toVkResult(err);
    return .success;
}

// Queue functions ===========================================================================================================================================

pub export fn strollQueueBindSparse(p_queue: vk.Queue, count: u32, info: [*]vk.BindSparseInfo, p_fence: vk.Fence) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkQueueBindSparse);
    defer entryPointEndLogTrace();

    const queue = Dispatchable(Queue).fromHandleObject(p_queue) catch |err| return toVkResult(err);
    const fence = if (p_fence != .null_handle) NonDispatchable(Fence).fromHandleObject(p_fence) catch |err| return toVkResult(err) else null;
    queue.bindSparse(info[0..count], fence) catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollQueueSubmit(p_queue: vk.Queue, count: u32, info: [*]const vk.SubmitInfo, p_fence: vk.Fence) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkQueueSubmit);
    defer entryPointEndLogTrace();

    if (count == 0) return .success;

    const queue = Dispatchable(Queue).fromHandleObject(p_queue) catch |err| return toVkResult(err);
    const fence = if (p_fence != .null_handle) NonDispatchable(Fence).fromHandleObject(p_fence) catch |err| return toVkResult(err) else null;
    queue.submit(info[0..count], fence) catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollQueueWaitIdle(p_queue: vk.Queue) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkQueueWaitIdle);
    defer entryPointEndLogTrace();

    const queue = Dispatchable(Queue).fromHandleObject(p_queue) catch |err| return toVkResult(err);
    queue.waitIdle() catch |err| return toVkResult(err);
    return .success;
}

// Device functions ==========================================================================================================================================

pub export fn strollAllocateCommandBuffers(p_device: vk.Device, p_info: ?*const vk.CommandBufferAllocateInfo, p_cmds: [*]vk.CommandBuffer) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkAllocateCommandBuffers);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const info = p_info orelse return .error_validation_failed;
    if (info.s_type != .command_buffer_allocate_info) {
        return .error_validation_failed;
    }

    const pool = NonDispatchable(CommandPool).fromHandleObject(info.command_pool) catch |err| return toVkResult(err);
    const cmds = pool.allocateCommandBuffers(info) catch |err| return toVkResult(err);
    for (cmds[0..info.command_buffer_count], 0..) |cmd, i| {
        p_cmds[i] = cmd.toVkHandle(vk.CommandBuffer);
    }
    return .success;
}

pub export fn strollAllocateMemory(p_device: vk.Device, p_info: ?*const vk.MemoryAllocateInfo, callbacks: ?*const vk.AllocationCallbacks, p_memory: *vk.DeviceMemory) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkAllocateMemory);
    defer entryPointEndLogTrace();

    const info = p_info orelse return .error_validation_failed;
    if (info.s_type != .memory_allocate_info) {
        return .error_validation_failed;
    }

    std.log.scoped(.vkAllocateMemory).debug("Allocating {d} bytes from device 0x{X}", .{ info.allocation_size, @intFromEnum(p_device) });

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const device_memory = device.allocateMemory(allocator, info) catch |err| return toVkResult(err);

    p_memory.* = (NonDispatchable(DeviceMemory).wrap(allocator, device_memory) catch |err| return toVkResult(err)).toVkHandle(vk.DeviceMemory);
    return .success;
}

pub export fn strollBindBufferMemory(p_device: vk.Device, p_buffer: vk.Buffer, p_memory: vk.DeviceMemory, offset: vk.DeviceSize) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkBindBufferMemory);
    defer entryPointEndLogTrace();

    std.log.scoped(.vkBindBufferMemory).debug("Binding device memory 0x{X} to buffer 0x{X}", .{ @intFromEnum(p_memory), @intFromEnum(p_buffer) });

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const buffer = NonDispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return toVkResult(err);
    const memory = NonDispatchable(DeviceMemory).fromHandleObject(p_memory) catch |err| return toVkResult(err);

    buffer.bindMemory(memory, offset) catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollBindImageMemory(p_device: vk.Device, p_image: vk.Image, p_memory: vk.DeviceMemory, offset: vk.DeviceSize) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkBindImageMemory);
    defer entryPointEndLogTrace();

    std.log.scoped(.vkBindImageMemory).debug("Binding device memory 0x{X} to image 0x{X}", .{ @intFromEnum(p_memory), @intFromEnum(p_image) });

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const image = NonDispatchable(Image).fromHandleObject(p_image) catch |err| return toVkResult(err);
    const memory = NonDispatchable(DeviceMemory).fromHandleObject(p_memory) catch |err| return toVkResult(err);

    image.bindMemory(memory, offset) catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollCreateBuffer(p_device: vk.Device, p_info: ?*const vk.BufferCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_buffer: *vk.Buffer) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateBuffer);
    defer entryPointEndLogTrace();

    const info = p_info orelse return .error_validation_failed;
    if (info.s_type != .buffer_create_info) {
        return .error_validation_failed;
    }
    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const buffer = device.createBuffer(allocator, info) catch |err| return toVkResult(err);
    p_buffer.* = (NonDispatchable(Buffer).wrap(allocator, buffer) catch |err| return toVkResult(err)).toVkHandle(vk.Buffer);
    return .success;
}

pub export fn strollCreateCommandPool(p_device: vk.Device, p_info: ?*const vk.CommandPoolCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_pool: *vk.CommandPool) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateCommandPool);
    defer entryPointEndLogTrace();

    const info = p_info orelse return .error_validation_failed;
    if (info.s_type != .command_pool_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const pool = device.createCommandPool(allocator, info) catch |err| return toVkResult(err);
    p_pool.* = (NonDispatchable(CommandPool).wrap(allocator, pool) catch |err| return toVkResult(err)).toVkHandle(vk.CommandPool);
    return .success;
}

pub export fn strollCreateFence(p_device: vk.Device, p_info: ?*const vk.FenceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_fence: *vk.Fence) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateFence);
    defer entryPointEndLogTrace();

    const info = p_info orelse return .error_validation_failed;
    if (info.s_type != .fence_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const fence = device.createFence(allocator, info) catch |err| return toVkResult(err);
    p_fence.* = (NonDispatchable(Fence).wrap(allocator, fence) catch |err| return toVkResult(err)).toVkHandle(vk.Fence);
    return .success;
}

pub export fn strollCreateImage(p_device: vk.Device, p_info: ?*const vk.ImageCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_image: *vk.Image) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateImage);
    defer entryPointEndLogTrace();

    const info = p_info orelse return .error_validation_failed;
    if (info.s_type != .image_create_info) {
        return .error_validation_failed;
    }
    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const image = device.createImage(allocator, info) catch |err| return toVkResult(err);
    p_image.* = (NonDispatchable(Image).wrap(allocator, image) catch |err| return toVkResult(err)).toVkHandle(vk.Image);
    return .success;
}

pub export fn strollCreateImageView(p_device: vk.Device, p_info: ?*const vk.ImageViewCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_image_view: *vk.ImageView) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateImageView);
    defer entryPointEndLogTrace();

    const info = p_info orelse return .error_validation_failed;
    if (info.s_type != .image_view_create_info) {
        return .error_validation_failed;
    }
    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const image_view = device.createImageView(allocator, info) catch |err| return toVkResult(err);
    p_image_view.* = (NonDispatchable(ImageView).wrap(allocator, image_view) catch |err| return toVkResult(err)).toVkHandle(vk.ImageView);
    return .success;
}

pub export fn strollDestroyBuffer(p_device: vk.Device, p_buffer: vk.Buffer, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyBuffer);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(Buffer).fromHandle(p_buffer) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollDestroyCommandPool(p_device: vk.Device, p_pool: vk.CommandPool, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyCommandPool);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(CommandPool).fromHandle(p_pool) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollDestroyDevice(p_device: vk.Device, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyDevice);
    defer entryPointEndLogTrace();

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const dispatchable = Dispatchable(Device).fromHandle(p_device) catch |err| return errorLogger(err);

    std.log.scoped(.vkDestroyDevice).debug("Destroying VkDevice created from {s}", .{dispatchable.object.physical_device.props.device_name});

    dispatchable.object.destroy(allocator) catch |err| return errorLogger(err);
    dispatchable.destroy(allocator);
}

pub export fn strollDestroyFence(p_device: vk.Device, p_fence: vk.Fence, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyFence);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(Fence).fromHandle(p_fence) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollDestroyImage(p_device: vk.Device, p_image: vk.Image, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyImage);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(Image).fromHandle(p_image) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollDestroyImageView(p_device: vk.Device, p_image_view: vk.ImageView, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyImageView);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(ImageView).fromHandle(p_image_view) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollFreeCommandBuffers(p_device: vk.Device, p_pool: vk.CommandPool, count: u32, p_cmds: [*]const vk.CommandBuffer) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkFreeCommandBuffers);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const pool = NonDispatchable(CommandPool).fromHandleObject(p_pool) catch |err| return errorLogger(err);
    const cmds: [*]*Dispatchable(CommandBuffer) = @ptrCast(@constCast(p_cmds));
    pool.freeCommandBuffers(cmds[0..count]) catch |err| return errorLogger(err);
}

pub export fn strollFreeMemory(p_device: vk.Device, p_memory: vk.DeviceMemory, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkFreeMemory);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(DeviceMemory).fromHandle(p_memory) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollGetBufferMemoryRequirements(p_device: vk.Device, p_buffer: vk.Buffer, requirements: *vk.MemoryRequirements) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetBufferMemoryRequirements);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const buffer = NonDispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);
    buffer.getMemoryRequirements(requirements);
}

pub export fn strollGetDeviceProcAddr(p_device: vk.Device, p_name: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    if (lib.getLogVerboseLevel() == .TooMuch) {
        entryPointBeginLogTrace(.vkGetDeviceProcAddr);
    }
    defer entryPointEndLogTrace();

    if (p_name == null) return null;
    const name = std.mem.span(p_name.?);

    if (p_device == .null_handle) return null;
    if (device_pfn_map.get(name)) |pfn| return pfn;

    entryPointNotFoundErrorLog(.vkGetDeviceProcAddr, name);
    return null;
}

pub export fn strollGetDeviceQueue(p_device: vk.Device, queue_family_index: u32, queue_index: u32, p_queue: *vk.Queue) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetDeviceQueue);
    defer entryPointEndLogTrace();

    p_queue.* = .null_handle;
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return errorLogger(err);
    if (device.queues.get(queue_family_index)) |family| {
        if (queue_index >= family.items.len) return;

        const dispatchable_queue = family.items[queue_index];
        const queue = dispatchable_queue.object;

        // https://docs.vulkan.org/refpages/latest/refpages/source/vkGetDeviceQueue.html#VUID-vkGetDeviceQueue-flags-01841
        if (queue.flags != @TypeOf(queue.flags){}) return;

        p_queue.* = dispatchable_queue.toVkHandle(vk.Queue);
    }
}

pub export fn strollGetFenceStatus(p_device: vk.Device, p_fence: vk.Fence) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetFenceStatus);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const fence = NonDispatchable(Fence).fromHandleObject(p_fence) catch |err| return toVkResult(err);
    fence.getStatus() catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollGetImageMemoryRequirements(p_device: vk.Device, p_image: vk.Image, requirements: *vk.MemoryRequirements) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetImageMemoryRequirements);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const image = NonDispatchable(Image).fromHandleObject(p_image) catch |err| return errorLogger(err);
    image.getMemoryRequirements(requirements);
}

pub export fn strollMapMemory(p_device: vk.Device, p_memory: vk.DeviceMemory, offset: vk.DeviceSize, size: vk.DeviceSize, _: vk.MemoryMapFlags, pp_data: *?*anyopaque) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkMapMemory);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const device_memory = NonDispatchable(DeviceMemory).fromHandleObject(p_memory) catch |err| return toVkResult(err);
    pp_data.* = device_memory.map(offset, size) catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollUnmapMemory(p_device: vk.Device, p_memory: vk.DeviceMemory) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkUnmapMemory);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const device_memory = NonDispatchable(DeviceMemory).fromHandleObject(p_memory) catch |err| return errorLogger(err);
    device_memory.unmap();
}

pub export fn strollResetFences(p_device: vk.Device, count: u32, p_fences: [*]const vk.Fence) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkResetFences);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    for (p_fences, 0..count) |p_fence, _| {
        const fence = NonDispatchable(Fence).fromHandleObject(p_fence) catch |err| return toVkResult(err);
        fence.reset() catch |err| return toVkResult(err);
    }
    return .success;
}

pub export fn strollWaitForFences(p_device: vk.Device, count: u32, p_fences: [*]const vk.Fence, waitForAll: vk.Bool32, timeout: u64) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkWaitForFences);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    loop: for (p_fences, 0..count) |p_fence, _| {
        const fence = NonDispatchable(Fence).fromHandleObject(p_fence) catch |err| return toVkResult(err);
        fence.wait(timeout) catch |err| return toVkResult(err);
        if (waitForAll == .false) break :loop;
    }
    return .success;
}

// Command Buffer functions ===================================================================================================================================

pub export fn strollBeginCommandBuffer(p_cmd: vk.CommandBuffer, p_info: ?*const vk.CommandBufferBeginInfo) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkBeginCommandBuffer);
    defer entryPointEndLogTrace();

    const info = p_info orelse return .error_validation_failed;
    if (info.s_type != .command_buffer_begin_info) {
        return .error_validation_failed;
    }
    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return toVkResult(err);
    cmd.begin(info) catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollCmdClearColorImage(p_cmd: vk.CommandBuffer, p_image: vk.Image, layout: vk.ImageLayout, color: *const vk.ClearColorValue, count: u32, ranges: [*]const vk.ImageSubresourceRange) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdCopyImage);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const image = NonDispatchable(Image).fromHandleObject(p_image) catch |err| return errorLogger(err);
    cmd.clearColorImage(image, layout, color, ranges[0..count]) catch |err| return errorLogger(err);
}

pub export fn strollCmdCopyBuffer(p_cmd: vk.CommandBuffer, p_src: vk.Buffer, p_dst: vk.Buffer, count: u32, regions: [*]const vk.BufferCopy) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdCopyBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const src = NonDispatchable(Buffer).fromHandleObject(p_src) catch |err| return errorLogger(err);
    const dst = NonDispatchable(Buffer).fromHandleObject(p_dst) catch |err| return errorLogger(err);
    cmd.copyBuffer(src, dst, regions[0..count]) catch |err| return errorLogger(err);
}

pub export fn strollCmdCopyImage(p_cmd: vk.CommandBuffer, p_src: vk.Image, p_dst: vk.Image, count: u32, regions: [*]const vk.ImageCopy) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdCopyImage);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const src = NonDispatchable(Image).fromHandleObject(p_src) catch |err| return errorLogger(err);
    const dst = NonDispatchable(Image).fromHandleObject(p_dst) catch |err| return errorLogger(err);
    cmd.copyImage(src, dst, regions[0..count]) catch |err| return errorLogger(err);
}

pub export fn strollCmdFillBuffer(p_cmd: vk.CommandBuffer, p_buffer: vk.Buffer, offset: vk.DeviceSize, size: vk.DeviceSize, data: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdFillBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const buffer = NonDispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);
    cmd.fillBuffer(buffer, offset, size, data) catch |err| return errorLogger(err);
}

pub export fn strollEndCommandBuffer(p_cmd: vk.CommandBuffer) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkEndCommandBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return toVkResult(err);
    cmd.end() catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollResetCommandBuffer(p_cmd: vk.CommandBuffer, flags: vk.CommandBufferResetFlags) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkResetCommandBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return toVkResult(err);
    cmd.reset(flags) catch |err| return toVkResult(err);
    return .success;
}
