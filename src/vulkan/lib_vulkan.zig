//! This file contains all exported Vulkan entrypoints.

const std = @import("std");
const vk = @import("vulkan");
const root = @import("root");
const lib = @import("lib.zig");
const builtin = @import("builtin");

const logger = lib.logger;
const errors = lib.errors;
const VkError = errors.VkError;
const toVkResult = errors.toVkResult;
const errorLogger = errors.errorLogger;

const Dispatchable = @import("Dispatchable.zig").Dispatchable;
const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;

const VulkanAllocator = @import("VulkanAllocator.zig");

pub const CommandBuffer = @import("CommandBuffer.zig");
pub const Device = @import("Device.zig");
pub const Instance = @import("Instance.zig");
pub const PhysicalDevice = @import("PhysicalDevice.zig");
pub const Queue = @import("Queue.zig");

pub const BinarySemaphore = @import("BinarySemaphore.zig");
pub const Buffer = @import("Buffer.zig");
pub const BufferView = @import("BufferView.zig");
pub const CommandPool = @import("CommandPool.zig");
pub const DescriptorPool = @import("DescriptorPool.zig");
pub const DescriptorSet = @import("DescriptorSet.zig");
pub const DescriptorSetLayout = @import("DescriptorSetLayout.zig");
pub const DeviceMemory = @import("DeviceMemory.zig");
pub const Event = @import("Event.zig");
pub const Fence = @import("Fence.zig");
pub const Framebuffer = @import("Framebuffer.zig");
pub const Image = @import("Image.zig");
pub const ImageView = @import("ImageView.zig");
pub const Pipeline = @import("Pipeline.zig");
pub const PipelineCache = @import("PipelineCache.zig");
pub const PipelineLayout = @import("PipelineLayout.zig");
pub const QueryPool = @import("QueryPool.zig");
pub const RenderPass = @import("RenderPass.zig");
pub const Sampler = @import("Sampler.zig");
pub const ShaderModule = @import("ShaderModule.zig");

fn entryPointBeginLogTrace(comptime scope: @Type(.enum_literal)) void {
    std.log.scoped(scope).debug("Calling {s}...", .{@tagName(scope)});
    logger.getManager().get().indent();
}

fn entryPointEndLogTrace() void {
    logger.getManager().get().unindent();
}

fn entryPointNotFoundErrorLog(comptime scope: @Type(.enum_literal), name: []const u8) void {
    if (lib.getLogVerboseLevel() != .TooMuch) return;
    std.log.scoped(scope).err("Could not find function {s}", .{name});
}

inline fn notImplementedWarning() void {
    logger.nestedFixme("function not yet implemented", .{});
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
    functionMapEntryPoint("vkEnumerateInstanceExtensionProperties"),
    //functionMapEntryPoint("vkEnumerateInstanceVersion"),
    functionMapEntryPoint("vkGetInstanceProcAddr"),
});

const instance_pfn_map = std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
    functionMapEntryPoint("vkDestroyInstance"),
    functionMapEntryPoint("vkEnumeratePhysicalDevices"),
    functionMapEntryPoint("vkGetDeviceProcAddr"),
});

const physical_device_pfn_map = std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
    functionMapEntryPoint("vkCreateDevice"),
    functionMapEntryPoint("vkEnumerateDeviceExtensionProperties"),
    functionMapEntryPoint("vkGetPhysicalDeviceFeatures"),
    functionMapEntryPoint("vkGetPhysicalDeviceFeatures2KHR"),
    functionMapEntryPoint("vkGetPhysicalDeviceFormatProperties"),
    functionMapEntryPoint("vkGetPhysicalDeviceFormatProperties2KHR"),
    functionMapEntryPoint("vkGetPhysicalDeviceImageFormatProperties"),
    functionMapEntryPoint("vkGetPhysicalDeviceImageFormatProperties2KHR"),
    functionMapEntryPoint("vkGetPhysicalDeviceMemoryProperties"),
    functionMapEntryPoint("vkGetPhysicalDeviceMemoryProperties2KHR"),
    functionMapEntryPoint("vkGetPhysicalDeviceProperties"),
    functionMapEntryPoint("vkGetPhysicalDeviceProperties2KHR"),
    functionMapEntryPoint("vkGetPhysicalDeviceQueueFamilyProperties"),
    functionMapEntryPoint("vkGetPhysicalDeviceQueueFamilyProperties2KHR"),
    functionMapEntryPoint("vkGetPhysicalDeviceSparseImageFormatProperties"),
    functionMapEntryPoint("vkGetPhysicalDeviceSparseImageFormatProperties2KHR"),
});

