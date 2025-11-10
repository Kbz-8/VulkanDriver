const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const root = @import("lib.zig");
const cpuinfo = @import("cpuinfo");

const SoftDevice = @import("SoftDevice.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.PhysicalDevice;

interface: Interface,

pub fn create(allocator: std.mem.Allocator, instance: *const base.Instance) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, instance);

    interface.dispatch_table = &.{
        .createDevice = createDevice,
        .getFormatProperties = getFormatProperties,
        .getImageFormatProperties = getImageFormatProperties,
        .getSparseImageFormatProperties = getSparseImageFormatProperties,
        .release = destroy,
    };

    interface.props.api_version = @bitCast(root.VULKAN_VERSION);
    interface.props.driver_version = @bitCast(root.DRIVER_VERSION);
    interface.props.device_id = root.DEVICE_ID;
    interface.props.device_type = .cpu;

    interface.mem_props.memory_type_count = 1;
    interface.mem_props.memory_types[0] = .{
        .heap_index = 0,
        .property_flags = .{
            .device_local_bit = true,
            .host_visible_bit = true,
            .host_coherent_bit = true,
            .host_cached_bit = true,
        },
    };
    interface.mem_props.memory_heap_count = 1;
    interface.mem_props.memory_heaps[0] = .{
        .size = std.process.totalSystemMemory() catch 0,
        .flags = .{}, // Host memory
    };

    interface.features = .{
        .robust_buffer_access = .true,
        .shader_float_64 = .true,
        .shader_int_64 = .true,
        .shader_int_16 = .true,
    };

    var queue_family_props = [_]vk.QueueFamilyProperties{
        .{
            .queue_flags = .{ .graphics_bit = true, .compute_bit = true, .transfer_bit = true },
            .queue_count = 1,
            .timestamp_valid_bits = 0,
            .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
        },
        .{
            .queue_flags = .{ .graphics_bit = true },
            .queue_count = 1,
            .timestamp_valid_bits = 0,
            .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
        },
        .{
            .queue_flags = .{ .transfer_bit = true },
            .queue_count = 1,
            .timestamp_valid_bits = 0,
            .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
        },
    };
    interface.queue_family_props = std.ArrayList(vk.QueueFamilyProperties).fromOwnedSlice(queue_family_props[0..]);

    // TODO: use Pytorch's cpuinfo someday
    const info = cpuinfo.get(allocator) catch return VkError.InitializationFailed;
    defer info.deinit(allocator);

    var writer = std.Io.Writer.fixed(interface.props.device_name[0 .. vk.MAX_PHYSICAL_DEVICE_NAME_SIZE - 1]);
    writer.print("{s} [" ++ root.DRIVER_NAME ++ " StrollDriver]", .{info.name}) catch return VkError.InitializationFailed;

    self.* = .{
        .interface = interface,
    };
    return self;
}

pub fn createDevice(interface: *Interface, allocator: std.mem.Allocator, infos: *const vk.DeviceCreateInfo) VkError!*base.Device {
    const device = try SoftDevice.create(interface, allocator, infos);
    return &device.interface;
}

pub fn getFormatProperties(interface: *Interface, format: vk.Format) VkError!vk.FormatProperties {
    _ = interface;
    _ = format;
    return .{};
}

pub fn getImageFormatProperties(
    interface: *Interface,
    format: vk.Format,
    image_type: vk.ImageType,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    flags: vk.ImageCreateFlags,
) VkError!vk.ImageFormatProperties {
    _ = interface;
    _ = format;
    _ = image_type;
    _ = tiling;
    _ = usage;
    _ = flags;
    return VkError.FormatNotSupported;
}

pub fn getSparseImageFormatProperties(
    interface: *Interface,
    format: vk.Format,
    image_type: vk.ImageType,
    samples: vk.SampleCountFlags,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    flags: vk.ImageCreateFlags,
) VkError!vk.SparseImageFormatProperties {
    _ = interface;
    _ = format;
    _ = image_type;
    _ = samples;
    _ = tiling;
    _ = usage;
    _ = flags;
    return VkError.FormatNotSupported;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}
