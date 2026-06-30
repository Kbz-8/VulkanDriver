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

pub const SurfaceKHR = @import("wsi/SurfaceKHR.zig");
pub const SwapchainKHR = @import("wsi/SwapchainKHR.zig");

const has_wayland = switch (builtin.os.tag) {
    .linux, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

pub const WaylandSurfaceKHR = if (has_wayland) @import("wsi/WaylandSurfaceKHR.zig") else undefined;

inline fn entryPointBeginLogTrace(comptime scope: @EnumLiteral()) void {
    std.log.scoped(scope).debug("Calling {s}...", .{@tagName(scope)});
}

inline fn entryPointEndLogTrace() void {}

inline fn notImplementedWarning() void {
    logger.fixme("function not yet implemented", .{});
}

fn wrapNonDispatchable(comptime T: type, allocator: std.mem.Allocator, object: *T, comptime VkT: type) VkError!VkT {
    const handle = NonDispatchable(T).wrap(allocator, object) catch |err| {
        object.destroy(allocator);
        return err;
    };
    return handle.toVkHandle(VkT);
}

fn functionMapEntryPoint(comptime name: []const u8) struct { []const u8, vk.PfnVoidFunction } {
    // Mapping 'vkFnName' to 'apeFnName'
    const ape_name = std.fmt.comptimePrint("ape{s}", .{name[2..]});

    return if (std.meta.hasFn(@This(), name))
        .{ name, @as(vk.PfnVoidFunction, @ptrCast(&@field(@This(), name))) }
    else if (std.meta.hasFn(@This(), ape_name))
        .{ name, @as(vk.PfnVoidFunction, @ptrCast(&@field(@This(), ape_name))) }
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
    functionMapEntryPoint("vkEnumerateInstanceLayerProperties"),
    //functionMapEntryPoint("vkEnumerateInstanceVersion"),
    functionMapEntryPoint("vkGetInstanceProcAddr"),
});

const instance_pfn_map = std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
    functionMapEntryPoint("vkCreateWaylandSurfaceKHR"),
    functionMapEntryPoint("vkDestroyInstance"),
    functionMapEntryPoint("vkDestroySurfaceKHR"),
    functionMapEntryPoint("vkEnumeratePhysicalDeviceGroups"),
    functionMapEntryPoint("vkEnumeratePhysicalDeviceGroupsKHR"),
    functionMapEntryPoint("vkEnumeratePhysicalDevices"),
    functionMapEntryPoint("vkGetDeviceProcAddr"),
});

const physical_device_pfn_map = std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
    functionMapEntryPoint("vkCreateDevice"),
    functionMapEntryPoint("vkEnumerateDeviceExtensionProperties"),
    functionMapEntryPoint("vkEnumerateDeviceLayerProperties"),
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
    functionMapEntryPoint("vkGetPhysicalDeviceSurfaceCapabilitiesKHR"),
    functionMapEntryPoint("vkGetPhysicalDeviceSurfaceFormatsKHR"),
    functionMapEntryPoint("vkGetPhysicalDeviceSurfacePresentModesKHR"),
    functionMapEntryPoint("vkGetPhysicalDeviceSurfaceSupportKHR"),
    functionMapEntryPoint("vkGetPhysicalDeviceWaylandPresentationSupportKHR"),
});

const device_pfn_map = block: {
    @setEvalBranchQuota(65535);
    break :block std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
        functionMapEntryPoint("vkAcquireNextImageKHR"),
        functionMapEntryPoint("vkAcquireNextImage2KHR"),
        functionMapEntryPoint("vkAllocateCommandBuffers"),
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
        functionMapEntryPoint("vkCmdDispatchBase"),
        functionMapEntryPoint("vkCmdDispatchBaseKHR"),
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
        functionMapEntryPoint("vkCmdSetDeviceMask"),
        functionMapEntryPoint("vkCmdSetDeviceMaskKHR"),
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
        functionMapEntryPoint("vkCreateSwapchainKHR"),
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
        functionMapEntryPoint("vkDestroySwapchainKHR"),
        functionMapEntryPoint("vkDeviceWaitIdle"),
        functionMapEntryPoint("vkEndCommandBuffer"),
        functionMapEntryPoint("vkFlushMappedMemoryRanges"),
        functionMapEntryPoint("vkFreeCommandBuffers"),
        functionMapEntryPoint("vkFreeDescriptorSets"),
        functionMapEntryPoint("vkFreeMemory"),
        functionMapEntryPoint("vkGetBufferMemoryRequirements"),
        functionMapEntryPoint("vkGetBufferDeviceAddress"),
        functionMapEntryPoint("vkGetBufferDeviceAddressEXT"),
        functionMapEntryPoint("vkGetBufferDeviceAddressKHR"),
        functionMapEntryPoint("vkGetDeviceMemoryCommitment"),
        functionMapEntryPoint("vkGetDeviceGroupPeerMemoryFeatures"),
        functionMapEntryPoint("vkGetDeviceGroupPeerMemoryFeaturesKHR"),
        functionMapEntryPoint("vkGetDeviceGroupPresentCapabilitiesKHR"),
        functionMapEntryPoint("vkGetDeviceGroupSurfacePresentModesKHR"),
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
        functionMapEntryPoint("vkGetSwapchainImagesKHR"),
        functionMapEntryPoint("vkInvalidateMappedMemoryRanges"),
        functionMapEntryPoint("vkMapMemory"),
        functionMapEntryPoint("vkMergePipelineCaches"),
        functionMapEntryPoint("vkQueueBindSparse"),
        functionMapEntryPoint("vkQueuePresentKHR"),
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

pub export fn ape_icdNegotiateLoaderICDInterfaceVersion(p_version: *u32) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vk_icdNegociateLoaderICDInterfaceVersion);
    defer entryPointEndLogTrace();

    p_version.* = 7;
    return .success;
}

pub export fn vk_icdGetInstanceProcAddr(p_instance: vk.Instance, p_name: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    defer entryPointEndLogTrace();

    if (p_name == null) return null;
    const name = std.mem.span(p_name.?);

    if (icd_pfn_map.get(name)) |pfn| return pfn;
    return vkGetInstanceProcAddr(p_instance, p_name);
}

pub export fn ape_icdGetPhysicalDeviceProcAddr(_: vk.Instance, p_name: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    defer entryPointEndLogTrace();

    if (p_name == null) return null;
    const name = std.mem.span(p_name.?);

    if (physical_device_pfn_map.get(name)) |pfn| return pfn;

    return null;
}

// Global functions ==========================================================================================================================================

pub export fn vkGetInstanceProcAddr(p_instance: vk.Instance, p_name: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    defer entryPointEndLogTrace();

    if (p_name == null) return null;
    const name = std.mem.span(p_name.?);

    if (global_pfn_map.get(name)) |pfn| return pfn;
    if (p_instance != .null_handle) {
        if (instance_pfn_map.get(name)) |pfn| return pfn;
        if (physical_device_pfn_map.get(name)) |pfn| return pfn;
        if (device_pfn_map.get(name)) |pfn| return pfn;
    }
    return null;
}

pub export fn apeCreateInstance(info: *const vk.InstanceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_instance: *vk.Instance) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateInstance);
    defer entryPointEndLogTrace();

    if (info.s_type != .instance_create_info) {
        return .error_validation_failed;
    }
    const allocator = VulkanAllocator.init(callbacks, .instance).allocator();
    Instance.validateCreateInfo(info) catch |err| return toVkResult(err);

    var instance: *lib.Instance = undefined;
    if (!builtin.is_test) {
        // Will call impl instead of interface as `root` refs the impl module
        instance = root.Instance.create(allocator, info) catch |err| return toVkResult(err);
    }

    instance.requestPhysicalDevices(allocator) catch |err| {
        if (!builtin.is_test) instance.deinit(allocator) catch {};
        return toVkResult(err);
    };

    const dispatchable = Dispatchable(Instance).wrap(allocator, instance) catch |err| {
        if (!builtin.is_test) instance.deinit(allocator) catch {};
        return toVkResult(err);
    };
    p_instance.* = dispatchable.toVkHandle(vk.Instance);
    return .success;
}

pub export fn apeEnumerateInstanceLayerProperties(property_count: *u32, properties: ?[*]vk.LayerProperties) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkEnumerateInstanceLayerProperties);
    defer entryPointEndLogTrace();

    Instance.enumerateLayerProperties(property_count, properties) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeEnumerateInstanceExtensionProperties(p_layer_name: ?[*:0]const u8, property_count: *u32, properties: ?[*]vk.ExtensionProperties) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkEnumerateInstanceExtensionProperties);
    defer entryPointEndLogTrace();

    var name: ?[]const u8 = null;
    if (p_layer_name) |layer_name| {
        name = std.mem.span(layer_name);
    }
    Instance.enumerateExtensionProperties(name, property_count, properties) catch |err| return toVkResult(err);
    return .success;
}

/// Do not make it available to GetProcAddr until Vulkan 1.1 is implemented
pub export fn apeEnumerateInstanceVersion(version: *u32) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkEnumerateInstanceVersion);
    defer entryPointEndLogTrace();

    Instance.enumerateVersion(version) catch |err| return toVkResult(err);
    return .success;
}

// Instance functions ========================================================================================================================================

