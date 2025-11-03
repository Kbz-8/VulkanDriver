const std = @import("std");
const vk = @import("vulkan");
const Instance = @import("Instance.zig");
const base = @import("base");
const root = @import("lib.zig");
const cpuinfo = @import("cpuinfo");

const dispatchable = base.dispatchable;

const Self = @This();

pub fn init(instance: *const base.Instance, allocator: std.mem.Allocator) !*dispatchable.Dispatchable(base.PhysicalDevice) {
    const dispatchable_physical_device = try base.PhysicalDevice.init(instance, allocator);
    errdefer dispatchable_physical_device.destroy(allocator);

    const base_physical_device = dispatchable_physical_device.object;

    base_physical_device.props.api_version = @bitCast(root.VULKAN_VERSION);
    base_physical_device.props.driver_version = @bitCast(root.DRIVER_VERSION);
    base_physical_device.props.device_id = root.DEVICE_ID;
    base_physical_device.props.device_type = .cpu;

    base_physical_device.mem_props.memory_type_count = 1;
    base_physical_device.mem_props.memory_types[0] = .{
        .heap_index = 0,
        .property_flags = .{
            .host_visible_bit = true,
            .host_coherent_bit = true,
        },
    };
    base_physical_device.mem_props.memory_heap_count = 1;
    base_physical_device.mem_props.memory_heaps[0] = .{
        .size = std.process.totalSystemMemory() catch 0,
        .flags = .{}, // Host memory
    };

    const info = try cpuinfo.get(allocator);
    defer info.deinit(allocator);

    var writer = std.io.Writer.fixed(base_physical_device.props.device_name[0 .. vk.MAX_PHYSICAL_DEVICE_NAME_SIZE - 1]);
    try writer.print("{s} [Soft Vulkan Driver]", .{info.name});

    return dispatchable_physical_device;
}
