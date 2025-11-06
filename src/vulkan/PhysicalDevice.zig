const std = @import("std");
const vk = @import("vulkan");
const root = @import("lib.zig");

const Instance = @import("Instance.zig");
const VkError = @import("error_set.zig").VkError;
const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .physical_device;

props: vk.PhysicalDeviceProperties,
mem_props: vk.PhysicalDeviceMemoryProperties,
features: vk.PhysicalDeviceFeatures,
queue_family_props: std.ArrayList(vk.QueueFamilyProperties),
instance: *const Instance,
dispatch_table: *const DispatchTable,

pub const DispatchTable = struct {
    createDevice: *const fn (*Self, std.mem.Allocator, *const vk.DeviceCreateInfo) VkError!*Device,
    getFormatProperties: *const fn (*Self, vk.Format) VkError!vk.FormatProperties,
    getImageFormatProperties: *const fn (*Self, vk.Format, vk.ImageType, vk.ImageTiling, vk.ImageUsageFlags, vk.ImageCreateFlags) VkError!vk.ImageFormatProperties,
    getSparseImageFormatProperties: *const fn (*Self, vk.Format, vk.ImageType, vk.SampleCountFlags, vk.ImageTiling, vk.ImageUsageFlags, vk.ImageCreateFlags) VkError!vk.SparseImageFormatProperties,
    release: *const fn (*Self, std.mem.Allocator) VkError!void,
};

pub fn init(allocator: std.mem.Allocator, instance: *const Instance) VkError!Self {
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
            .limits = undefined,
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

pub fn createDevice(self: *Self, allocator: std.mem.Allocator, infos: *const vk.DeviceCreateInfo) VkError!*Device {
    return try self.dispatch_table.createDevice(self, allocator, infos);
}

pub fn getFormatProperties(self: *Self, format: vk.Format) VkError!vk.FormatProperties {
    return try self.dispatch_table.getFormatProperties(self, format);
}

pub fn getImageFormatProperties(
    self: *Self,
    format: vk.Format,
    image_type: vk.ImageType,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    flags: vk.ImageCreateFlags,
) VkError!vk.ImageFormatProperties {
    return try self.dispatch_table.getImageFormatProperties(self, format, image_type, tiling, usage, flags);
}

pub fn getSparseImageFormatProperties(
    self: *Self,
    format: vk.Format,
    image_type: vk.ImageType,
    samples: vk.SampleCountFlags,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    flags: vk.ImageCreateFlags,
) VkError!vk.SparseImageFormatProperties {
    return try self.dispatch_table.getSparseImageFormatProperties(self, format, image_type, samples, tiling, usage, flags);
}

pub fn releasePhysicalDevice(self: *Self, allocator: std.mem.Allocator) VkError!void {
    try self.dispatch_table.release(self, allocator);
}
