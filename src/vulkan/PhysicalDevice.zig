const std = @import("std");
const vk = @import("vulkan");
const root = @import("lib.zig");
const Instance = @import("Instance.zig");
const Device = @import("Device.zig");
const dispatchable = @import("dispatchable.zig");
const VulkanAllocator = @import("VulkanAllocator.zig");

const Dispatchable = dispatchable.Dispatchable;

const Self = @This();
pub const ObjectType: vk.ObjectType = .physical_device;

props: vk.PhysicalDeviceProperties,
mem_props: vk.PhysicalDeviceMemoryProperties,
instance: *const Instance,
dispatch_table: DispatchTable,
driver_data: ?*anyopaque,

pub const DispatchTable = struct {
    createImplDevice: ?*const fn (*Self, vk.DeviceCreateInfo, std.mem.Allocator) anyerror!?*anyopaque,
};

pub fn init(instance: *const Instance, allocator: std.mem.Allocator) !*Dispatchable(Self) {
    const dispatchable_physical_device = try Dispatchable(Self).create(allocator);
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

    self.mem_props = .{
        .memory_type_count = 0,
        .memory_types = undefined,
        .memory_heap_count = 0,
        .memory_heaps = undefined,
    };

    self.driver_data = null;
    self.instance = instance;
    self.dispatch_table = .{};

    return dispatchable_physical_device;
}

pub fn createDevice(p_physical_device: vk.PhysicalDevice, p_infos: ?*const vk.DeviceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_device: *vk.Device) callconv(vk.vulkan_call_conv) vk.Result {
    const infos = p_infos orelse return .error_initialization_failed;
    if (infos.s_type != .device_create_info) {
        return .error_initialization_failed;
    }

    const self = dispatchable.fromHandleObject(Self, @intFromEnum(p_physical_device)) catch return .error_unknown;

    const deref_callbacks = if (callbacks) |c| c.* else null;

    const allocator = VulkanAllocator.init(deref_callbacks, .instance).allocator();

    const dispatchable_device = Dispatchable(Device).create(allocator) catch return .error_out_of_host_memory;
    const device = dispatchable_device.object;
    device.dispatch_table = .{};

    if (self.dispatch_table.createImplDevice) |pfnCreateImplDevice| {
        device.driver_data = pfnCreateImplDevice(self, infos, allocator) catch return .error_initialization_failed;
    } else if (std.process.hasEnvVar(allocator, root.DRIVER_LOGS_ENV_NAME) catch false) {
        std.log.scoped(.vkCreateDevice).warn("Missing dispatch implementation", .{});
    }

    p_device.* = @enumFromInt(dispatchable_device.toHandle());
    return .success;
}

pub fn getProperties(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceProperties) callconv(vk.vulkan_call_conv) void {
    const self = dispatchable.fromHandleObject(Self, @intFromEnum(p_physical_device)) catch return;
    properties.* = self.props;
}

pub fn getMemoryProperties(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceMemoryProperties) callconv(vk.vulkan_call_conv) void {
    const self = dispatchable.fromHandleObject(Self, @intFromEnum(p_physical_device)) catch return;
    properties.* = self.mem_props;
}

pub fn getProcAddr(name: []const u8) vk.PfnVoidFunction {
    const allocator = std.heap.c_allocator;

    const KV = struct { []const u8, vk.PfnVoidFunction };
    const pfn_map = std.StaticStringMap(vk.PfnVoidFunction).init([_]KV{
        .{ "vkCreateDevice", @ptrCast(&createDevice) },
        .{ "vkGetPhysicalDeviceProperties", @ptrCast(&getProperties) },
        .{ "vkGetPhysicalDeviceMemoryProperties", @ptrCast(&getMemoryProperties) },
    }, allocator) catch return null;
    defer pfn_map.deinit(allocator);

    return if (pfn_map.get(name)) |pfn| pfn else null;
}