pub export fn apeDestroyInstance(p_instance: vk.Instance, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyInstance);
    defer entryPointEndLogTrace();

    const allocator = VulkanAllocator.init(callbacks, .instance).allocator();
    const dispatchable = Dispatchable(Instance).fromHandle(p_instance) catch |err| return errorLogger(err);
    dispatchable.object.deinit(allocator) catch |err| return errorLogger(err);
    dispatchable.destroy(allocator);
}

pub export fn apeEnumeratePhysicalDeviceGroups(p_instance: vk.Instance, count: *u32, p_groups: ?[*]vk.PhysicalDeviceGroupProperties) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkEnumeratePhysicalDeviceGroups);
    defer entryPointEndLogTrace();

    const instance = Dispatchable(Instance).fromHandleObject(p_instance) catch |err| return toVkResult(err);
    const available: u32 = @intCast(instance.physical_devices.items.len);

    if (p_groups) |groups| {
        const write_count = @min(count.*, available);
        if (write_count == 0) {
            count.* = 0;
            return .incomplete;
        }

        for (groups[0..write_count], instance.physical_devices.items[0..write_count]) |*group, physical_device| {
            group.physical_device_count = 1;
            group.physical_devices = @splat(.null_handle);
            group.physical_devices[0] = physical_device.toVkHandle(vk.PhysicalDevice);
            group.subset_allocation = .false;
        }

        count.* = write_count;
        if (write_count < available) return .incomplete;
        return .success;
    }

    count.* = available;
    return .success;
}

pub export fn apeEnumeratePhysicalDeviceGroupsKHR(p_instance: vk.Instance, count: *u32, p_groups: ?[*]vk.PhysicalDeviceGroupProperties) callconv(vk.vulkan_call_conv) vk.Result {
    return @call(.always_inline, apeEnumeratePhysicalDeviceGroups, .{ p_instance, count, p_groups });
}

pub export fn apeEnumeratePhysicalDevices(p_instance: vk.Instance, count: *u32, p_devices: ?[*]vk.PhysicalDevice) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkEnumeratePhysicalDevices);
    defer entryPointEndLogTrace();

    const instance = Dispatchable(Instance).fromHandleObject(p_instance) catch |err| return toVkResult(err);
    const available = instance.physical_devices.items.len;
    if (p_devices) |devices| {
        const write_count = @min(count.*, available);
        for (0..write_count) |i| {
            devices[i] = instance.physical_devices.items[i].toVkHandle(vk.PhysicalDevice);
        }
        count.* = @intCast(write_count);
        if (write_count < available) return .incomplete;
    } else {
        count.* = @intCast(available);
    }
    return .success;
}

// Physical Device functions =================================================================================================================================

pub export fn apeCreateDevice(p_physical_device: vk.PhysicalDevice, info: *const vk.DeviceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_device: *vk.Device) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateDevice);
    defer entryPointEndLogTrace();

    if (info.s_type != .device_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .device).allocator();
    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);
    physical_device.validateCreateInfo(allocator, info) catch |err| return toVkResult(err);

    std.log.scoped(.vkCreateDevice).debug("Using VkPhysicalDevice named {s}", .{physical_device.props.device_name});

    const device = physical_device.createDevice(allocator, info) catch |err| return toVkResult(err);
    const dispatchable = Dispatchable(Device).wrap(allocator, device) catch |err| {
        device.destroy(allocator) catch {};
        return toVkResult(err);
    };
    p_device.* = dispatchable.toVkHandle(vk.Device);
    return .success;
}

pub export fn apeEnumerateDeviceLayerProperties(p_physical_device: vk.PhysicalDevice, property_count: *u32, properties: ?[*]vk.LayerProperties) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkEnumerateDeviceLayerProperties);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);
    physical_device.enumerateLayerProperties(property_count, properties) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeEnumerateDeviceExtensionProperties(p_physical_device: vk.PhysicalDevice, p_layer_name: ?[*:0]const u8, property_count: *u32, properties: ?[*]vk.ExtensionProperties) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkEnumerateDeviceExtensionProperties);
    defer entryPointEndLogTrace();

    var name: ?[]const u8 = null;
    if (p_layer_name) |layer_name| {
        name = std.mem.span(layer_name);
    }
    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);
    physical_device.enumerateExtensionProperties(name, property_count, properties) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeGetPhysicalDeviceFormatProperties(p_physical_device: vk.PhysicalDevice, format: vk.Format, properties: *vk.FormatProperties) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceFormatProperties);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    properties.* = physical_device.getFormatProperties(format) catch |err| return errorLogger(err);
}

pub export fn apeGetPhysicalDeviceFormatProperties2KHR(p_physical_device: vk.PhysicalDevice, format: vk.Format, properties: *vk.FormatProperties2KHR) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceFormatProperties2KHR);
    defer entryPointEndLogTrace();

    if (properties.s_type != .format_properties_2) return;

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    properties.format_properties = physical_device.getFormatProperties(format) catch |err| return errorLogger(err);
}

pub export fn apeGetPhysicalDeviceFeatures(p_physical_device: vk.PhysicalDevice, features: *vk.PhysicalDeviceFeatures) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceFeatures);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    features.* = physical_device.features;
}

pub export fn apeGetPhysicalDeviceFeatures2KHR(p_physical_device: vk.PhysicalDevice, features: *vk.PhysicalDeviceFeatures2KHR) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceFeatures2KHR);
    defer entryPointEndLogTrace();

    if (features.s_type != .physical_device_features_2) return;

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    features.features = physical_device.features;
}

pub export fn apeGetPhysicalDeviceImageFormatProperties(
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

pub export fn apeGetPhysicalDeviceImageFormatProperties2KHR(p_physical_device: vk.PhysicalDevice, format_info: *vk.PhysicalDeviceImageFormatInfo2KHR, properties: *vk.ImageFormatProperties2KHR) callconv(vk.vulkan_call_conv) vk.Result {
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

pub export fn apeGetPhysicalDeviceProperties(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceProperties) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceProperties);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    properties.* = physical_device.props;
}

pub export fn apeGetPhysicalDeviceProperties2KHR(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceProperties2KHR) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceProperties2KHR);
    defer entryPointEndLogTrace();

    if (properties.s_type != .physical_device_properties_2) return;

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    properties.properties = physical_device.props;
}

pub export fn apeGetPhysicalDeviceMemoryProperties(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceMemoryProperties) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceMemoryProperties);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    properties.* = physical_device.mem_props;
}

pub export fn apeGetPhysicalDeviceMemoryProperties2KHR(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceMemoryProperties2KHR) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceMemoryProperties2KHR);
    defer entryPointEndLogTrace();

    if (properties.s_type != .physical_device_memory_properties_2) return;

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    properties.memory_properties = physical_device.mem_props;
}

pub export fn apeGetPhysicalDeviceQueueFamilyProperties(p_physical_device: vk.PhysicalDevice, count: *u32, properties: ?[*]vk.QueueFamilyProperties) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceQueueFamilyProperties);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return errorLogger(err);
    count.* = @intCast(physical_device.queue_family_props.items.len);
    if (properties) |props| {
        @memcpy(props[0..count.*], physical_device.queue_family_props.items[0..count.*]);
    }
}

pub export fn apeGetPhysicalDeviceQueueFamilyProperties2KHR(p_physical_device: vk.PhysicalDevice, count: *u32, properties: ?[*]vk.QueueFamilyProperties2KHR) callconv(vk.vulkan_call_conv) void {
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

pub export fn apeGetPhysicalDeviceSparseImageFormatProperties(
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

pub export fn apeGetPhysicalDeviceSparseImageFormatProperties2KHR(
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

pub export fn apeQueueBindSparse(p_queue: vk.Queue, count: u32, info: [*]vk.BindSparseInfo, p_fence: vk.Fence) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkQueueBindSparse);
    defer entryPointEndLogTrace();

    const queue = Dispatchable(Queue).fromHandleObject(p_queue) catch |err| return toVkResult(err);
    const fence = if (p_fence != .null_handle) NonDispatchable(Fence).fromHandleObject(p_fence) catch |err| return toVkResult(err) else null;
    queue.bindSparse(info[0..count], fence) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeQueueSubmit(p_queue: vk.Queue, count: u32, info: [*]const vk.SubmitInfo, p_fence: vk.Fence) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkQueueSubmit);
    defer entryPointEndLogTrace();

    const queue = Dispatchable(Queue).fromHandleObject(p_queue) catch |err| return toVkResult(err);
    const fence = if (p_fence != .null_handle) NonDispatchable(Fence).fromHandleObject(p_fence) catch |err| return toVkResult(err) else null;
    queue.submit(info[0..count], fence) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeQueueWaitIdle(p_queue: vk.Queue) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkQueueWaitIdle);
    defer entryPointEndLogTrace();

    const queue = Dispatchable(Queue).fromHandleObject(p_queue) catch |err| return toVkResult(err);
    queue.waitIdle() catch |err| return toVkResult(err);
    return .success;
}

// Device functions ==========================================================================================================================================

pub export fn apeAllocateCommandBuffers(p_device: vk.Device, info: *const vk.CommandBufferAllocateInfo, p_cmds: [*]vk.CommandBuffer) callconv(vk.vulkan_call_conv) vk.Result {
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

pub export fn apeAllocateDescriptorSets(p_device: vk.Device, info: *const vk.DescriptorSetAllocateInfo, p_sets: [*]vk.DescriptorSet) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkAllocateDescriptorSets);
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