const device_pfn_map = block: {
    @setEvalBranchQuota(65535);
    break :block std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
        functionMapEntryPoint("vkAllocateCommandBuffers"),
        functionMapEntryPoint("vkAllocateDescriptorSets"),
        functionMapEntryPoint("vkAllocateDescriptorSets"),
        functionMapEntryPoint("vkAllocateMemory"),
        functionMapEntryPoint("vkBeginCommandBuffer"),
        functionMapEntryPoint("vkBindBufferMemory"),
        functionMapEntryPoint("vkBindImageMemory"),
        functionMapEntryPoint("vkCmdBeginQuery"),
        functionMapEntryPoint("vkCmdBeginRenderPass"),
        functionMapEntryPoint("vkCmdBindDescriptorSets"),
        functionMapEntryPoint("vkCmdBindIndexBuffer"),
        functionMapEntryPoint("vkCmdBindPipeline"),
        functionMapEntryPoint("vkCmdBindVertexBuffers"),
        functionMapEntryPoint("vkCmdBlitImage"),
        functionMapEntryPoint("vkCmdClearAttachments"),
        functionMapEntryPoint("vkCmdClearColorImage"),
        functionMapEntryPoint("vkCmdClearDepthStencilImage"),
        functionMapEntryPoint("vkCmdCopyBuffer"),
        functionMapEntryPoint("vkCmdCopyBufferToImage"),
        functionMapEntryPoint("vkCmdCopyImage"),
        functionMapEntryPoint("vkCmdCopyImageToBuffer"),
        functionMapEntryPoint("vkCmdCopyQueryPoolResults"),
        functionMapEntryPoint("vkCmdDispatch"),
        functionMapEntryPoint("vkCmdDispatchIndirect"),
        functionMapEntryPoint("vkCmdDraw"),
        functionMapEntryPoint("vkCmdDrawIndexed"),
        functionMapEntryPoint("vkCmdDrawIndexedIndirect"),
        functionMapEntryPoint("vkCmdDrawIndirect"),
        functionMapEntryPoint("vkCmdEndQuery"),
        functionMapEntryPoint("vkCmdEndRenderPass"),
        functionMapEntryPoint("vkCmdExecuteCommands"),
        functionMapEntryPoint("vkCmdFillBuffer"),
        functionMapEntryPoint("vkCmdNextSubpass"),
        functionMapEntryPoint("vkCmdPipelineBarrier"),
        functionMapEntryPoint("vkCmdPushConstants"),
        functionMapEntryPoint("vkCmdResetEvent"),
        functionMapEntryPoint("vkCmdResetQueryPool"),
        functionMapEntryPoint("vkCmdResolveImage"),
        functionMapEntryPoint("vkCmdSetBlendConstants"),
        functionMapEntryPoint("vkCmdSetDepthBias"),
        functionMapEntryPoint("vkCmdSetDepthBounds"),
        functionMapEntryPoint("vkCmdSetEvent"),
        functionMapEntryPoint("vkCmdSetLineWidth"),
        functionMapEntryPoint("vkCmdSetScissor"),
        functionMapEntryPoint("vkCmdSetStencilCompareMask"),
        functionMapEntryPoint("vkCmdSetStencilReference"),
        functionMapEntryPoint("vkCmdSetStencilWriteMask"),
        functionMapEntryPoint("vkCmdSetViewport"),
        functionMapEntryPoint("vkCmdUpdateBuffer"),
        functionMapEntryPoint("vkCmdWaitEvents"),
        functionMapEntryPoint("vkCmdWriteTimestamp"),
        functionMapEntryPoint("vkCreateBuffer"),
        functionMapEntryPoint("vkCreateBufferView"),
        functionMapEntryPoint("vkCreateCommandPool"),
        functionMapEntryPoint("vkCreateComputePipelines"),
        functionMapEntryPoint("vkCreateDescriptorPool"),
        functionMapEntryPoint("vkCreateDescriptorSetLayout"),
        functionMapEntryPoint("vkCreateEvent"),
        functionMapEntryPoint("vkCreateFence"),
        functionMapEntryPoint("vkCreateFramebuffer"),
        functionMapEntryPoint("vkCreateGraphicsPipelines"),
        functionMapEntryPoint("vkCreateImage"),
        functionMapEntryPoint("vkCreateImageView"),
        functionMapEntryPoint("vkCreatePipelineCache"),
        functionMapEntryPoint("vkCreatePipelineLayout"),
        functionMapEntryPoint("vkCreateQueryPool"),
        functionMapEntryPoint("vkCreateRenderPass"),
        functionMapEntryPoint("vkCreateSampler"),
        functionMapEntryPoint("vkCreateSemaphore"),
        functionMapEntryPoint("vkCreateShaderModule"),
        functionMapEntryPoint("vkDestroyBuffer"),
        functionMapEntryPoint("vkDestroyBufferView"),
        functionMapEntryPoint("vkDestroyCommandPool"),
        functionMapEntryPoint("vkDestroyDescriptorPool"),
        functionMapEntryPoint("vkDestroyDescriptorSetLayout"),
        functionMapEntryPoint("vkDestroyDevice"),
        functionMapEntryPoint("vkDestroyEvent"),
        functionMapEntryPoint("vkDestroyFence"),
        functionMapEntryPoint("vkDestroyFramebuffer"),
        functionMapEntryPoint("vkDestroyImage"),
        functionMapEntryPoint("vkDestroyImageView"),
        functionMapEntryPoint("vkDestroyPipeline"),
        functionMapEntryPoint("vkDestroyPipelineCache"),
        functionMapEntryPoint("vkDestroyPipelineLayout"),
        functionMapEntryPoint("vkDestroyQueryPool"),
        functionMapEntryPoint("vkDestroyRenderPass"),
        functionMapEntryPoint("vkDestroySampler"),
        functionMapEntryPoint("vkDestroySemaphore"),
        functionMapEntryPoint("vkDestroyShaderModule"),
        functionMapEntryPoint("vkDeviceWaitIdle"),
        functionMapEntryPoint("vkEndCommandBuffer"),
        functionMapEntryPoint("vkFlushMappedMemoryRanges"),
        functionMapEntryPoint("vkFreeCommandBuffers"),
        functionMapEntryPoint("vkFreeDescriptorSets"),
        functionMapEntryPoint("vkFreeMemory"),
        functionMapEntryPoint("vkGetBufferMemoryRequirements"),
        functionMapEntryPoint("vkGetDeviceMemoryCommitment"),
        functionMapEntryPoint("vkGetDeviceProcAddr"),
        functionMapEntryPoint("vkGetDeviceQueue"),
        functionMapEntryPoint("vkGetEventStatus"),
        functionMapEntryPoint("vkGetFenceStatus"),
        functionMapEntryPoint("vkGetImageMemoryRequirements"),
        functionMapEntryPoint("vkGetImageSparseMemoryRequirements"),
        functionMapEntryPoint("vkGetImageSubresourceLayout"),
        functionMapEntryPoint("vkGetPipelineCacheData"),
        functionMapEntryPoint("vkGetQueryPoolResults"),
        functionMapEntryPoint("vkGetRenderAreaGranularity"),
        functionMapEntryPoint("vkInvalidateMappedMemoryRanges"),
        functionMapEntryPoint("vkMapMemory"),
        functionMapEntryPoint("vkMergePipelineCaches"),
        functionMapEntryPoint("vkQueueBindSparse"),
        functionMapEntryPoint("vkQueueSubmit"),
        functionMapEntryPoint("vkQueueWaitIdle"),
        functionMapEntryPoint("vkResetCommandBuffer"),
        functionMapEntryPoint("vkResetCommandPool"),
        functionMapEntryPoint("vkResetDescriptorPool"),
        functionMapEntryPoint("vkResetEvent"),
        functionMapEntryPoint("vkResetFences"),
        functionMapEntryPoint("vkSetEvent"),
        functionMapEntryPoint("vkUnmapMemory"),
        functionMapEntryPoint("vkUpdateDescriptorSets"),
        functionMapEntryPoint("vkWaitForFences"),
    });
};

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
    if (p_instance != .null_handle) {
        if (instance_pfn_map.get(name)) |pfn| return pfn;
        if (physical_device_pfn_map.get(name)) |pfn| return pfn;
        if (device_pfn_map.get(name)) |pfn| return pfn;
    }
    entryPointNotFoundErrorLog(.vkGetInstanceProcAddr, name);
    return null;
}

pub export fn strollCreateInstance(info: *const vk.InstanceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_instance: *vk.Instance) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateInstance);
    defer entryPointEndLogTrace();

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

pub export fn strollEnumerateInstanceExtensionProperties(p_layer_name: ?[*:0]const u8, property_count: *u32, properties: ?[*]vk.ExtensionProperties) callconv(vk.vulkan_call_conv) vk.Result {
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
    defer logger.getManager().deinit();

    entryPointBeginLogTrace(.vkDestroyInstance);
    defer entryPointEndLogTrace();

    const allocator = VulkanAllocator.init(callbacks, .instance).allocator();
    const dispatchable = Dispatchable(Instance).fromHandle(p_instance) catch |err| return errorLogger(err);
    dispatchable.object.deinit(allocator) catch |err| return errorLogger(err);
    dispatchable.destroy(allocator);
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

pub export fn strollCreateDevice(p_physical_device: vk.PhysicalDevice, info: *const vk.DeviceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_device: *vk.Device) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateDevice);
    defer entryPointEndLogTrace();

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

pub export fn strollGetPhysicalDeviceFormatProperties2KHR(p_physical_device: vk.PhysicalDevice, format: vk.Format, properties: *vk.FormatProperties2KHR) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceFormatProperties2KHR);
    defer entryPointEndLogTrace();

    if (properties.s_type != .format_properties_2) return;

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    properties.format_properties = physical_device.getFormatProperties(format) catch |err| return errorLogger(err);
}

pub export fn strollGetPhysicalDeviceFeatures(p_physical_device: vk.PhysicalDevice, features: *vk.PhysicalDeviceFeatures) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceFeatures);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    features.* = physical_device.features;
}

pub export fn strollGetPhysicalDeviceFeatures2KHR(p_physical_device: vk.PhysicalDevice, features: *vk.PhysicalDeviceFeatures2KHR) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceFeatures2KHR);
    defer entryPointEndLogTrace();

    if (features.s_type != .physical_device_features_2) return;

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    features.features = physical_device.features;
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

