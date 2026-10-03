const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const lib = @import("lib.zig");
const PsvkDevice = @import("PsvkDevice.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.PhysicalDevice;
pub const extensions = [_]vk.ExtensionProperties{};
interface: Interface,

pub fn create(allocator: std.mem.Allocator, instance: *base.Instance) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, instance);

    interface.dispatch_table = &.{
        .createDevice = createDevice,
        .getFormatProperties = getFormatProperties,
        .getImageFormatProperties = getImageFormatProperties,
        .getSparseImageFormatProperties = getSparseImageFormatProperties,
        .enumerateLayerProperties = enumerateLayerProperties,
        .enumerateExtensionProperties = enumerateExtensionProperties,
        .release = destroy,
        .getSparseImageFormatProperties2 = getSparseImageFormatProperties2,
        .getSurfaceSupportKHR = getSurfaceSupportKHR,
    };
    interface.props.api_version = @bitCast(lib.vulkan_version);
    interface.props.device_type = .other;
    const name = "Psvk";
    @memcpy(interface.props.device_name[0..name.len], name);
    interface.mem_props.memory_type_count = 1;
    interface.mem_props.memory_types[0] = .{ .heap_index = 0 };
    interface.mem_props.memory_heap_count = 1;
    interface.mem_props.memory_heaps[0] = .{ .size = 0 };
    interface.queue_family_props.append(allocator, .{
        .queue_flags = .{
            .graphics = true,
            .compute = true,
            .transfer = true,
        },
        .queue_count = 1,
        .timestamp_valid_bits = 0,
        .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
    }) catch return VkError.OutOfHostMemory;
    self.* = .{
        .interface = interface,
    };

    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    allocator.destroy(self);
}

pub fn createDevice(interface: *Interface, allocator: std.mem.Allocator, info: *const vk.DeviceCreateInfo) VkError!*base.Device {
    return &(try PsvkDevice.create(interface.instance, interface, allocator, info)).interface;
}

pub fn enumerateLayerProperties(_: *const Interface, count: *u32, _: ?[*]vk.LayerProperties) VkError!void {
    count.* = 0;
}

pub fn enumerateExtensionProperties(_: *const Interface, layer_name: ?[]const u8, count: *u32, _: ?[*]vk.ExtensionProperties) VkError!void {
    if (layer_name != null) return VkError.LayerNotPresent;
    count.* = 0;
}

pub fn getFormatProperties(_: *Interface, _: vk.Format) VkError!vk.FormatProperties {
    return .{};
}

pub fn getImageFormatProperties(_: *Interface, _: vk.Format, _: vk.ImageType, _: vk.ImageTiling, _: vk.ImageUsageFlags, _: vk.ImageCreateFlags) VkError!vk.ImageFormatProperties {
    return VkError.FormatNotSupported;
}

pub fn getSparseImageFormatProperties(_: *Interface, _: vk.Format, _: vk.ImageType, _: vk.SampleCountFlags, _: vk.ImageTiling, _: vk.ImageUsageFlags, _: ?[*]vk.SparseImageFormatProperties) VkError!u32 {
    return 0;
}

pub fn getSparseImageFormatProperties2(_: *Interface, _: vk.Format, _: vk.ImageType, _: vk.SampleCountFlags, _: vk.ImageTiling, _: vk.ImageUsageFlags, _: ?[*]vk.SparseImageFormatProperties2) VkError!u32 {
    return 0;
}

pub fn getSurfaceSupportKHR(_: *Interface, _: u32, _: *base.SurfaceKHR) VkError!bool {
    return false;
}
