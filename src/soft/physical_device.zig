const std = @import("std");
const vk = @import("vulkan");
const Instance = @import("Instance.zig");
const base = @import("base");
const root = @import("lib.zig");
const cpuinfo = @import("cpuinfo");

pub fn setup(allocator: std.mem.Allocator, physical_device: *base.PhysicalDevice) !void {
    physical_device.props.api_version = @bitCast(root.VULKAN_VERSION);
    physical_device.props.driver_version = @bitCast(root.DRIVER_VERSION);
    physical_device.props.device_id = root.DEVICE_ID;
    physical_device.props.device_type = .cpu;

    physical_device.mem_props.memory_type_count = 1;
    physical_device.mem_props.memory_types[0] = .{
        .heap_index = 0,
        .property_flags = .{
            .host_visible_bit = true,
            .host_coherent_bit = true,
        },
    };
    physical_device.mem_props.memory_heap_count = 1;
    physical_device.mem_props.memory_heaps[0] = .{
        .size = std.process.totalSystemMemory() catch 0,
        .flags = .{}, // Host memory
    };

    const info = try cpuinfo.get(allocator);
    defer info.deinit(allocator);

    var writer = std.io.Writer.fixed(physical_device.props.device_name[0 .. vk.MAX_PHYSICAL_DEVICE_NAME_SIZE - 1]);
    try writer.print("{s} [Soft Vulkan Driver]", .{info.name});
}