pub export fn strollGetPhysicalDeviceImageFormatProperties2KHR(p_physical_device: vk.PhysicalDevice, format_info: *vk.PhysicalDeviceImageFormatInfo2KHR, properties: *vk.ImageFormatProperties2KHR) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceImageFormatProperties2KHR);
    defer entryPointEndLogTrace();

    if (format_info.s_type != .physical_device_image_format_info_2) return .error_validation_failed;
    if (properties.s_type != .image_format_properties_2) return .error_validation_failed;

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);
    properties.image_format_properties = physical_device.getImageFormatProperties(
        format_info.format,
        format_info.type,
        format_info.tiling,
        format_info.usage,
        format_info.flags,
    ) catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollGetPhysicalDeviceProperties(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceProperties) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceProperties);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    properties.* = physical_device.props;
}

pub export fn strollGetPhysicalDeviceProperties2KHR(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceProperties2KHR) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceProperties2KHR);
    defer entryPointEndLogTrace();

    if (properties.s_type != .physical_device_properties_2) return;

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    properties.properties = physical_device.props;
}

pub export fn strollGetPhysicalDeviceMemoryProperties(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceMemoryProperties) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceMemoryProperties);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    properties.* = physical_device.mem_props;
}

pub export fn strollGetPhysicalDeviceMemoryProperties2KHR(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceMemoryProperties2KHR) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceMemoryProperties2KHR);
    defer entryPointEndLogTrace();

    if (properties.s_type != .physical_device_memory_properties_2) return;

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    properties.memory_properties = physical_device.mem_props;
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

pub export fn strollGetPhysicalDeviceQueueFamilyProperties2KHR(p_physical_device: vk.PhysicalDevice, count: *u32, properties: ?[*]vk.QueueFamilyProperties2KHR) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceQueueFamilyProperties2KHR);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    count.* = @intCast(physical_device.queue_family_props.items.len);
    if (properties) |p_props| {
        for (p_props[0..], physical_device.queue_family_props.items[0..], 0..count.*) |*props, device_props, _| {
            if (props.s_type != .queue_family_properties_2) continue;
            props.queue_family_properties = device_props;
        }
    }
}

pub export fn strollGetPhysicalDeviceSparseImageFormatProperties(
    p_physical_device: vk.PhysicalDevice,
    format: vk.Format,
    image_type: vk.ImageType,
    samples: vk.SampleCountFlags,
    usage: vk.ImageUsageFlags,
    tiling: vk.ImageTiling,
    count: *u32,
    properties: ?[*]vk.SparseImageFormatProperties,
) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceSparseImageFormatProperties);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);
    count.* = physical_device.getSparseImageFormatProperties(format, image_type, samples, tiling, usage, properties) catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollGetPhysicalDeviceSparseImageFormatProperties2KHR(
    p_physical_device: vk.PhysicalDevice,
    format_info: *const vk.PhysicalDeviceSparseImageFormatInfo2KHR,
    count: *u32,
    properties: ?[*]vk.SparseImageFormatProperties2KHR,
) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceSparseImageFormatProperties2KHR);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);
    count.* = physical_device.getSparseImageFormatProperties2(
        format_info.format,
        format_info.type,
        format_info.samples,
        format_info.tiling,
        format_info.usage,
        properties,
    ) catch |err| return toVkResult(err);
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

pub export fn strollAllocateCommandBuffers(p_device: vk.Device, info: *const vk.CommandBufferAllocateInfo, p_cmds: [*]vk.CommandBuffer) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkAllocateCommandBuffers);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

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

pub export fn strollAllocateDescriptorSets(p_device: vk.Device, info: *const vk.DescriptorSetAllocateInfo, p_sets: [*]vk.DescriptorSet) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkAllocateCommandBuffers);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    if (info.s_type != .descriptor_set_allocate_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(null, .command).allocator();

    const pool = NonDispatchable(DescriptorPool).fromHandleObject(info.descriptor_pool) catch |err| return toVkResult(err);
    for (0..info.descriptor_set_count) |i| {
        const layout = NonDispatchable(DescriptorSetLayout).fromHandleObject(info.p_set_layouts[i]) catch |err| return toVkResult(err);
        const set = pool.allocateDescriptorSet(layout) catch |err| return toVkResult(err);
        p_sets[i] = (NonDispatchable(DescriptorSet).wrap(allocator, set) catch |err| return toVkResult(err)).toVkHandle(vk.DescriptorSet);
    }

    return .success;
}

pub export fn strollAllocateMemory(p_device: vk.Device, info: *const vk.MemoryAllocateInfo, callbacks: ?*const vk.AllocationCallbacks, p_memory: *vk.DeviceMemory) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkAllocateMemory);
    defer entryPointEndLogTrace();

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

pub export fn strollCreateBuffer(p_device: vk.Device, info: *const vk.BufferCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_buffer: *vk.Buffer) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateBuffer);
    defer entryPointEndLogTrace();

    if (info.s_type != .buffer_create_info) {
        return .error_validation_failed;
    }
    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const buffer = device.createBuffer(allocator, info) catch |err| return toVkResult(err);
    p_buffer.* = (NonDispatchable(Buffer).wrap(allocator, buffer) catch |err| return toVkResult(err)).toVkHandle(vk.Buffer);
    return .success;
}

pub export fn strollCreateBufferView(p_device: vk.Device, info: *const vk.BufferViewCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_view: *vk.BufferView) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateBufferView);
    defer entryPointEndLogTrace();

    if (info.s_type != .buffer_view_create_info) {
        return .error_validation_failed;
    }
    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const view = device.createBufferView(allocator, info) catch |err| return toVkResult(err);
    p_view.* = (NonDispatchable(BufferView).wrap(allocator, view) catch |err| return toVkResult(err)).toVkHandle(vk.BufferView);
    return .success;
}

pub export fn strollCreateCommandPool(p_device: vk.Device, info: *const vk.CommandPoolCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_pool: *vk.CommandPool) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateCommandPool);
    defer entryPointEndLogTrace();

    if (info.s_type != .command_pool_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const pool = device.createCommandPool(allocator, info) catch |err| return toVkResult(err);
    p_pool.* = (NonDispatchable(CommandPool).wrap(allocator, pool) catch |err| return toVkResult(err)).toVkHandle(vk.CommandPool);
    return .success;
}

pub export fn strollCreateComputePipelines(p_device: vk.Device, p_cache: vk.PipelineCache, count: u32, infos: [*]const vk.ComputePipelineCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_pipelines: [*]vk.Pipeline) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateComputePipelines);
    defer entryPointEndLogTrace();

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();

    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const cache = if (p_cache == .null_handle) null else NonDispatchable(PipelineCache).fromHandleObject(p_cache) catch |err| return toVkResult(err);

    var global_res: vk.Result = .success;

    for (p_pipelines, infos, 0..count) |*p_pipeline, *info, _| {
        if (info.s_type != .compute_pipeline_create_info) {
            return .error_validation_failed;
        }

        // According to the Vulkan spec, section 9.4. Multiple Pipeline Creation
        // "When an application attempts to create many pipelines in a single command,
        //  it is possible that some subset may fail creation. In that case, the
        //  corresponding entries in the pPipelines output array will be filled with
        //  VK_NULL_HANDLE values. If any pipeline fails creation (for example, due to
        //  out of memory errors), the vkCreate*Pipelines commands will return an
        //  error code. The implementation will attempt to create all pipelines, and
        //  only return VK_NULL_HANDLE values for those that actually failed."
        p_pipeline.*, const local_res = blk: {
            const pipeline = device.createComputePipeline(allocator, cache, info) catch |err| break :blk .{ .null_handle, toVkResult(err) };
            const handle = NonDispatchable(Pipeline).wrap(allocator, pipeline) catch |err| {
                pipeline.destroy(allocator);
                break :blk .{ .null_handle, toVkResult(err) };
            };
            break :blk .{ handle.toVkHandle(vk.Pipeline), .success };
        };

        if (local_res != .success) {
            global_res = local_res;
        }
    }

    return global_res;
}