pub export fn apeAllocateMemory(p_device: vk.Device, info: *const vk.MemoryAllocateInfo, callbacks: ?*const vk.AllocationCallbacks, p_memory: *vk.DeviceMemory) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkAllocateMemory);
    defer entryPointEndLogTrace();

    if (info.s_type != .memory_allocate_info) {
        return .error_validation_failed;
    }

    std.log.scoped(.vkAllocateMemory).debug("Allocating {d} bytes from device 0x{X}", .{ info.allocation_size, @intFromEnum(p_device) });

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const device_memory = device.allocateMemory(allocator, info) catch |err| return toVkResult(err);

    p_memory.* = wrapNonDispatchable(DeviceMemory, allocator, device_memory, vk.DeviceMemory) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeBindBufferMemory(p_device: vk.Device, p_buffer: vk.Buffer, p_memory: vk.DeviceMemory, offset: vk.DeviceSize) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkBindBufferMemory);
    defer entryPointEndLogTrace();

    std.log.scoped(.vkBindBufferMemory).debug("Binding device memory 0x{X} to buffer 0x{X}", .{ @intFromEnum(p_memory), @intFromEnum(p_buffer) });

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const buffer = NonDispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return toVkResult(err);
    const memory = NonDispatchable(DeviceMemory).fromHandleObject(p_memory) catch |err| return toVkResult(err);

    buffer.bindMemory(memory, offset) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeBindImageMemory(p_device: vk.Device, p_image: vk.Image, p_memory: vk.DeviceMemory, offset: vk.DeviceSize) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkBindImageMemory);
    defer entryPointEndLogTrace();

    std.log.scoped(.vkBindImageMemory).debug("Binding device memory 0x{X} to image 0x{X}", .{ @intFromEnum(p_memory), @intFromEnum(p_image) });

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const image = NonDispatchable(Image).fromHandleObject(p_image) catch |err| return toVkResult(err);
    const memory = NonDispatchable(DeviceMemory).fromHandleObject(p_memory) catch |err| return toVkResult(err);

    image.bindMemory(memory, offset) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateBuffer(p_device: vk.Device, info: *const vk.BufferCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_buffer: *vk.Buffer) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateBuffer);
    defer entryPointEndLogTrace();

    if (info.s_type != .buffer_create_info) {
        return .error_validation_failed;
    }
    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const buffer = device.createBuffer(allocator, info) catch |err| return toVkResult(err);
    p_buffer.* = wrapNonDispatchable(Buffer, allocator, buffer, vk.Buffer) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateBufferView(p_device: vk.Device, info: *const vk.BufferViewCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_view: *vk.BufferView) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateBufferView);
    defer entryPointEndLogTrace();

    if (info.s_type != .buffer_view_create_info) {
        return .error_validation_failed;
    }
    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const view = device.createBufferView(allocator, info) catch |err| return toVkResult(err);
    p_view.* = wrapNonDispatchable(BufferView, allocator, view, vk.BufferView) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateCommandPool(p_device: vk.Device, info: *const vk.CommandPoolCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_pool: *vk.CommandPool) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateCommandPool);
    defer entryPointEndLogTrace();

    if (info.s_type != .command_pool_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const pool = device.createCommandPool(allocator, info) catch |err| return toVkResult(err);
    p_pool.* = wrapNonDispatchable(CommandPool, allocator, pool, vk.CommandPool) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateComputePipelines(p_device: vk.Device, p_cache: vk.PipelineCache, count: u32, infos: [*]const vk.ComputePipelineCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_pipelines: [*]vk.Pipeline) callconv(vk.vulkan_call_conv) vk.Result {
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

pub export fn apeCreateDescriptorPool(p_device: vk.Device, info: *const vk.DescriptorPoolCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_pool: *vk.DescriptorPool) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateDescriptorPool);
    defer entryPointEndLogTrace();

    if (info.s_type != .descriptor_pool_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const pool = device.createDescriptorPool(allocator, info) catch |err| return toVkResult(err);
    p_pool.* = wrapNonDispatchable(DescriptorPool, allocator, pool, vk.DescriptorPool) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateDescriptorSetLayout(p_device: vk.Device, info: *const vk.DescriptorSetLayoutCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_layout: *vk.DescriptorSetLayout) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateDescriptorSetLayout);
    defer entryPointEndLogTrace();

    if (info.s_type != .descriptor_set_layout_create_info) {
        return .error_validation_failed;
    }

    // Device scoped because we're reference counting and layout may not be destroyed when vkDestroyDescriptorSetLayout is called
    const allocator = VulkanAllocator.init(callbacks, .device).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const layout = device.createDescriptorSetLayout(allocator, info) catch |err| return toVkResult(err);
    p_layout.* = wrapNonDispatchable(DescriptorSetLayout, allocator, layout, vk.DescriptorSetLayout) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateEvent(p_device: vk.Device, info: *const vk.EventCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_event: *vk.Event) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateEvent);
    defer entryPointEndLogTrace();

    if (info.s_type != .event_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const event = device.createEvent(allocator, info) catch |err| return toVkResult(err);
    p_event.* = wrapNonDispatchable(Event, allocator, event, vk.Event) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateFence(p_device: vk.Device, info: *const vk.FenceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_fence: *vk.Fence) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateFence);
    defer entryPointEndLogTrace();

    if (info.s_type != .fence_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const fence = device.createFence(allocator, info) catch |err| return toVkResult(err);
    p_fence.* = wrapNonDispatchable(Fence, allocator, fence, vk.Fence) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateFramebuffer(p_device: vk.Device, info: *const vk.FramebufferCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_framebuffer: *vk.Framebuffer) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateFramebuffer);
    defer entryPointEndLogTrace();

    if (info.s_type != .framebuffer_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const framebuffer = device.createFramebuffer(allocator, info) catch |err| return toVkResult(err);
    p_framebuffer.* = wrapNonDispatchable(Framebuffer, allocator, framebuffer, vk.Framebuffer) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateGraphicsPipelines(p_device: vk.Device, p_cache: vk.PipelineCache, count: u32, infos: [*]const vk.GraphicsPipelineCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_pipelines: [*]vk.Pipeline) callconv(vk.vulkan_call_conv) vk.Result {
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

pub export fn apeCreateImage(p_device: vk.Device, info: *const vk.ImageCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_image: *vk.Image) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateImage);
    defer entryPointEndLogTrace();

    if (info.s_type != .image_create_info) {
        return .error_validation_failed;
    }
    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const image = device.createImage(allocator, info) catch |err| return toVkResult(err);
    p_image.* = wrapNonDispatchable(Image, allocator, image, vk.Image) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateImageView(p_device: vk.Device, info: *const vk.ImageViewCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_image_view: *vk.ImageView) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateImageView);
    defer entryPointEndLogTrace();

    if (info.s_type != .image_view_create_info) {
        return .error_validation_failed;
    }
    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const image_view = device.createImageView(allocator, info) catch |err| return toVkResult(err);
    p_image_view.* = wrapNonDispatchable(ImageView, allocator, image_view, vk.ImageView) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreatePipelineCache(p_device: vk.Device, info: *const vk.PipelineCacheCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_cache: *vk.PipelineCache) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreatePipelineCache);
    defer entryPointEndLogTrace();

    if (info.s_type != .pipeline_cache_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const cache = device.createPipelineCache(allocator, info) catch |err| return toVkResult(err);
    p_cache.* = wrapNonDispatchable(PipelineCache, allocator, cache, vk.PipelineCache) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreatePipelineLayout(p_device: vk.Device, info: *const vk.PipelineLayoutCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_layout: *vk.PipelineLayout) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreatePipelineLayout);
    defer entryPointEndLogTrace();

    if (info.s_type != .pipeline_layout_create_info) {
        return .error_validation_failed;
    }

    // Device scoped because we're reference counting and layout may not be destroyed when vkDestroyPipelineLayout is called
    const allocator = VulkanAllocator.init(callbacks, .device).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const layout = device.createPipelineLayout(allocator, info) catch |err| return toVkResult(err);
    p_layout.* = wrapNonDispatchable(PipelineLayout, allocator, layout, vk.PipelineLayout) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateQueryPool(p_device: vk.Device, info: *const vk.QueryPoolCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_pool: *vk.QueryPool) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateQueryPool);
    defer entryPointEndLogTrace();

    if (info.s_type != .query_pool_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const pool = device.createQueryPool(allocator, info) catch |err| return toVkResult(err);
    p_pool.* = wrapNonDispatchable(QueryPool, allocator, pool, vk.QueryPool) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateRenderPass(p_device: vk.Device, info: *const vk.RenderPassCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_pass: *vk.RenderPass) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateRenderPass);
    defer entryPointEndLogTrace();

    if (info.s_type != .render_pass_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const pass = device.createRenderPass(allocator, info) catch |err| return toVkResult(err);
    p_pass.* = wrapNonDispatchable(RenderPass, allocator, pass, vk.RenderPass) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateSampler(p_device: vk.Device, info: *const vk.SamplerCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_sampler: *vk.Sampler) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateSampler);
    defer entryPointEndLogTrace();

    if (info.s_type != .sampler_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const sampler = device.createSampler(allocator, info) catch |err| return toVkResult(err);
    p_sampler.* = wrapNonDispatchable(Sampler, allocator, sampler, vk.Sampler) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateSemaphore(p_device: vk.Device, info: *const vk.SemaphoreCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_semaphore: *vk.Semaphore) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateSemaphore);
    defer entryPointEndLogTrace();

    if (info.s_type != .semaphore_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const semaphore = device.createSemaphore(allocator, info) catch |err| return toVkResult(err);
    p_semaphore.* = wrapNonDispatchable(BinarySemaphore, allocator, semaphore, vk.Semaphore) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateShaderModule(p_device: vk.Device, info: *const vk.ShaderModuleCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_module: *vk.ShaderModule) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateShaderModule);
    defer entryPointEndLogTrace();

    if (info.s_type != .shader_module_create_info) {
        return .error_validation_failed;
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const module = device.createShaderModule(allocator, info) catch |err| return toVkResult(err);
    p_module.* = wrapNonDispatchable(ShaderModule, allocator, module, vk.ShaderModule) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeDestroyBuffer(p_device: vk.Device, p_buffer: vk.Buffer, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyBuffer);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(Buffer).fromHandle(p_buffer) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroyBufferView(p_device: vk.Device, p_view: vk.BufferView, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyBufferView);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(BufferView).fromHandle(p_view) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroyCommandPool(p_device: vk.Device, p_pool: vk.CommandPool, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyCommandPool);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(CommandPool).fromHandle(p_pool) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroyDescriptorPool(p_device: vk.Device, p_pool: vk.DescriptorPool, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyDescriptorPool);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(DescriptorPool).fromHandle(p_pool) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroyDescriptorSetLayout(p_device: vk.Device, p_layout: vk.DescriptorSetLayout, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyDescriptorLayout);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(DescriptorSetLayout).fromHandle(p_layout) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroyDevice(p_device: vk.Device, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyDevice);
    defer entryPointEndLogTrace();

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const dispatchable = Dispatchable(Device).fromHandle(p_device) catch |err| return errorLogger(err);

    std.log.scoped(.vkDestroyDevice).debug("Destroying VkDevice created from {s}", .{dispatchable.object.physical_device.props.device_name});

    dispatchable.object.destroy(allocator) catch |err| return errorLogger(err);
    dispatchable.destroy(allocator);
}

