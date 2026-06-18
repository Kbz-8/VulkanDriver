const std = @import("std");
const vk = @import("vulkan");
const root = @import("lib.zig");
const utils = @import("utils.zig");

const Instance = @import("Instance.zig");
const VkError = @import("error_set.zig").VkError;
const Device = @import("Device.zig");
const SurfaceKHR = @import("wsi/SurfaceKHR.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .physical_device;

props: vk.PhysicalDeviceProperties,
mem_props: vk.PhysicalDeviceMemoryProperties,
features: vk.PhysicalDeviceFeatures,
queue_family_props: std.ArrayList(vk.QueueFamilyProperties),
instance: *Instance,
dispatch_table: *const DispatchTable,

pub const DispatchTable = struct {
    createDevice: *const fn (*Self, std.mem.Allocator, *const vk.DeviceCreateInfo) VkError!*Device,
    getFormatProperties: *const fn (*Self, vk.Format) VkError!vk.FormatProperties,
    getImageFormatProperties: *const fn (*Self, vk.Format, vk.ImageType, vk.ImageTiling, vk.ImageUsageFlags, vk.ImageCreateFlags) VkError!vk.ImageFormatProperties,
    getSparseImageFormatProperties: *const fn (*Self, vk.Format, vk.ImageType, vk.SampleCountFlags, vk.ImageTiling, vk.ImageUsageFlags, ?[*]vk.SparseImageFormatProperties) VkError!u32,
    enumerateExtensionProperties: *const fn (*const Self, ?[]const u8, *u32, ?[*]vk.ExtensionProperties) VkError!void,
    enumerateLayerProperties: *const fn (*const Self, *u32, ?[*]vk.LayerProperties) VkError!void,
    release: *const fn (*Self, std.mem.Allocator) VkError!void,

    // VK_KHR_get_physical_device_properties_2
    getSparseImageFormatProperties2: ?*const fn (*Self, vk.Format, vk.ImageType, vk.SampleCountFlags, vk.ImageTiling, vk.ImageUsageFlags, ?[*]vk.SparseImageFormatProperties2) VkError!u32,

    // VK_KHR_surface
    getSurfaceSupportKHR: ?*const fn (*Self, u32, *SurfaceKHR) VkError!bool,
};

pub fn init(allocator: std.mem.Allocator, instance: *Instance) VkError!Self {
    _ = allocator;
    return .{
        .props = .{
            .api_version = undefined,
            .driver_version = undefined,
            .vendor_id = root.VULKAN_VENDOR_ID,
            .device_id = undefined,
            .device_type = undefined,
            .device_name = [_]u8{0} ** vk.MAX_PHYSICAL_DEVICE_NAME_SIZE,
            .pipeline_cache_uuid = undefined,
            .limits = std.mem.zeroInit(vk.PhysicalDeviceLimits, .{}),
            .sparse_properties = undefined,
        },
        .mem_props = .{
            .memory_type_count = 0,
            .memory_types = undefined,
            .memory_heap_count = 0,
            .memory_heaps = undefined,
        },
        .queue_family_props = .empty,
        .features = .{},
        .instance = instance,
        .dispatch_table = undefined,
    };
}

pub inline fn createDevice(self: *Self, allocator: std.mem.Allocator, infos: *const vk.DeviceCreateInfo) VkError!*Device {
    return try self.dispatch_table.createDevice(self, allocator, infos);
}

pub fn validateCreateInfo(self: *const Self, allocator: std.mem.Allocator, info: *const vk.DeviceCreateInfo) VkError!void {
    if (info.enabled_layer_count != 0) {
        const names = info.pp_enabled_layer_names orelse return VkError.LayerNotPresent;
        for (0..info.enabled_layer_count) |i| {
            _ = utils.boundedName(names[i], vk.MAX_EXTENSION_NAME_SIZE) orelse return VkError.LayerNotPresent;
            return VkError.LayerNotPresent;
        }
    }

    if (info.enabled_extension_count != 0) {
        const names = info.pp_enabled_extension_names orelse return VkError.ExtensionNotPresent;

        var available_count: u32 = 0;
        try self.enumerateExtensionProperties(null, &available_count, null);
        const supported_extensions = allocator.alloc(vk.ExtensionProperties, available_count) catch return VkError.OutOfHostMemory;
        defer allocator.free(supported_extensions);

        var written_count = available_count;
        try self.enumerateExtensionProperties(null, &written_count, supported_extensions.ptr);

        for (0..info.enabled_extension_count) |i| {
            const name = utils.boundedName(names[i], vk.MAX_EXTENSION_NAME_SIZE) orelse return VkError.ExtensionNotPresent;
            if (!utils.isSupportedExtension(name, supported_extensions[0..written_count])) {
                return VkError.ExtensionNotPresent;
            }
        }
    }

    if (info.p_enabled_features) |requested_features| {
        inline for (std.meta.fields(vk.PhysicalDeviceFeatures)) |field| {
            if (@field(requested_features, field.name) == .true and @field(self.features, field.name) == .false) {
                return VkError.FeatureNotPresent;
            }
        }
    }
}

pub inline fn getFormatProperties(self: *Self, format: vk.Format) VkError!vk.FormatProperties {
    return try self.dispatch_table.getFormatProperties(self, format);
}

pub inline fn enumerateExtensionProperties(self: *const Self, layer_name: ?[]const u8, count: *u32, p_properties: ?[*]vk.ExtensionProperties) VkError!void {
    return try self.dispatch_table.enumerateExtensionProperties(self, layer_name, count, p_properties);
}

pub inline fn enumerateLayerProperties(self: *const Self, count: *u32, p_properties: ?[*]vk.LayerProperties) VkError!void {
    return try self.dispatch_table.enumerateLayerProperties(self, count, p_properties);
}

pub inline fn getImageFormatProperties(
    self: *Self,
    format: vk.Format,
    image_type: vk.ImageType,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    flags: vk.ImageCreateFlags,
) VkError!vk.ImageFormatProperties {
    return self.dispatch_table.getImageFormatProperties(self, format, image_type, tiling, usage, flags);
}

pub inline fn getSparseImageFormatProperties(
    self: *Self,
    format: vk.Format,
    image_type: vk.ImageType,
    samples: vk.SampleCountFlags,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    properties: ?[*]vk.SparseImageFormatProperties,
) VkError!u32 {
    return self.dispatch_table.getSparseImageFormatProperties(self, format, image_type, samples, tiling, usage, properties);
}

pub fn release(self: *Self, allocator: std.mem.Allocator) VkError!void {
    self.queue_family_props.deinit(allocator);
    self.queue_family_props = .empty;
    try self.dispatch_table.release(self, allocator);
}

pub fn getSparseImageFormatProperties2(
    self: *Self,
    format: vk.Format,
    image_type: vk.ImageType,
    samples: vk.SampleCountFlags,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    properties: ?[*]vk.SparseImageFormatProperties2,
) VkError!u32 {
    return if (self.dispatch_table.getSparseImageFormatProperties2) |pfn|
        pfn(self, format, image_type, samples, tiling, usage, properties)
    else
        0;
}

pub fn getSurfaceCapabilitiesKHR(_: *Self, surface: *SurfaceKHR, capabilities: *vk.SurfaceCapabilitiesKHR) VkError!void {
    capabilities.* = try surface.getCapabilities();
}

pub fn getSurfaceFormatsKHR(_: *Self, _: *SurfaceKHR, count: *u32, p_formats: ?[*]vk.SurfaceFormatKHR) VkError!void {
    const surface_formats = SurfaceKHR.getFormats();
    count.* = surface_formats.len;
    if (p_formats) |formats| {
        for (formats[0..], surface_formats[0..]) |*format, surface_format| {
            format.* = surface_format;
        }
    }
}

pub fn getSurfacePresentModesKHR(_: *Self, _: *SurfaceKHR, count: *u32, p_modes: ?[*]vk.PresentModeKHR) VkError!void {
    const surface_modes = SurfaceKHR.getPresentModes();
    count.* = surface_modes.len;
    if (p_modes) |modes| {
        for (modes[0..], surface_modes[0..]) |*mode, surface_mode| {
            mode.* = surface_mode;
        }
    }
}

pub fn getSurfaceSupportKHR(self: *Self, queue_family_index: u32, surface: *SurfaceKHR) VkError!bool {
    return if (self.dispatch_table.getSurfaceSupportKHR) |pfn|
        pfn(self, queue_family_index, surface)
    else
        false;
}