pub export fn strollCreateDescriptorPool(p_device: vk.Device, info: *const vk.DescriptorPoolCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_pool: *vk.DescriptorPool) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateDescriptorPool);
    defer entryPointEndLogTrace();

    if (info.s_type != .descriptor_pool_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const pool = device.createDescriptorPool(allocator, info) catch |err| return toVkResult(err);
    p_pool.* = (NonDispatchable(DescriptorPool).wrap(allocator, pool) catch |err| return toVkResult(err)).toVkHandle(vk.DescriptorPool);
    return .success;
}

pub export fn strollCreateDescriptorSetLayout(p_device: vk.Device, info: *const vk.DescriptorSetLayoutCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_layout: *vk.DescriptorSetLayout) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateDescriptorSetLayout);
    defer entryPointEndLogTrace();

    if (info.s_type != .descriptor_set_layout_create_info) {
        return .error_validation_failed;
    }

    // Device scoped because we're reference counting and layout may not be destroyed when vkDestroyDescriptorSetLayout is called
    const allocator = VulkanAllocator.init(callbacks, .device).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const layout = device.createDescriptorSetLayout(allocator, info) catch |err| return toVkResult(err);
    p_layout.* = (NonDispatchable(DescriptorSetLayout).wrap(allocator, layout) catch |err| return toVkResult(err)).toVkHandle(vk.DescriptorSetLayout);
    return .success;
}

pub export fn strollCreateEvent(p_device: vk.Device, info: *const vk.EventCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_event: *vk.Event) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateEvent);
    defer entryPointEndLogTrace();

    if (info.s_type != .event_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const event = device.createEvent(allocator, info) catch |err| return toVkResult(err);
    p_event.* = (NonDispatchable(Event).wrap(allocator, event) catch |err| return toVkResult(err)).toVkHandle(vk.Event);
    return .success;
}

pub export fn strollCreateFence(p_device: vk.Device, info: *const vk.FenceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_fence: *vk.Fence) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateFence);
    defer entryPointEndLogTrace();

    if (info.s_type != .fence_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const fence = device.createFence(allocator, info) catch |err| return toVkResult(err);
    p_fence.* = (NonDispatchable(Fence).wrap(allocator, fence) catch |err| return toVkResult(err)).toVkHandle(vk.Fence);
    return .success;
}

pub export fn strollCreateFramebuffer(p_device: vk.Device, info: *const vk.FramebufferCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_framebuffer: *vk.Framebuffer) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateFramebuffer);
    defer entryPointEndLogTrace();

    if (info.s_type != .framebuffer_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const framebuffer = device.createFramebuffer(allocator, info) catch |err| return toVkResult(err);
    p_framebuffer.* = (NonDispatchable(Framebuffer).wrap(allocator, framebuffer) catch |err| return toVkResult(err)).toVkHandle(vk.Framebuffer);
    return .success;
}

pub export fn strollCreateGraphicsPipelines(p_device: vk.Device, p_cache: vk.PipelineCache, count: u32, infos: [*]const vk.GraphicsPipelineCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_pipelines: [*]vk.Pipeline) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateGraphicsPipelines);
    defer entryPointEndLogTrace();

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const cache = if (p_cache == .null_handle) null else NonDispatchable(PipelineCache).fromHandleObject(p_cache) catch |err| return toVkResult(err);

    var global_res: vk.Result = .success;

    for (p_pipelines, infos, 0..count) |*p_pipeline, *info, _| {
        if (info.s_type != .graphics_pipeline_create_info) {
            return .error_validation_failed;
        }

        // According to the Vulkan spec, section 9.4. Multiple Pipeline Creation
        // "When an application attempts to create many pipelines in a single command,
        //  it is possible that some subset may fail creation. In that case, the
        //  corresponding entries in the pPipelines output array will be filled with
        //  VK_NULL_HANDLE values. If any pipeline fails creation (for example, due to
        //  out of memory errors), the vkCreate*Pipelines commands will return an
        //  error code. The implementation will attempt to create all pipelines, and
        //  only return VK_NULL_HANDLE values for those that actually failed."
        p_pipeline.*, const local_res = blk: {
            const pipeline = device.createGraphicsPipeline(allocator, cache, info) catch |err| break :blk .{ .null_handle, toVkResult(err) };
            const handle = NonDispatchable(Pipeline).wrap(allocator, pipeline) catch |err| {
                pipeline.destroy(allocator);
                break :blk .{ .null_handle, toVkResult(err) };
            };
            break :blk .{ handle.toVkHandle(vk.Pipeline), .success };
        };

        if (local_res != .success) {
            global_res = local_res;
        }
    }
    return global_res;
}

pub export fn strollCreateImage(p_device: vk.Device, info: *const vk.ImageCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_image: *vk.Image) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateImage);
    defer entryPointEndLogTrace();

    if (info.s_type != .image_create_info) {
        return .error_validation_failed;
    }
    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const image = device.createImage(allocator, info) catch |err| return toVkResult(err);
    p_image.* = (NonDispatchable(Image).wrap(allocator, image) catch |err| return toVkResult(err)).toVkHandle(vk.Image);
    return .success;
}

pub export fn strollCreateImageView(p_device: vk.Device, info: *const vk.ImageViewCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_image_view: *vk.ImageView) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateImageView);
    defer entryPointEndLogTrace();

    if (info.s_type != .image_view_create_info) {
        return .error_validation_failed;
    }
    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const image_view = device.createImageView(allocator, info) catch |err| return toVkResult(err);
    p_image_view.* = (NonDispatchable(ImageView).wrap(allocator, image_view) catch |err| return toVkResult(err)).toVkHandle(vk.ImageView);
    return .success;
}

pub export fn strollCreatePipelineCache(p_device: vk.Device, info: *const vk.PipelineCacheCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_cache: *vk.PipelineCache) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreatePipelineCache);
    defer entryPointEndLogTrace();

    if (info.s_type != .pipeline_cache_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const cache = device.createPipelineCache(allocator, info) catch |err| return toVkResult(err);
    p_cache.* = (NonDispatchable(PipelineCache).wrap(allocator, cache) catch |err| return toVkResult(err)).toVkHandle(vk.PipelineCache);
    return .success;
}

pub export fn strollCreatePipelineLayout(p_device: vk.Device, info: *const vk.PipelineLayoutCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_layout: *vk.PipelineLayout) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreatePipelineLayout);
    defer entryPointEndLogTrace();

    if (info.s_type != .pipeline_layout_create_info) {
        return .error_validation_failed;
    }

    // Device scoped because we're reference counting and layout may not be destroyed when vkDestroyPipelineLayout is called
    const allocator = VulkanAllocator.init(callbacks, .device).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const layout = device.createPipelineLayout(allocator, info) catch |err| return toVkResult(err);
    p_layout.* = (NonDispatchable(PipelineLayout).wrap(allocator, layout) catch |err| return toVkResult(err)).toVkHandle(vk.PipelineLayout);
    return .success;
}