pub export fn apeDestroyEvent(p_device: vk.Device, p_event: vk.Event, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyEvent);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(Event).fromHandle(p_event) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroyFence(p_device: vk.Device, p_fence: vk.Fence, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyFence);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(Fence).fromHandle(p_fence) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroyFramebuffer(p_device: vk.Device, p_framebuffer: vk.Framebuffer, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyFramebuffer);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(Framebuffer).fromHandle(p_framebuffer) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroyImage(p_device: vk.Device, p_image: vk.Image, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyImage);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(Image).fromHandle(p_image) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroyImageView(p_device: vk.Device, p_image_view: vk.ImageView, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyImageView);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(ImageView).fromHandle(p_image_view) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroyPipeline(p_device: vk.Device, p_pipeline: vk.Pipeline, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyPipeline);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(Pipeline).fromHandle(p_pipeline) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroyPipelineCache(p_device: vk.Device, p_cache: vk.PipelineCache, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyPipelineCache);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(PipelineCache).fromHandle(p_cache) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroyPipelineLayout(p_device: vk.Device, p_layout: vk.PipelineLayout, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyPipelineCache);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(PipelineLayout).fromHandle(p_layout) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroyQueryPool(p_device: vk.Device, p_pool: vk.QueryPool, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyQueryPool);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(QueryPool).fromHandle(p_pool) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroyRenderPass(p_device: vk.Device, p_pass: vk.RenderPass, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyRenderPass);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(RenderPass).fromHandle(p_pass) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroySampler(p_device: vk.Device, p_sampler: vk.Sampler, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroySampler);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(Sampler).fromHandle(p_sampler) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroySemaphore(p_device: vk.Device, p_semaphore: vk.Semaphore, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroySemaphore);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(BinarySemaphore).fromHandle(p_semaphore) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroyShaderModule(p_device: vk.Device, p_module: vk.ShaderModule, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroyShaderModule);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(ShaderModule).fromHandle(p_module) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDeviceWaitIdle(p_device: vk.Device) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkDeviceWaitIdle);
    defer entryPointEndLogTrace();

    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    device.waitIdle() catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeFlushMappedMemoryRanges(p_device: vk.Device, count: u32, p_ranges: [*]const vk.MappedMemoryRange) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkFlushMappedMemoryRanges);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    for (p_ranges, 0..count) |range, _| {
        const memory = NonDispatchable(DeviceMemory).fromHandleObject(range.memory) catch |err| return toVkResult(err);
        memory.flushRange(range.offset, range.size) catch |err| return toVkResult(err);
    }
    return .success;
}

pub export fn apeFreeCommandBuffers(p_device: vk.Device, p_pool: vk.CommandPool, count: u32, p_cmds: [*]const vk.CommandBuffer) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkFreeCommandBuffers);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const pool = NonDispatchable(CommandPool).fromHandleObject(p_pool) catch |err| return errorLogger(err);
    const cmds: [*]*Dispatchable(CommandBuffer) = @ptrCast(@constCast(p_cmds));
    pool.freeCommandBuffers(cmds[0..count]) catch |err| return errorLogger(err);
}

pub export fn apeFreeDescriptorSets(p_device: vk.Device, p_pool: vk.CommandPool, count: u32, p_sets: [*]const vk.DescriptorSet) callconv(vk.vulkan_call_conv) void {
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

pub export fn apeFreeMemory(p_device: vk.Device, p_memory: vk.DeviceMemory, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkFreeMemory);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(DeviceMemory).fromHandle(p_memory) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeGetBufferMemoryRequirements(p_device: vk.Device, p_buffer: vk.Buffer, requirements: *vk.MemoryRequirements) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetBufferMemoryRequirements);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const buffer = NonDispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);
    buffer.getMemoryRequirements(requirements);
}

pub export fn apeGetBufferDeviceAddress(p_device: vk.Device, info: *const vk.BufferDeviceAddressInfo) callconv(vk.vulkan_call_conv) vk.DeviceAddress {
    entryPointBeginLogTrace(.vkGetBufferDeviceAddress);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| {
        errorLogger(err);
        return 0;
    };

    const buffer = NonDispatchable(Buffer).fromHandleObject(info.buffer) catch |err| {
        errorLogger(err);
        return 0;
    };

    return buffer.getDeviceAddress() catch |err| {
        errorLogger(err);
        return 0;
    };
}

pub export fn apeGetBufferDeviceAddressEXT(p_device: vk.Device, info: *const vk.BufferDeviceAddressInfo) callconv(vk.vulkan_call_conv) vk.DeviceAddress {
    return @call(.always_inline, apeGetBufferDeviceAddress, .{ p_device, info });
}

pub export fn apeGetBufferDeviceAddressKHR(p_device: vk.Device, info: *const vk.BufferDeviceAddressInfo) callconv(vk.vulkan_call_conv) vk.DeviceAddress {
    return @call(.always_inline, apeGetBufferDeviceAddress, .{ p_device, info });
}

pub export fn apeGetDeviceMemoryCommitment(p_device: vk.Device, p_memory: vk.DeviceMemory, committed_memory: *vk.DeviceSize) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetDeviceMemoryCommitment);
    defer entryPointEndLogTrace();

    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return errorLogger(err);
    const memory = NonDispatchable(DeviceMemory).fromHandleObject(p_memory) catch |err| return errorLogger(err);
    if (memory.owner != device)
        return errorLogger(VkError.InvalidHandleDrv);

    committed_memory.* = memory.size;
}

pub export fn apeGetDeviceGroupPeerMemoryFeatures(
    p_device: vk.Device,
    heap_index: u32,
    local_device_index: u32,
    remote_device_index: u32,
    p_peer_memory_features: *vk.PeerMemoryFeatureFlags,
) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetDeviceGroupPeerMemoryFeatures);
    defer entryPointEndLogTrace();

    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return errorLogger(err);
    p_peer_memory_features.* = device.getDeviceGroupPeerMemoryFeatures(heap_index, local_device_index, remote_device_index) catch |err| return errorLogger(err);
}

pub export fn apeGetDeviceGroupPeerMemoryFeaturesKHR(
    p_device: vk.Device,
    heap_index: u32,
    local_device_index: u32,
    remote_device_index: u32,
    p_peer_memory_features: *vk.PeerMemoryFeatureFlags,
) callconv(vk.vulkan_call_conv) void {
    apeGetDeviceGroupPeerMemoryFeatures(p_device, heap_index, local_device_index, remote_device_index, p_peer_memory_features);
}

