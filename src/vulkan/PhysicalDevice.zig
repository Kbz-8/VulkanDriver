const std = @import("std");
const vk = @import("vulkan");
const root = @import("lib.zig");
const Instance = @import("Instance.zig");
const dispatchable = @import("dispatchable.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .physical_device;

props: vk.PhysicalDeviceProperties,
instance: *const Instance,
dispatch_table: DispatchTable,
driver_data: ?*anyopaque,

pub const DispatchTable = struct {};

pub fn init(instance: *const Instance, allocator: std.mem.Allocator) !*dispatchable.Dispatchable(Self) {
    const dispatchable_physical_device = try dispatchable.Dispatchable(Self).create(allocator);
    errdefer dispatchable_physical_device.destroy(allocator);

    const self = dispatchable_physical_device.object;

    self.props = .{
        .api_version = undefined,
        .driver_version = undefined,
        .vendor_id = root.VULKAN_VENDOR_ID,
        .device_id = undefined,
        .device_type = undefined,
        .device_name = [_]u8{0} ** vk.MAX_PHYSICAL_DEVICE_NAME_SIZE,
        .pipeline_cache_uuid = undefined,
        .limits = undefined,
        .sparse_properties = undefined,
    };

    self.driver_data = null;
    self.instance = instance;
    self.dispatch_table = .{};

    return dispatchable_physical_device;
}

pub fn getProperties(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceProperties) callconv(vk.vulkan_call_conv) void {
    const self = dispatchable.fromHandleObject(Self, @intFromEnum(p_physical_device)) catch return;
    properties.* = self.props;
}

pub fn getProcAddr(name: []const u8) vk.PfnVoidFunction {
    const allocator = std.heap.c_allocator;

    const KV = struct { []const u8, vk.PfnVoidFunction };
    const pfn_map = std.StaticStringMap(vk.PfnVoidFunction).init([_]KV{
        .{ "vkGetPhysicalDeviceProperties", @ptrCast(&getProperties) },
    }, allocator) catch return null;
    defer pfn_map.deinit(allocator);

    return if (pfn_map.get(name)) |pfn| pfn else null;
}