pub export fn strollCreateQueryPool(p_device: vk.Device, info: *const vk.QueryPoolCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_pool: *vk.QueryPool) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateQueryPool);
    defer entryPointEndLogTrace();

    if (info.s_type != .query_pool_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const pool = device.createQueryPool(allocator, info) catch |err| return toVkResult(err);
    p_pool.* = (NonDispatchable(QueryPool).wrap(allocator, pool) catch |err| return toVkResult(err)).toVkHandle(vk.QueryPool);
    return .success;
}

pub export fn strollCreateRenderPass(p_device: vk.Device, info: *const vk.RenderPassCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_pass: *vk.RenderPass) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateRenderPass);
    defer entryPointEndLogTrace();

    if (info.s_type != .render_pass_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const pass = device.createRenderPass(allocator, info) catch |err| return toVkResult(err);
    p_pass.* = (NonDispatchable(RenderPass).wrap(allocator, pass) catch |err| return toVkResult(err)).toVkHandle(vk.RenderPass);
    return .success;
}

pub export fn strollCreateSampler(p_device: vk.Device, info: *const vk.SamplerCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_sampler: *vk.Sampler) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateSampler);
    defer entryPointEndLogTrace();

    if (info.s_type != .sampler_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const sampler = device.createSampler(allocator, info) catch |err| return toVkResult(err);
    p_sampler.* = (NonDispatchable(Sampler).wrap(allocator, sampler) catch |err| return toVkResult(err)).toVkHandle(vk.Sampler);
    return .success;
}

pub export fn strollCreateSemaphore(p_device: vk.Device, info: *const vk.SemaphoreCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_semaphore: *vk.Semaphore) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateSemaphore);
    defer entryPointEndLogTrace();

    if (info.s_type != .semaphore_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const semaphore = device.createSemaphore(allocator, info) catch |err| return toVkResult(err);
    p_semaphore.* = (NonDispatchable(BinarySemaphore).wrap(allocator, semaphore) catch |err| return toVkResult(err)).toVkHandle(vk.Semaphore);
    return .success;
}

pub export fn strollCreateShaderModule(p_device: vk.Device, info: *const vk.ShaderModuleCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_module: *vk.ShaderModule) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateShaderModule);
    defer entryPointEndLogTrace();

    if (info.s_type != .shader_module_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const module = device.createShaderModule(allocator, info) catch |err| return toVkResult(err);
    p_module.* = (NonDispatchable(ShaderModule).wrap(allocator, module) catch |err| return toVkResult(err)).toVkHandle(vk.ShaderModule);
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

pub export fn strollDestroyBufferView(p_device: vk.Device, p_view: vk.BufferView, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyBufferView);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(BufferView).fromHandle(p_view) catch |err| return errorLogger(err);
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

pub export fn strollDestroyDescriptorPool(p_device: vk.Device, p_pool: vk.DescriptorPool, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyDescriptorPool);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(DescriptorPool).fromHandle(p_pool) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollDestroyDescriptorSetLayout(p_device: vk.Device, p_layout: vk.DescriptorSetLayout, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyDescriptorLayout);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(DescriptorSetLayout).fromHandle(p_layout) catch |err| return errorLogger(err);
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

pub export fn strollDestroyEvent(p_device: vk.Device, p_event: vk.Event, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyEvent);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(Event).fromHandle(p_event) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollDestroyFence(p_device: vk.Device, p_fence: vk.Fence, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyFence);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(Fence).fromHandle(p_fence) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollDestroyFramebuffer(p_device: vk.Device, p_framebuffer: vk.Framebuffer, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyFramebuffer);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(Framebuffer).fromHandle(p_framebuffer) catch |err| return errorLogger(err);
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

pub export fn strollDestroyPipeline(p_device: vk.Device, p_pipeline: vk.Pipeline, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyPipeline);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(Pipeline).fromHandle(p_pipeline) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollDestroyPipelineCache(p_device: vk.Device, p_cache: vk.PipelineCache, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyPipelineCache);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(PipelineCache).fromHandle(p_cache) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollDestroyPipelineLayout(p_device: vk.Device, p_layout: vk.PipelineLayout, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyPipelineCache);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(PipelineLayout).fromHandle(p_layout) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollDestroyQueryPool(p_device: vk.Device, p_pool: vk.QueryPool, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyQueryPool);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(QueryPool).fromHandle(p_pool) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollDestroyRenderPass(p_device: vk.Device, p_pass: vk.RenderPass, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyRenderPass);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(RenderPass).fromHandle(p_pass) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollDestroySampler(p_device: vk.Device, p_sampler: vk.Sampler, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroySampler);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(Sampler).fromHandle(p_sampler) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollDestroySemaphore(p_device: vk.Device, p_semaphore: vk.Semaphore, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroySemaphore);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(BinarySemaphore).fromHandle(p_semaphore) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollDestroyShaderModule(p_device: vk.Device, p_module: vk.ShaderModule, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyShaderModule);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(ShaderModule).fromHandle(p_module) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn strollDeviceWaitIdle(p_device: vk.Device) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkDeviceWaitIdle);
    defer entryPointEndLogTrace();

    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    device.waitIdle() catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollFlushMappedMemoryRanges(p_device: vk.Device, count: u32, p_ranges: [*]const vk.MappedMemoryRange) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkFlushMappedMemoryRanges);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    for (p_ranges, 0..count) |range, _| {
        const memory = NonDispatchable(DeviceMemory).fromHandleObject(range.memory) catch |err| return toVkResult(err);
        memory.flushRange(range.offset, range.size) catch |err| return toVkResult(err);
    }
    return .success;
}

pub export fn strollFreeCommandBuffers(p_device: vk.Device, p_pool: vk.CommandPool, count: u32, p_cmds: [*]const vk.CommandBuffer) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkFreeCommandBuffers);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const pool = NonDispatchable(CommandPool).fromHandleObject(p_pool) catch |err| return errorLogger(err);
    const cmds: [*]*Dispatchable(CommandBuffer) = @ptrCast(@constCast(p_cmds));
    pool.freeCommandBuffers(cmds[0..count]) catch |err| return errorLogger(err);
}

pub export fn strollFreeDescriptorSets(p_device: vk.Device, p_pool: vk.CommandPool, count: u32, p_sets: [*]const vk.DescriptorSet) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkFreeDescriptorSets);
    defer entryPointEndLogTrace();

    const allocator = VulkanAllocator.init(null, .command).allocator();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const pool = NonDispatchable(DescriptorPool).fromHandleObject(p_pool) catch |err| return errorLogger(err);
    for (p_sets[0..], 0..count) |p_set, _| {
        const non_dispatchable_set = NonDispatchable(DescriptorSet).fromHandle(p_set) catch |err| return errorLogger(err);
        pool.freeDescriptorSet(non_dispatchable_set.object) catch |err| return errorLogger(err);
        non_dispatchable_set.destroy(allocator);
    }
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

pub export fn strollGetDeviceMemoryCommitment(p_device: vk.Device, p_memory: vk.DeviceMemory, committed_memory: *vk.DeviceSize) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetDeviceMemoryCommitment);
    defer entryPointEndLogTrace();

    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return errorLogger(err);
    const memory = Dispatchable(DeviceMemory).fromHandleObject(p_memory) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = device;
    _ = memory;
    _ = committed_memory;
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