pub export fn apeGetDeviceGroupPresentCapabilitiesKHR(
    p_device: vk.Device,
    p_device_group_present_capabilities: *vk.DeviceGroupPresentCapabilitiesKHR,
) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetDeviceGroupPresentCapabilitiesKHR);
    defer entryPointEndLogTrace();

    if (p_device_group_present_capabilities.s_type != .device_group_present_capabilities_khr) {
        return .error_validation_failed;
    }

    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    device.getDeviceGroupPresentCapabilitiesKHR(p_device_group_present_capabilities) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeGetDeviceGroupSurfacePresentModesKHR(
    p_device: vk.Device,
    p_surface: vk.SurfaceKHR,
    p_modes: *vk.DeviceGroupPresentModeFlagsKHR,
) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetDeviceGroupSurfacePresentModesKHR);
    defer entryPointEndLogTrace();

    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const surface = NonDispatchable(SurfaceKHR).fromHandleObject(p_surface) catch |err| return toVkResult(err);
    p_modes.* = device.getDeviceGroupSurfacePresentModesKHR(surface) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeGetDeviceProcAddr(p_device: vk.Device, p_name: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    defer entryPointEndLogTrace();

    if (p_name == null) return null;
    const name = std.mem.span(p_name.?);

    if (p_device == .null_handle) return null;
    if (device_pfn_map.get(name)) |pfn| return pfn;

    return null;
}

pub export fn apeGetDeviceQueue(p_device: vk.Device, queue_family_index: u32, queue_index: u32, p_queue: *vk.Queue) callconv(vk.vulkan_call_conv) void {
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

pub export fn apeGetEventStatus(p_device: vk.Device, p_event: vk.Event) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetEventStatus);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const event = NonDispatchable(Event).fromHandleObject(p_event) catch |err| return toVkResult(err);
    event.getStatus() catch |err| return toVkResult(err);
    return .event_set;
}

pub export fn apeGetFenceStatus(p_device: vk.Device, p_fence: vk.Fence) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetFenceStatus);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const fence = NonDispatchable(Fence).fromHandleObject(p_fence) catch |err| return toVkResult(err);
    fence.getStatus() catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeGetImageMemoryRequirements(p_device: vk.Device, p_image: vk.Image, requirements: *vk.MemoryRequirements) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetImageMemoryRequirements);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const image = NonDispatchable(Image).fromHandleObject(p_image) catch |err| return errorLogger(err);
    image.getMemoryRequirements(requirements) catch |err| return errorLogger(err);
}

pub export fn apeGetImageSparseMemoryRequirements(p_device: vk.Device, p_image: vk.Image, requirements: *vk.SparseImageMemoryRequirements) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetImageSparseMemoryRequirements);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);
    NonDispatchable(Image).checkHandleValidity(p_image) catch |err| return errorLogger(err);

    lib.unsupported("sparse images are not supported", .{});

    _ = requirements;
}

pub export fn apeGetImageSubresourceLayout(p_device: vk.Device, p_image: vk.Image, subresource: *const vk.ImageSubresource, layout: *vk.SubresourceLayout) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetImageSubresourceLayout);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const image = NonDispatchable(Image).fromHandleObject(p_image) catch |err| return errorLogger(err);
    layout.* = image.getSubresourceLayout(subresource.*) catch |err| return errorLogger(err);
}

pub export fn apeGetPipelineCacheData(p_device: vk.Device, p_cache: vk.PipelineCache, size: *usize, data: ?*anyopaque) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetPipelineCacheData);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);
    const cache = NonDispatchable(PipelineCache).fromHandleObject(p_cache) catch |err| return toVkResult(err);

    const available = cache.availableDataSize();
    const result = if (data) |ptr| blk: {
        if (size.* < @sizeOf(PipelineCache.Header)) {
            size.* = 0;
            return .incomplete;
        }
        const bytes = @as([*]u8, @ptrCast(ptr))[0..size.*];
        break :blk cache.getData(bytes);
    } else cache.getData(null);
    size.* = if (result == .incomplete) @min(size.*, available) else available;
    return result;
}

pub export fn apeGetQueryPoolResults(
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
    const pool = NonDispatchable(QueryPool).fromHandleObject(p_pool) catch |err| return toVkResult(err);

    const bytes = @as([*]u8, @ptrCast(data))[0..size];
    pool.writeResults(first, count, bytes, stride, flags) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeGetRenderAreaGranularity(p_device: vk.Device, p_pass: vk.RenderPass, granularity: *vk.Extent2D) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkGetRenderAreaGranularity);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);
    const pass = NonDispatchable(RenderPass).fromHandleObject(p_pass) catch |err| return errorLogger(err);

    granularity.* = pass.getRenderAreaGranularity();
}

pub export fn apeInvalidateMappedMemoryRanges(p_device: vk.Device, count: u32, p_ranges: [*]const vk.MappedMemoryRange) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkInvalidateMappedMemoryRanges);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    for (p_ranges, 0..count) |range, _| {
        const memory = NonDispatchable(DeviceMemory).fromHandleObject(range.memory) catch |err| return toVkResult(err);
        memory.invalidateRange(range.offset, range.size) catch |err| return toVkResult(err);
    }
    return .success;
}

pub export fn apeMapMemory(p_device: vk.Device, p_memory: vk.DeviceMemory, offset: vk.DeviceSize, size: vk.DeviceSize, _: vk.MemoryMapFlags, pp_data: *?*anyopaque) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkMapMemory);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const device_memory = NonDispatchable(DeviceMemory).fromHandleObject(p_memory) catch |err| return toVkResult(err);
    pp_data.* = @ptrCast((device_memory.map(offset, size) catch |err| return toVkResult(err)).ptr);
    return .success;
}

pub export fn apeMergePipelineCaches(p_device: vk.Device, p_dst: vk.PipelineCache, count: u32, p_srcs: [*]const vk.PipelineCache) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkMergePipelineCaches);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);
    const dst = NonDispatchable(PipelineCache).fromHandleObject(p_dst) catch |err| return toVkResult(err);

    for (0..count) |i| {
        const src = NonDispatchable(PipelineCache).fromHandleObject(p_srcs[i]) catch |err| return toVkResult(err);
        dst.merge(src) catch |err| return toVkResult(err);
    }

    return .success;
}

pub export fn apeResetCommandPool(p_device: vk.Device, p_pool: vk.CommandPool, flags: vk.CommandPoolResetFlags) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkResetCommandPool);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);
    const pool = NonDispatchable(CommandPool).fromHandleObject(p_pool) catch |err| return toVkResult(err);
    pool.reset(flags) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeResetDescriptorPool(p_device: vk.Device, p_pool: vk.DescriptorPool, flags: vk.DescriptorPoolResetFlags) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkResetDescriptorPool);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);
    const pool = NonDispatchable(DescriptorPool).fromHandleObject(p_pool) catch |err| return toVkResult(err);
    pool.reset(flags) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeResetEvent(p_device: vk.Device, p_event: vk.Event) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkResetEvent);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const event = NonDispatchable(Event).fromHandleObject(p_event) catch |err| return toVkResult(err);
    event.reset() catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeResetFences(p_device: vk.Device, count: u32, p_fences: [*]const vk.Fence) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkResetFences);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    for (p_fences, 0..count) |p_fence, _| {
        const fence = NonDispatchable(Fence).fromHandleObject(p_fence) catch |err| return toVkResult(err);
        fence.reset() catch |err| return toVkResult(err);
    }
    return .success;
}

pub export fn apeSetEvent(p_device: vk.Device, p_event: vk.Event) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkSetEvent);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const event = NonDispatchable(Event).fromHandleObject(p_event) catch |err| return toVkResult(err);
    event.signal() catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeUnmapMemory(p_device: vk.Device, p_memory: vk.DeviceMemory) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkUnmapMemory);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const device_memory = NonDispatchable(DeviceMemory).fromHandleObject(p_memory) catch |err| return errorLogger(err);
    device_memory.unmap();
}

pub export fn apeUpdateDescriptorSets(p_device: vk.Device, write_count: u32, writes: [*]const vk.WriteDescriptorSet, copy_count: u32, copies: [*]const vk.CopyDescriptorSet) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkUpdateDescriptorSets);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    for (writes, 0..write_count) |write, _| {
        const set = NonDispatchable(DescriptorSet).fromHandleObject(write.dst_set) catch |err| return errorLogger(err);
        set.write(write) catch |err| return errorLogger(err);
    }

    for (copies, 0..copy_count) |copy, _| {
        const dst = NonDispatchable(DescriptorSet).fromHandleObject(copy.dst_set) catch |err| return errorLogger(err);
        const src = NonDispatchable(DescriptorSet).fromHandleObject(copy.src_set) catch |err| return errorLogger(err);
        dst.copy(src, copy) catch |err| return errorLogger(err);
    }
}

pub export fn apeWaitForFences(p_device: vk.Device, count: u32, p_fences: [*]const vk.Fence, waitForAll: vk.Bool32, timeout: u64) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkWaitForFences);
    defer entryPointEndLogTrace();

    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);

    const allocator = VulkanAllocator.init(null, .command).allocator();
    const fences = allocator.alloc(*Fence, count) catch return toVkResult(VkError.OutOfHostMemory);
    defer allocator.free(fences);

    for (p_fences[0..count], fences) |p_fence, *fence| {
        fence.* = NonDispatchable(Fence).fromHandleObject(p_fence) catch |err| return toVkResult(err);
    }

    Fence.waitMany(device, fences, waitForAll, timeout) catch |err| return toVkResult(err);
    return .success;
}

// Command Buffer functions ===================================================================================================================================

