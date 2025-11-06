const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const root = @import("lib.zig");
const cpuinfo = @import("cpuinfo");

const Device = @import("Device.zig");
const Instance = @import("Instance.zig");

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
            .host_visible_bit = true,
            .host_coherent_bit = true,
        },
    };
    interface.mem_props.memory_heap_count = 1;
    interface.mem_props.memory_heaps[0] = .{
        .size = std.process.totalSystemMemory() catch 0,
        .flags = .{}, // Host memory
    };

    const info = cpuinfo.get(allocator) catch return VkError.InitializationFailed;
    defer info.deinit(allocator);

    var writer = std.Io.Writer.fixed(interface.props.device_name[0 .. vk.MAX_PHYSICAL_DEVICE_NAME_SIZE - 1]);
    writer.print("{s} [" ++ root.DRIVER_NAME ++ " StrollDriver]", .{info.name}) catch return VkError.InitializationFailed;

    self.* = .{
        .interface = interface,
    };
    return self;
}

pub fn createDevice(interface: *Interface, allocator: std.mem.Allocator, infos: *const vk.DeviceCreateInfo) VkError!*Device.Interface {
    const device = try Device.create(interface, allocator, infos);
    return &device.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}