pub export fn strollGetEventStatus(p_device: vk.Device, p_event: vk.Event) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetEventStatus);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const event = NonDispatchable(Event).fromHandleObject(p_event) catch |err| return toVkResult(err);
    event.getStatus() catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollGetFenceStatus(p_device: vk.Device, p_fence: vk.Fence) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetFenceStatus);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const fence = NonDispatchable(Fence).fromHandleObject(p_fence) catch |err| return toVkResult(err);
    fence.getStatus() catch |err| return toVkResult(err);
    return .event_set;
}

pub export fn strollGetImageMemoryRequirements(p_device: vk.Device, p_image: vk.Image, requirements: *vk.MemoryRequirements) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetImageMemoryRequirements);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const image = NonDispatchable(Image).fromHandleObject(p_image) catch |err| return errorLogger(err);
    image.getMemoryRequirements(requirements);
}

pub export fn strollGetImageSparseMemoryRequirements(p_device: vk.Device, p_image: vk.Image, requirements: *vk.SparseImageMemoryRequirements) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetImageSparseMemoryRequirements);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const image = NonDispatchable(Image).fromHandleObject(p_image) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = image;
    _ = requirements;
}

pub export fn strollGetImageSubresourceLayout(p_device: vk.Device, p_image: vk.Image, subresource: *const vk.ImageSubresource, layout: *vk.SubresourceLayout) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetImageSubresourceLayout);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const image = NonDispatchable(Image).fromHandleObject(p_image) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = image;
    _ = subresource;
    _ = layout;
}

pub export fn strollGetPipelineCacheData(p_device: vk.Device, p_cache: vk.PipelineCache, size: *usize, data: *anyopaque) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetPipelineCacheData);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    notImplementedWarning();

    _ = p_cache;
    _ = size;
    _ = data;

    return .error_unknown;
}

pub export fn strollGetQueryPoolResults(
    p_device: vk.Device,
    p_pool: vk.QueryPool,
    first: u32,
    count: u32,
    size: usize,
    data: *anyopaque,
    stride: vk.DeviceSize,
    flags: vk.QueryResultFlags,
) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetQueryPoolResults);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    notImplementedWarning();

    _ = p_pool;
    _ = first;
    _ = count;
    _ = size;
    _ = data;
    _ = stride;
    _ = flags;

    return .error_unknown;
}

pub export fn strollGetRenderAreaGranularity(p_device: vk.Device, p_pass: vk.RenderPass, granularity: *vk.Extent2D) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetRenderAreaGranularity);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = p_pass;
    _ = granularity;
}

pub export fn strollInvalidateMappedMemoryRanges(p_device: vk.Device, count: u32, p_ranges: [*]const vk.MappedMemoryRange) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkInvalidateMappedMemoryRanges);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    for (p_ranges, 0..count) |range, _| {
        const memory = NonDispatchable(DeviceMemory).fromHandleObject(range.memory) catch |err| return toVkResult(err);
        memory.invalidateRange(range.offset, range.size) catch |err| return toVkResult(err);
    }
    return .success;
}

pub export fn strollMapMemory(p_device: vk.Device, p_memory: vk.DeviceMemory, offset: vk.DeviceSize, size: vk.DeviceSize, _: vk.MemoryMapFlags, pp_data: *?*anyopaque) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkMapMemory);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const device_memory = NonDispatchable(DeviceMemory).fromHandleObject(p_memory) catch |err| return toVkResult(err);
    pp_data.* = device_memory.map(offset, size) catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollMergePipelineCaches(p_device: vk.Device, p_dst: vk.PipelineCache, count: u32, p_srcs: [*]const vk.PipelineCache) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkMergePipelineCaches);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    notImplementedWarning();

    _ = p_dst;
    _ = count;
    _ = p_srcs;

    return .error_unknown;
}

pub export fn strollResetCommandPool(p_device: vk.Device, p_pool: vk.CommandPool, flags: vk.CommandPoolResetFlags) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkResetCommandPool);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);
    const pool = NonDispatchable(CommandPool).fromHandleObject(p_pool) catch |err| return toVkResult(err);

    notImplementedWarning();

    _ = pool;
    _ = flags;

    return .error_unknown;
}

pub export fn strollResetDescriptorPool(p_device: vk.Device, p_pool: vk.DescriptorPool, flags: vk.CommandPoolResetFlags) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkResetDescriptorPool);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);
    const pool = NonDispatchable(DescriptorPool).fromHandleObject(p_pool) catch |err| return toVkResult(err);

    notImplementedWarning();

    _ = pool;
    _ = flags;

    return .error_unknown;
}

pub export fn strollResetEvent(p_device: vk.Device, p_event: vk.Fence) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkResetEvent);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const event = NonDispatchable(Event).fromHandleObject(p_event) catch |err| return toVkResult(err);
    event.reset() catch |err| return toVkResult(err);
    return .success;
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

pub export fn strollSetEvent(p_device: vk.Device, p_event: vk.Fence) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkSetEvent);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const event = NonDispatchable(Event).fromHandleObject(p_event) catch |err| return toVkResult(err);
    event.signal() catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollUnmapMemory(p_device: vk.Device, p_memory: vk.DeviceMemory) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkUnmapMemory);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const device_memory = NonDispatchable(DeviceMemory).fromHandleObject(p_memory) catch |err| return errorLogger(err);
    device_memory.unmap();
}

pub export fn strollUpdateDescriptorSets(p_device: vk.Device, write_count: u32, writes: [*]const vk.WriteDescriptorSet, copy_count: u32, copies: [*]const vk.CopyDescriptorSet) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkUpdateDescriptorSets);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    for (writes, 0..write_count) |write, _| {
        const set = NonDispatchable(DescriptorSet).fromHandleObject(write.dst_set) catch |err| return errorLogger(err);
        set.write(write) catch |err| return errorLogger(err);
    }

    for (copies, 0..copy_count) |copy, _| {
        const set = NonDispatchable(DescriptorSet).fromHandleObject(copy.dst_set) catch |err| return errorLogger(err);
        set.copy(copy) catch |err| return errorLogger(err);
    }
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

pub export fn strollBeginCommandBuffer(p_cmd: vk.CommandBuffer, info: *const vk.CommandBufferBeginInfo) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkBeginCommandBuffer);
    defer entryPointEndLogTrace();

    if (info.s_type != .command_buffer_begin_info) {
        return .error_validation_failed;
    }
    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return toVkResult(err);
    cmd.begin(info) catch |err| return toVkResult(err);
    return .success;
}

pub export fn strollCmdBeginQuery(p_cmd: vk.CommandBuffer, p_pool: vk.QueryPool, query: u32, flags: vk.QueryControlFlags) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdBeginQuery);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = p_pool;
    _ = query;
    _ = flags;
}

pub export fn strollCmdBeginRenderPass(p_cmd: vk.CommandBuffer, info: *const vk.RenderPassBeginInfo, contents: vk.SubpassContents) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdBeginRenderPass);
    defer entryPointEndLogTrace();

    if (info.s_type != .render_pass_begin_info) {
        return errorLogger(VkError.ValidationFailed);
    }
    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = contents;
}

pub export fn strollCmdBindDescriptorSets(
    p_cmd: vk.CommandBuffer,
    bind_point: vk.PipelineBindPoint,
    layout: vk.PipelineLayout,
    first: u32,
    count: u32,
    sets: [*]const vk.DescriptorSet,
    dynamic_offset_count: u32,
    dynamic_offsets: [*]const u32,
) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdBindDescriptorSets);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.bindDescriptorSets(bind_point, first, sets[0..count], dynamic_offsets[0..dynamic_offset_count]) catch |err| return errorLogger(err);

    _ = layout;
}