pub export fn apeBeginCommandBuffer(p_cmd: vk.CommandBuffer, info: *const vk.CommandBufferBeginInfo) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkBeginCommandBuffer);
    defer entryPointEndLogTrace();

    if (info.s_type != .command_buffer_begin_info) {
        return .error_validation_failed;
    }
    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return toVkResult(err);
    cmd.begin(info) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCmdBeginQuery(p_cmd: vk.CommandBuffer, p_pool: vk.QueryPool, query: u32, flags: vk.QueryControlFlags) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdBeginQuery);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const pool = NonDispatchable(QueryPool).fromHandleObject(p_pool) catch |err| return errorLogger(err);
    cmd.beginQuery(pool, query, flags) catch |err| return errorLogger(err);
}

pub export fn apeCmdBeginRenderPass(p_cmd: vk.CommandBuffer, info: *const vk.RenderPassBeginInfo, contents: vk.SubpassContents) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdBeginRenderPass);
    defer entryPointEndLogTrace();

    if (info.s_type != .render_pass_begin_info) {
        return errorLogger(VkError.ValidationFailed);
    }

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const render_pass = NonDispatchable(RenderPass).fromHandleObject(info.render_pass) catch |err| return errorLogger(err);
    const framebuffer = NonDispatchable(Framebuffer).fromHandleObject(info.framebuffer) catch |err| return errorLogger(err);
    cmd.beginRenderPass(render_pass, framebuffer, info.render_area, if (info.p_clear_values) |clear_values| clear_values[0..info.clear_value_count] else null) catch |err| return errorLogger(err);

    _ = contents;
}

pub export fn apeCmdBindDescriptorSets(
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

pub export fn apeCmdBindIndexBuffer(p_cmd: vk.CommandBuffer, p_buffer: vk.Buffer, offset: vk.DeviceSize, index_type: vk.IndexType) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdBindIndexBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const buffer = NonDispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);
    cmd.bindIndexBuffer(buffer, offset, index_type) catch |err| return errorLogger(err);
}

pub export fn apeCmdBindPipeline(p_cmd: vk.CommandBuffer, bind_point: vk.PipelineBindPoint, p_pipeline: vk.Pipeline) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdBindPipeline);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const pipeline = NonDispatchable(Pipeline).fromHandleObject(p_pipeline) catch |err| return errorLogger(err);
    cmd.bindPipeline(bind_point, pipeline) catch |err| return errorLogger(err);
}

pub export fn apeCmdBindVertexBuffers(p_cmd: vk.CommandBuffer, first: u32, count: u32, p_buffers: [*]const vk.Buffer, offsets: [*]const vk.DeviceSize) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdBindVertexBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    for (p_buffers, offsets, 0..count) |p_buffer, offset, i| {
        const buffer = NonDispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);
        cmd.bindVertexBuffer(first + i, buffer, offset) catch |err| return errorLogger(err);
    }
}

pub export fn apeCmdBlitImage(
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

    cmd.blitImage(src, src_layout, dst, dst_layout, regions[0..count], filter) catch |err| return errorLogger(err);
}

pub export fn apeCmdClearAttachments(p_cmd: vk.CommandBuffer, attachment_count: u32, attachments: [*]const vk.ClearAttachment, rect_count: u32, rects: [*]const vk.ClearRect) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdClearAttachments);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    for (attachments[0..], 0..attachment_count) |attachment, _| {
        for (rects[0..], 0..rect_count) |rect, _| {
            cmd.clearAttachment(attachment, rect) catch |err| return errorLogger(err);
        }
    }
}

pub export fn apeCmdClearColorImage(p_cmd: vk.CommandBuffer, p_image: vk.Image, layout: vk.ImageLayout, color: *const vk.ClearColorValue, count: u32, ranges: [*]const vk.ImageSubresourceRange) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdClearColorImage);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const image = NonDispatchable(Image).fromHandleObject(p_image) catch |err| return errorLogger(err);
    cmd.clearColorImage(image, layout, color, ranges[0..count]) catch |err| return errorLogger(err);
}

pub export fn apeCmdClearDepthStencilImage(p_cmd: vk.CommandBuffer, p_image: vk.Image, layout: vk.ImageLayout, value: *const vk.ClearDepthStencilValue, count: u32, ranges: [*]const vk.ImageSubresourceRange) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdClearDepthStencilImage);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const image = NonDispatchable(Image).fromHandleObject(p_image) catch |err| return errorLogger(err);
    cmd.clearDepthStencilImage(image, layout, value, ranges[0..count]) catch |err| return errorLogger(err);
}

pub export fn apeCmdCopyBuffer(p_cmd: vk.CommandBuffer, p_src: vk.Buffer, p_dst: vk.Buffer, count: u32, regions: [*]const vk.BufferCopy) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdCopyBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const src = NonDispatchable(Buffer).fromHandleObject(p_src) catch |err| return errorLogger(err);
    const dst = NonDispatchable(Buffer).fromHandleObject(p_dst) catch |err| return errorLogger(err);
    cmd.copyBuffer(src, dst, regions[0..count]) catch |err| return errorLogger(err);
}

pub export fn apeCmdCopyBufferToImage(p_cmd: vk.CommandBuffer, p_src: vk.Buffer, p_dst: vk.Image, layout: vk.ImageLayout, count: u32, regions: [*]const vk.BufferImageCopy) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdCopyBufferToImage);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const src = NonDispatchable(Buffer).fromHandleObject(p_src) catch |err| return errorLogger(err);
    const dst = NonDispatchable(Image).fromHandleObject(p_dst) catch |err| return errorLogger(err);

    cmd.copyBufferToImage(src, dst, layout, regions[0..count]) catch |err| return errorLogger(err);
}

pub export fn apeCmdCopyImage(p_cmd: vk.CommandBuffer, p_src: vk.Image, src_layout: vk.ImageLayout, p_dst: vk.Image, dst_layout: vk.ImageLayout, count: u32, regions: [*]const vk.ImageCopy) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdCopyImage);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const src = NonDispatchable(Image).fromHandleObject(p_src) catch |err| return errorLogger(err);
    const dst = NonDispatchable(Image).fromHandleObject(p_dst) catch |err| return errorLogger(err);
    cmd.copyImage(src, src_layout, dst, dst_layout, regions[0..count]) catch |err| return errorLogger(err);
}

pub export fn apeCmdCopyImageToBuffer(p_cmd: vk.CommandBuffer, p_src: vk.Image, layout: vk.ImageLayout, p_dst: vk.Buffer, count: u32, regions: [*]const vk.BufferImageCopy) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdCopyImageToBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const src = NonDispatchable(Image).fromHandleObject(p_src) catch |err| return errorLogger(err);
    const dst = NonDispatchable(Buffer).fromHandleObject(p_dst) catch |err| return errorLogger(err);
    cmd.copyImageToBuffer(src, layout, dst, regions[0..count]) catch |err| return errorLogger(err);
}

pub export fn apeCmdCopyQueryPoolResults(p_cmd: vk.CommandBuffer, p_pool: vk.QueryPool, first: u32, count: u32, p_dst: vk.Buffer, offset: vk.DeviceSize, stride: vk.DeviceSize, flags: vk.QueryResultFlags) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdCopyQueryPoolResults);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const pool = NonDispatchable(QueryPool).fromHandleObject(p_pool) catch |err| return errorLogger(err);
    const dst = NonDispatchable(Buffer).fromHandleObject(p_dst) catch |err| return errorLogger(err);
    cmd.copyQueryPoolResults(pool, first, count, dst, offset, stride, flags) catch |err| return errorLogger(err);
}

pub export fn apeCmdDispatch(p_cmd: vk.CommandBuffer, group_count_x: u32, group_count_y: u32, group_count_z: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdDispatch);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.dispatch(group_count_x, group_count_y, group_count_z) catch |err| return errorLogger(err);
}

pub export fn apeCmdDispatchBase(p_cmd: vk.CommandBuffer, base_group_x: u32, base_group_y: u32, base_group_z: u32, group_count_x: u32, group_count_y: u32, group_count_z: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdDispatchBase);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.dispatchBase(base_group_x, base_group_y, base_group_z, group_count_x, group_count_y, group_count_z) catch |err| return errorLogger(err);
}

pub export fn apeCmdDispatchBaseKHR(p_cmd: vk.CommandBuffer, base_group_x: u32, base_group_y: u32, base_group_z: u32, group_count_x: u32, group_count_y: u32, group_count_z: u32) callconv(vk.vulkan_call_conv) void {
    @call(.always_inline, apeCmdDispatchBase, .{ p_cmd, base_group_x, base_group_y, base_group_z, group_count_x, group_count_y, group_count_z });
}

pub export fn apeCmdDispatchIndirect(p_cmd: vk.CommandBuffer, p_buffer: vk.Buffer, offset: vk.DeviceSize) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdDispatchIndirect);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const buffer = NonDispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);
    cmd.dispatchIndirect(buffer, offset) catch |err| return errorLogger(err);
}

pub export fn apeCmdDraw(p_cmd: vk.CommandBuffer, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdDraw);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.draw(vertex_count, instance_count, first_vertex, first_instance) catch |err| return errorLogger(err);
}