pub export fn strollCmdBindIndexBuffer(p_cmd: vk.CommandBuffer, p_buffer: vk.Buffer, offset: vk.DeviceSize, index_type: vk.IndexType) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdBindIndexBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const buffer = NonDispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = buffer;
    _ = offset;
    _ = index_type;
}

pub export fn strollCmdBindPipeline(p_cmd: vk.CommandBuffer, bind_point: vk.PipelineBindPoint, p_pipeline: vk.Pipeline) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdBindPipeline);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const pipeline = Dispatchable(Pipeline).fromHandleObject(p_pipeline) catch |err| return errorLogger(err);
    cmd.bindPipeline(bind_point, pipeline) catch |err| return errorLogger(err);
}

pub export fn strollCmdBindVertexBuffers(p_cmd: vk.CommandBuffer, first: u32, count: u32, p_buffers: [*]const vk.Buffer, offsets: [*]const vk.DeviceSize) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdBindVertexBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = first;
    _ = count;
    _ = p_buffers;
    _ = offsets;
}

pub export fn strollCmdBlitImage(
    p_cmd: vk.CommandBuffer,
    p_src_image: vk.Image,
    src_layout: vk.ImageLayout,
    p_dst_image: vk.Image,
    dst_layout: vk.ImageLayout,
    count: u32,
    regions: [*]const vk.ImageBlit,
    filter: vk.Filter,
) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdBlitImage);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const src = NonDispatchable(Image).fromHandleObject(p_src_image) catch |err| return errorLogger(err);
    const dst = NonDispatchable(Image).fromHandleObject(p_dst_image) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = src;
    _ = src_layout;
    _ = dst;
    _ = dst_layout;
    _ = count;
    _ = regions;
    _ = filter;
}

pub export fn strollCmdClearAttachments(p_cmd: vk.CommandBuffer, attachment_count: u32, attachments: [*]const vk.ClearAttachment, rect_count: u32, rects: [*]const vk.ClearRect) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdClearAttachments);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = attachment_count;
    _ = attachments;
    _ = rect_count;
    _ = rects;
}

pub export fn strollCmdClearColorImage(p_cmd: vk.CommandBuffer, p_image: vk.Image, layout: vk.ImageLayout, color: *const vk.ClearColorValue, count: u32, ranges: [*]const vk.ImageSubresourceRange) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdClearColorImage);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const image = NonDispatchable(Image).fromHandleObject(p_image) catch |err| return errorLogger(err);
    cmd.clearColorImage(image, layout, color, ranges[0..count]) catch |err| return errorLogger(err);
}

pub export fn strollCmdClearDepthStencilImage(p_cmd: vk.CommandBuffer, p_image: vk.Image, layout: vk.ImageLayout, stencil: *const vk.ClearDepthStencilValue, count: u32, ranges: [*]const vk.ImageSubresourceRange) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdClearDepthStencilImage);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const image = NonDispatchable(Image).fromHandleObject(p_image) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = image;
    _ = layout;
    _ = stencil;
    _ = count;
    _ = ranges;
}

pub export fn strollCmdCopyBuffer(p_cmd: vk.CommandBuffer, p_src: vk.Buffer, p_dst: vk.Buffer, count: u32, regions: [*]const vk.BufferCopy) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdCopyBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const src = NonDispatchable(Buffer).fromHandleObject(p_src) catch |err| return errorLogger(err);
    const dst = NonDispatchable(Buffer).fromHandleObject(p_dst) catch |err| return errorLogger(err);
    cmd.copyBuffer(src, dst, regions[0..count]) catch |err| return errorLogger(err);
}

pub export fn strollCmdCopyBufferToImage(p_cmd: vk.CommandBuffer, p_src: vk.Buffer, p_dst: vk.Image, layout: vk.ImageLayout, count: u32, regions: [*]const vk.BufferImageCopy) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdCopyBufferToImage);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const src = NonDispatchable(Buffer).fromHandleObject(p_src) catch |err| return errorLogger(err);
    const dst = NonDispatchable(Image).fromHandleObject(p_dst) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = src;
    _ = dst;
    _ = layout;
    _ = count;
    _ = regions;
}

pub export fn strollCmdCopyImage(p_cmd: vk.CommandBuffer, p_src: vk.Image, src_layout: vk.ImageLayout, p_dst: vk.Image, dst_layout: vk.ImageLayout, count: u32, regions: [*]const vk.ImageCopy) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdCopyImage);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const src = NonDispatchable(Image).fromHandleObject(p_src) catch |err| return errorLogger(err);
    const dst = NonDispatchable(Image).fromHandleObject(p_dst) catch |err| return errorLogger(err);
    cmd.copyImage(src, src_layout, dst, dst_layout, regions[0..count]) catch |err| return errorLogger(err);
}

pub export fn strollCmdCopyImageToBuffer(p_cmd: vk.CommandBuffer, p_src: vk.Image, layout: vk.ImageLayout, p_dst: vk.Buffer, count: u32, regions: [*]const vk.BufferImageCopy) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdCopyImageToBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const src = NonDispatchable(Image).fromHandleObject(p_src) catch |err| return errorLogger(err);
    const dst = NonDispatchable(Buffer).fromHandleObject(p_dst) catch |err| return errorLogger(err);
    cmd.copyImageToBuffer(src, layout, dst, regions[0..count]) catch |err| return errorLogger(err);
}

pub export fn strollCmdCopyQueryPoolResults(p_cmd: vk.CommandBuffer, p_pool: vk.QueryPool, first: u32, count: u32, p_dst: vk.Buffer, offset: vk.DeviceSize, stride: vk.DeviceSize, flags: vk.QueryResultFlags) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdCopyQueryPoolResults);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const dst = NonDispatchable(Image).fromHandleObject(p_dst) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = p_pool;
    _ = first;
    _ = count;
    _ = dst;
    _ = offset;
    _ = stride;
    _ = flags;
}

pub export fn strollCmdDispatch(p_cmd: vk.CommandBuffer, group_count_x: u32, group_count_y: u32, group_count_z: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdDispatch);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = group_count_x;
    _ = group_count_y;
    _ = group_count_z;
}

pub export fn strollCmdDispatchIndirect(p_cmd: vk.CommandBuffer, p_buffer: vk.Buffer, offset: vk.DeviceSize) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdDispatchIndirect);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const buffer = NonDispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = buffer;
    _ = offset;
}

pub export fn strollCmdDraw(p_cmd: vk.CommandBuffer, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdDraw);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = vertex_count;
    _ = instance_count;
    _ = first_vertex;
    _ = first_instance;
}

pub export fn strollCmdDrawIndexed(p_cmd: vk.CommandBuffer, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: u32, first_instance: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdDrawIndexed);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = index_count;
    _ = instance_count;
    _ = first_index;
    _ = vertex_offset;
    _ = first_instance;
}

pub export fn strollCmdDrawIndexedIndirect(p_cmd: vk.CommandBuffer, p_buffer: vk.Buffer, offset: vk.DeviceSize, count: u32, stride: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdDrawIndexedIndirect);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const buffer = Dispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = buffer;
    _ = offset;
    _ = count;
    _ = stride;
}

pub export fn strollCmdDrawIndirect(p_cmd: vk.CommandBuffer, p_buffer: vk.Buffer, offset: vk.DeviceSize, count: u32, stride: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdDrawIndirect);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const buffer = Dispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = buffer;
    _ = offset;
    _ = count;
    _ = stride;
}