pub export fn apeCmdDrawIndexed(p_cmd: vk.CommandBuffer, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdDrawIndexed);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.drawIndexed(index_count, instance_count, first_index, vertex_offset, first_instance) catch |err| return errorLogger(err);
}

pub export fn apeCmdDrawIndexedIndirect(p_cmd: vk.CommandBuffer, p_buffer: vk.Buffer, offset: vk.DeviceSize, count: u32, stride: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdDrawIndexedIndirect);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const buffer = NonDispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);
    cmd.drawIndexedIndirect(buffer, offset, count, stride) catch |err| return errorLogger(err);
}

pub export fn apeCmdDrawIndirect(p_cmd: vk.CommandBuffer, p_buffer: vk.Buffer, offset: vk.DeviceSize, count: u32, stride: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdDrawIndirect);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const buffer = NonDispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);
    cmd.drawIndirect(buffer, offset, count, stride) catch |err| return errorLogger(err);
}

pub export fn apeCmdEndQuery(p_cmd: vk.CommandBuffer, p_pool: vk.QueryPool, query: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdEndQuery);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const pool = NonDispatchable(QueryPool).fromHandleObject(p_pool) catch |err| return errorLogger(err);
    cmd.endQuery(pool, query) catch |err| return errorLogger(err);
}

pub export fn apeCmdEndRenderPass(p_cmd: vk.CommandBuffer) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdEndRenderPass);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.endRenderPass() catch |err| return errorLogger(err);
}

pub export fn apeCmdExecuteCommands(p_cmd: vk.CommandBuffer, count: u32, p_cmds: [*]const vk.CommandBuffer) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdExecuteCommands);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    for (p_cmds, 0..count) |p_sec_cmd, _| {
        const sec_cmd = Dispatchable(CommandBuffer).fromHandleObject(p_sec_cmd) catch |err| return errorLogger(err);
        cmd.executeCommands(sec_cmd) catch |err| return errorLogger(err);
    }
}

pub export fn apeCmdFillBuffer(p_cmd: vk.CommandBuffer, p_buffer: vk.Buffer, offset: vk.DeviceSize, size: vk.DeviceSize, data: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdFillBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const buffer = NonDispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);
    cmd.fillBuffer(buffer, offset, size, data) catch |err| return errorLogger(err);
}

pub export fn apeCmdNextSubpass(p_cmd: vk.CommandBuffer, contents: vk.SubpassContents) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdNextSubpass);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.nextSubpass(contents) catch |err| return errorLogger(err);
}

pub export fn apeCmdPipelineBarrier(
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
    cmd.pipelineBarrier(
        src_stage_mask,
        dst_stage_mask,
        dependency_flags,
        memory_barriers[0..memory_barrier_count],
        buffer_memory_barriers[0..buffer_memory_barrier_count],
        image_memory_barriers[0..image_memory_barrier_count],
    ) catch |err| return errorLogger(err);
}

pub export fn apeCmdPushConstants(p_cmd: vk.CommandBuffer, layout: vk.PipelineLayout, flags: vk.ShaderStageFlags, offset: u32, size: u32, data: [*]const u8) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdPushConstants);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.pushConstants(flags, offset, data[0..size]) catch |err| return errorLogger(err);

    _ = layout; // Pipelines embed their layout which is more trustworthy
}

pub export fn apeCmdResetQueryPool(p_cmd: vk.CommandBuffer, p_pool: vk.QueryPool, first: u32, count: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdResetQueryPool);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const pool = NonDispatchable(QueryPool).fromHandleObject(p_pool) catch |err| return errorLogger(err);
    cmd.resetQueryPool(pool, first, count) catch |err| return errorLogger(err);
}

pub export fn apeCmdResetEvent(p_cmd: vk.CommandBuffer, p_event: vk.Event, stage_mask: vk.PipelineStageFlags) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdResetEvent);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const event = NonDispatchable(Event).fromHandleObject(p_event) catch |err| return errorLogger(err);
    cmd.resetEvent(event, stage_mask) catch |err| return errorLogger(err);
}

pub export fn apeCmdResolveImage(
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
    const src = NonDispatchable(Image).fromHandleObject(p_src) catch |err| return errorLogger(err);
    const dst = NonDispatchable(Image).fromHandleObject(p_dst) catch |err| return errorLogger(err);
    cmd.resolveImage(src, src_layout, dst, dst_layout, regions[0..count]) catch |err| return errorLogger(err);
}

pub export fn apeCmdSetBlendConstants(p_cmd: vk.CommandBuffer, p_constants: [*]f32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetBlendConstants);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const constants = [4]f32{ p_constants[0], p_constants[1], p_constants[2], p_constants[3] };

    cmd.setBlendConstants(constants) catch |err| return errorLogger(err);
}

pub export fn apeCmdSetDepthBias(p_cmd: vk.CommandBuffer, constant_factor: f32, clamp: f32, slope_factor: f32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetDepthBias);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.setDepthBias(constant_factor, clamp, slope_factor) catch |err| return errorLogger(err);
}

pub export fn apeCmdSetDepthBounds(p_cmd: vk.CommandBuffer, min: f32, max: f32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetDepthBounds);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.setDepthBounds(min, max) catch |err| return errorLogger(err);
}

pub export fn apeCmdSetDeviceMask(p_cmd: vk.CommandBuffer, device_mask: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetDeviceMask);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.setDeviceMask(device_mask) catch |err| return errorLogger(err);
}

pub export fn apeCmdSetDeviceMaskKHR(p_cmd: vk.CommandBuffer, device_mask: u32) callconv(vk.vulkan_call_conv) void {
    @call(.always_inline, apeCmdSetDeviceMask, .{ p_cmd, device_mask });
}

pub export fn apeCmdSetEvent(p_cmd: vk.CommandBuffer, p_event: vk.Event, stage_mask: vk.PipelineStageFlags) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetEvent);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const event = NonDispatchable(Event).fromHandleObject(p_event) catch |err| return errorLogger(err);
    cmd.setEvent(event, stage_mask) catch |err| return errorLogger(err);
}

pub export fn apeCmdSetLineWidth(p_cmd: vk.CommandBuffer, width: f32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetLineWidth);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.setLineWidth(width) catch |err| return errorLogger(err);
}

pub export fn apeCmdSetScissor(p_cmd: vk.CommandBuffer, first: u32, count: u32, scissors: [*]const vk.Rect2D) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetScissor);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.setScissor(first, scissors[0..count]) catch |err| return errorLogger(err);
}

pub export fn apeCmdSetStencilCompareMask(p_cmd: vk.CommandBuffer, face_mask: vk.StencilFaceFlags, compare_mask: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetStencilCompareMask);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.setStencilCompareMask(face_mask, compare_mask) catch |err| return errorLogger(err);
}

pub export fn apeCmdSetStencilReference(p_cmd: vk.CommandBuffer, face_mask: vk.StencilFaceFlags, reference: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetStencilReference);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.setStencilReference(face_mask, reference) catch |err| return errorLogger(err);
}

pub export fn apeCmdSetStencilWriteMask(p_cmd: vk.CommandBuffer, face_mask: vk.StencilFaceFlags, write_mask: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetStencilWriteMask);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.setStencilWriteMask(face_mask, write_mask) catch |err| return errorLogger(err);
}

pub export fn apeCmdSetViewport(p_cmd: vk.CommandBuffer, first: u32, count: u32, viewports: [*]const vk.Viewport) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdSetViewport);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    cmd.setViewport(first, viewports[0..count]) catch |err| return errorLogger(err);
}

pub export fn apeCmdUpdateBuffer(p_cmd: vk.CommandBuffer, p_buffer: vk.Buffer, offset: vk.DeviceSize, size: vk.DeviceSize, data: *const anyopaque) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdUpdateBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const buffer = NonDispatchable(Buffer).fromHandleObject(p_buffer) catch |err| return errorLogger(err);
    const data_bytes: [*]const u8 = @ptrCast(data);
    cmd.updateBuffer(buffer, offset, data_bytes[0..size]) catch |err| return errorLogger(err);
}

pub export fn apeCmdWaitEvents(
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

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    for (p_events, 0..count) |p_event, _| {
        const event = NonDispatchable(Event).fromHandleObject(p_event) catch |err| return errorLogger(err);
        cmd.waitEvent(
            event,
            src_stage_mask,
            dst_stage_mask,
            memory_barriers[0..memory_barrier_count],
            buffer_memory_barriers[0..buffer_memory_barrier_count],
            image_memory_barriers[0..image_memory_barrier_count],
        ) catch |err| return errorLogger(err);
    }
}

pub export fn apeCmdWriteTimestamp(p_cmd: vk.CommandBuffer, stage: vk.PipelineStageFlags, p_pool: vk.QueryPool, query: u32) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkCmdWriteTimestamp);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return errorLogger(err);
    const pool = NonDispatchable(QueryPool).fromHandleObject(p_pool) catch |err| return errorLogger(err);
    cmd.writeTimestamp(stage, pool, query) catch |err| return errorLogger(err);
}

pub export fn apeEndCommandBuffer(p_cmd: vk.CommandBuffer) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkEndCommandBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return toVkResult(err);
    cmd.end() catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeResetCommandBuffer(p_cmd: vk.CommandBuffer, flags: vk.CommandBufferResetFlags) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkResetCommandBuffer);
    defer entryPointEndLogTrace();

    const cmd = Dispatchable(CommandBuffer).fromHandleObject(p_cmd) catch |err| return toVkResult(err);
    cmd.reset(flags) catch |err| return toVkResult(err);
    return .success;
}

// WSI functions ===================================================================================================================================

pub export fn apeAcquireNextImageKHR(p_device: vk.Device, p_swapchain: vk.SwapchainKHR, timeout: u64, p_semaphore: vk.Semaphore, p_fence: vk.Fence, image_index: *u32) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkAcquireNextImageKHR);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const swapchain = NonDispatchable(SwapchainKHR).fromHandleObject(p_swapchain) catch |err| return toVkResult(err);
    const semaphore = if (p_semaphore != .null_handle) NonDispatchable(BinarySemaphore).fromHandleObject(p_semaphore) catch |err| return toVkResult(err) else null;
    const fence = if (p_fence != .null_handle) NonDispatchable(Fence).fromHandleObject(p_fence) catch |err| return toVkResult(err) else null;
    swapchain.getNextImage(timeout, semaphore, fence, image_index) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeAcquireNextImage2KHR(p_device: vk.Device, p_acquire_info: *const vk.AcquireNextImageInfoKHR, image_index: *u32) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkAcquireNextImage2KHR);
    defer entryPointEndLogTrace();

    if (p_acquire_info.s_type != .acquire_next_image_info_khr) {
        return .error_validation_failed;
    }

    if (p_acquire_info.device_mask != 1) {
        return .error_validation_failed;
    }

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const swapchain = NonDispatchable(SwapchainKHR).fromHandleObject(p_acquire_info.swapchain) catch |err| return toVkResult(err);
    const semaphore = if (p_acquire_info.semaphore != .null_handle) NonDispatchable(BinarySemaphore).fromHandleObject(p_acquire_info.semaphore) catch |err| return toVkResult(err) else null;
    const fence = if (p_acquire_info.fence != .null_handle) NonDispatchable(Fence).fromHandleObject(p_acquire_info.fence) catch |err| return toVkResult(err) else null;
    swapchain.getNextImage(p_acquire_info.timeout, semaphore, fence, image_index) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateSwapchainKHR(p_device: vk.Device, info: *const vk.SwapchainCreateInfoKHR, callbacks: ?*const vk.AllocationCallbacks, p_swapchain: *vk.SwapchainKHR) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkCreateSwapchainKHR);
    defer entryPointEndLogTrace();

    if (info.s_type != .swapchain_create_info_khr) {
        return .error_validation_failed;
    }

    if (info.old_swapchain != .null_handle) {
        const old_swapchain = NonDispatchable(SwapchainKHR).fromHandleObject(info.old_swapchain) catch |err| return toVkResult(err);
        old_swapchain.detachSurface() catch |err| return toVkResult(err);
    }

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const device = Dispatchable(Device).fromHandleObject(p_device) catch |err| return toVkResult(err);
    const surface = NonDispatchable(SurfaceKHR).fromHandleObject(info.surface) catch |err| return toVkResult(err);
    const swapchain = SwapchainKHR.create(device, allocator, surface, info) catch |err| return toVkResult(err);
    p_swapchain.* = wrapNonDispatchable(SwapchainKHR, allocator, swapchain, vk.SwapchainKHR) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeCreateWaylandSurfaceKHR(p_instance: vk.Instance, info: *const vk.WaylandSurfaceCreateInfoKHR, callbacks: ?*const vk.AllocationCallbacks, p_surface: *vk.SurfaceKHR) callconv(vk.vulkan_call_conv) vk.Result {
    if (comptime has_wayland) {
        entryPointBeginLogTrace(.vkCreateWaylandSurfaceKHR);
        defer entryPointEndLogTrace();

        if (info.s_type != .wayland_surface_create_info_khr) {
            return .error_validation_failed;
        }
        const allocator = VulkanAllocator.init(callbacks, .object).allocator();
        const instance = Dispatchable(Instance).fromHandleObject(p_instance) catch |err| return toVkResult(err);
        const surface = WaylandSurfaceKHR.create(instance, allocator, info) catch |err| return toVkResult(err);
        p_surface.* = wrapNonDispatchable(SurfaceKHR, allocator, surface, vk.SurfaceKHR) catch |err| return toVkResult(err);
        return .success;
    } else {
        return .error_unknown;
    }
}

pub export fn apeDestroySurfaceKHR(p_instance: vk.Instance, p_surface: vk.SurfaceKHR, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroySurfaceKHR);
    defer entryPointEndLogTrace();

    NonDispatchable(Instance).checkHandleValidity(p_instance) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(SurfaceKHR).fromHandle(p_surface) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeDestroySwapchainKHR(p_device: vk.Device, p_swapchain: vk.SwapchainKHR, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    entryPointBeginLogTrace(.vkDestroySwapchainKHR);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return errorLogger(err);

    const allocator = VulkanAllocator.init(callbacks, .object).allocator();
    const non_dispatchable = NonDispatchable(SwapchainKHR).fromHandle(p_swapchain) catch |err| return errorLogger(err);
    non_dispatchable.intrusiveDestroy(allocator);
}

pub export fn apeGetPhysicalDeviceSurfaceCapabilitiesKHR(p_physical_device: vk.PhysicalDevice, p_surface: vk.SurfaceKHR, capabilities: *vk.SurfaceCapabilitiesKHR) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceSurfaceCapabilitiesKHR);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);
    const surface = NonDispatchable(SurfaceKHR).fromHandleObject(p_surface) catch |err| return toVkResult(err);
    physical_device.getSurfaceCapabilitiesKHR(surface, capabilities) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeGetPhysicalDeviceSurfaceFormatsKHR(p_physical_device: vk.PhysicalDevice, p_surface: vk.SurfaceKHR, count: *u32, p_formats: ?[*]vk.SurfaceFormatKHR) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceSurfaceFormatsKHR);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);
    const surface = NonDispatchable(SurfaceKHR).fromHandleObject(p_surface) catch |err| return toVkResult(err);
    physical_device.getSurfaceFormatsKHR(surface, count, p_formats) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeGetPhysicalDeviceSurfacePresentModesKHR(p_physical_device: vk.PhysicalDevice, p_surface: vk.SurfaceKHR, count: *u32, p_modes: ?[*]vk.PresentModeKHR) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceSurfacePresentModesKHR);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);
    const surface = NonDispatchable(SurfaceKHR).fromHandleObject(p_surface) catch |err| return toVkResult(err);
    physical_device.getSurfacePresentModesKHR(surface, count, p_modes) catch |err| return toVkResult(err);
    return .success;
}

pub export fn apeGetPhysicalDeviceSurfaceSupportKHR(p_physical_device: vk.PhysicalDevice, queue_family_index: u32, p_surface: vk.SurfaceKHR, p_supported: *vk.Bool32) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetPhysicalDeviceSurfaceSupportKHR);
    defer entryPointEndLogTrace();

    const physical_device = Dispatchable(PhysicalDevice).fromHandleObject(p_physical_device) catch |err| return toVkResult(err);
    const surface = NonDispatchable(SurfaceKHR).fromHandleObject(p_surface) catch |err| return toVkResult(err);
    p_supported.* = if (physical_device.getSurfaceSupportKHR(queue_family_index, surface) catch |err| return toVkResult(err)) .true else .false;
    return .success;
}

/// TODO: proper implementation when adding new drivers
pub export fn apeGetPhysicalDeviceWaylandPresentationSupportKHR(p_physical_device: vk.PhysicalDevice, _: u32, _: *anyopaque) callconv(vk.vulkan_call_conv) vk.Bool32 {
    if (comptime has_wayland) {
        entryPointBeginLogTrace(.vkGetPhysicalDeviceWaylandPresentationSupportKHR);
        defer entryPointEndLogTrace();

        Dispatchable(PhysicalDevice).checkHandleValidity(p_physical_device) catch |err| errorLogger(err);
        return .true;
    } else {
        return .false;
    }
}

pub export fn apeGetSwapchainImagesKHR(p_device: vk.Device, p_swapchain: vk.SwapchainKHR, count: *u32, p_images: ?[*]vk.Image) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkGetSwapchainImagesKHR);
    defer entryPointEndLogTrace();

    Dispatchable(Device).checkHandleValidity(p_device) catch |err| return toVkResult(err);

    const swapchain = NonDispatchable(SwapchainKHR).fromHandleObject(p_swapchain) catch |err| return toVkResult(err);
    count.* = @intCast(swapchain.images.len);
    if (p_images) |images| {
        for (images[0..], swapchain.images[0..]) |*image, *swapchain_image| {
            image.* = swapchain_image.non_dispatchable_image.toVkHandle(vk.Image);
        }
    }

    return .success;
}

pub export fn apeQueuePresentKHR(p_queue: vk.Queue, info: *const vk.PresentInfoKHR) callconv(vk.vulkan_call_conv) vk.Result {
    entryPointBeginLogTrace(.vkQueuePresentKHR);
    defer entryPointEndLogTrace();

    if (info.s_type != .present_info_khr) {
        return .error_validation_failed;
    }
    const queue = Dispatchable(Queue).fromHandleObject(p_queue) catch |err| return toVkResult(err);
    queue.presentKHR(info) catch |err| return toVkResult(err);
    return .success;
}