pub export fn strollCmdEndQuery(p_cmd: vk.CommandBuffer, p_pool: vk.QueryPool, query: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdEndQuery);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = p_pool;
    _ = query;
}

pub export fn strollCmdEndRenderPass(p_cmd: vk.CommandBuffer) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdEndRenderPass);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
}

pub export fn strollCmdExecuteCommands(p_cmd: vk.CommandBuffer, count: u32, p_cmds: [*]const vk.CommandBuffer) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdExecuteCommands);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = count;
    _ = p_cmds;
}

pub export fn strollCmdFillBuffer(p_cmd: vk.CommandBuffer, p_buffer: vk.Buffer, offset: vk.DeviceSize, size: vk.DeviceSize, data: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdFillBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const buffer = NonDispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);
    cmd.fillBuffer(buffer, offset, size, data) catch |err| return errorLogger(err);
}

pub export fn strollCmdNextSubpass(p_cmd: vk.CommandBuffer, contents: vk.SubpassContents) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdNextSubpass);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = contents;
}

pub export fn strollCmdPipelineBarrier(
    p_cmd: vk.CommandBuffer,
    src_stage_mask: vk.PipelineStageFlags,
    dst_stage_mask: vk.PipelineStageFlags,
    dependency_flags: vk.DependencyFlags,
    memory_barrier_count: u32,
    memory_barriers: [*]const vk.MemoryBarrier,
    buffer_memory_barrier_count: u32,
    buffer_memory_barriers: [*]const vk.BufferMemoryBarrier,
    image_memory_barrier_count: u32,
    image_memory_barriers: [*]const vk.ImageMemoryBarrier,
) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdPipelineBarrier);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = src_stage_mask;
    _ = dst_stage_mask;
    _ = dependency_flags;
    _ = memory_barrier_count;
    _ = memory_barriers;
    _ = buffer_memory_barrier_count;
    _ = buffer_memory_barriers;
    _ = image_memory_barrier_count;
    _ = image_memory_barriers;
}

pub export fn strollCmdPushConstants(p_cmd: vk.CommandBuffer, layout: vk.PipelineLayout, flags: vk.ShaderStageFlags, offset: u32, size: u32, values: *const anyopaque) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdPushConstants);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = layout;
    _ = flags;
    _ = offset;
    _ = size;
    _ = values;
}

pub export fn strollCmdResetQueryPool(p_cmd: vk.CommandBuffer, p_pool: vk.QueryPool, first: u32, count: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdResetQueryPool);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = p_pool;
    _ = first;
    _ = count;
}

pub export fn strollCmdResetEvent(p_cmd: vk.CommandBuffer, p_event: vk.Event, stage_mask: vk.PipelineStageFlags) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdResetEvent);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const event = NonDispatchable(Event).fromHandleObject(p_event) catch |err| return errorLogger(err);
    cmd.resetEvent(event, stage_mask) catch |err| return errorLogger(err);
}

pub export fn strollCmdResolveImage(
    p_cmd: vk.CommandBuffer,
    p_src: vk.Image,
    src_layout: vk.ImageLayout,
    p_dst: vk.Image,
    dst_layout: vk.ImageLayout,
    count: u32,
    regions: [*]const vk.ImageResolve,
) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdResolveImage);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const src = Dispatchable(Image).fromHandleObject(p_src) catch |err| return errorLogger(err);
    const dst = Dispatchable(Image).fromHandleObject(p_dst) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = src;
    _ = src_layout;
    _ = dst;
    _ = dst_layout;
    _ = count;
    _ = regions;
}

pub export fn strollCmdSetBlendConstants(p_cmd: vk.CommandBuffer, p_constants: [*]f32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetBlendConstants);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const constants = [4]f32{ p_constants[0], p_constants[1], p_constants[2], p_constants[3] };

    notImplementedWarning();

    _ = cmd;
    _ = constants;
}

pub export fn strollCmdSetDepthBias(p_cmd: vk.CommandBuffer, constant_factor: f32, clamp: f32, slope_factor: f32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetDepthBias);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = constant_factor;
    _ = clamp;
    _ = slope_factor;
}

pub export fn strollCmdSetDepthBounds(p_cmd: vk.CommandBuffer, min: f32, max: f32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetDepthBounds);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = min;
    _ = max;
}

pub export fn strollCmdSetEvent(p_cmd: vk.CommandBuffer, p_event: vk.Event, stage_mask: vk.PipelineStageFlags) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetEvent);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const event = NonDispatchable(Event).fromHandleObject(p_event) catch |err| return errorLogger(err);
    cmd.setEvent(event, stage_mask) catch |err| return errorLogger(err);
}

pub export fn strollCmdSetLineWidth(p_cmd: vk.CommandBuffer, width: f32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetLineWidth);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = width;
}

pub export fn strollCmdSetScissor(p_cmd: vk.CommandBuffer, first: u32, count: u32, scissors: [*]const vk.Rect2D) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetScissor);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = first;
    _ = count;
    _ = scissors;
}

pub export fn strollCmdSetStencilCompareMask(p_cmd: vk.CommandBuffer, face_mask: vk.StencilFaceFlags, compare_mask: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetStencilCompareMask);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = face_mask;
    _ = compare_mask;
}

pub export fn strollCmdSetStencilReference(p_cmd: vk.CommandBuffer, face_mask: vk.StencilFaceFlags, reference: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetStencilReference);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = face_mask;
    _ = reference;
}

pub export fn strollCmdSetStencilWriteMask(p_cmd: vk.CommandBuffer, face_mask: vk.StencilFaceFlags, write_mask: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetStencilWriteMask);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = face_mask;
    _ = write_mask;
}

pub export fn strollCmdSetViewport(p_cmd: vk.CommandBuffer, first: u32, count: u32, viewports: [*]const vk.Viewport) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetViewport);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = first;
    _ = count;
    _ = viewports;
}

pub export fn strollCmdUpdateBuffer(p_cmd: vk.CommandBuffer, p_buffer: vk.Buffer, offset: vk.DeviceSize, size: vk.DeviceSize, data: *const anyopaque) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdUpdateBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const buffer = Dispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = buffer;
    _ = offset;
    _ = size;
    _ = data;
}

pub export fn strollCmdWaitEvents(
    p_cmd: vk.CommandBuffer,
    count: u32,
    p_events: [*]const vk.Event,
    src_stage_mask: vk.PipelineStageFlags,
    dst_stage_mask: vk.PipelineStageFlags,
    memory_barrier_count: u32,
    memory_barriers: [*]const vk.MemoryBarrier,
    buffer_memory_barrier_count: u32,
    buffer_memory_barriers: [*]const vk.BufferMemoryBarrier,
    image_memory_barrier_count: u32,
    image_memory_barriers: [*]const vk.ImageMemoryBarrier,
) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdWaitEvents);
    defer entryPointEndLogTrace();

    _ = count;
    _ = p_events;
    _ = src_stage_mask;
    _ = dst_stage_mask;
    _ = memory_barrier_count;
    _ = memory_barriers;
    _ = buffer_memory_barrier_count;
    _ = buffer_memory_barriers;
    _ = image_memory_barrier_count;
    _ = image_memory_barriers;
    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    _ = cmd;
}

pub export fn strollCmdWriteTimestamp(p_cmd: vk.CommandBuffer, stage: vk.PipelineStageFlags, p_pool: vk.QueryPool, query: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdWriteTimestamp);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);

    notImplementedWarning();

    _ = cmd;
    _ = stage;
    _ = p_pool;
    _ = query;
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
