const std = @import("std");
const vk = @import("vulkan");
const root = @import("lib.zig");
const dispatchable = @import("dispatchable.zig");
const VulkanAllocator = @import("VulkanAllocator.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");

extern fn __vkImplInstanceInit(*Self, *const std.mem.Allocator) ?*anyopaque;

const Self = @This();
pub const ObjectType: vk.ObjectType = .instance;

alloc_callbacks: ?vk.AllocationCallbacks,
physical_devices: std.ArrayList(vk.PhysicalDevice),
dispatch_table: DispatchTable,
driver_data: ?*anyopaque,

pub const DispatchTable = struct {
    destroyInstance: ?*const fn (*const Self, std.mem.Allocator) anyerror!void = null,
    enumerateInstanceVersion: ?vk.PfnEnumerateInstanceVersion = null,
    //enumerateInstanceLayerProperties: vk.PfnEnumerateInstanceProperties = null,
    enumerateInstanceExtensionProperties: ?vk.PfnEnumerateInstanceExtensionProperties = null,
};

pub fn create(p_infos: ?*const vk.InstanceCreateInfo, callbacks: ?*const vk.AllocationCallbacks, p_instance: *vk.Instance) callconv(vk.vulkan_call_conv) vk.Result {
    const infos = p_infos orelse return .error_initialization_failed;
    if (infos.s_type != .instance_create_info) {
        return .error_initialization_failed;
    }

    const deref_callbacks = if (callbacks) |c| c.* else null;

    const allocator = VulkanAllocator.init(deref_callbacks, .instance).allocator();

    const dispatchable_instance = dispatchable.Dispatchable(Self).create(allocator) catch return .error_out_of_host_memory;
    const self = dispatchable_instance.object;
    self.dispatch_table = .{};

    self.alloc_callbacks = deref_callbacks;
    self.physical_devices = .empty;

    self.driver_data = __vkImplInstanceInit(self, &allocator) orelse return .error_initialization_failed;
    std.debug.assert(self.physical_devices.items.len != 0);

    p_instance.* = @enumFromInt(dispatchable_instance.toHandle());
    return .success;
}

pub fn destroy(p_instance: vk.Instance, callbacks: ?*const vk.AllocationCallbacks) callconv(vk.vulkan_call_conv) void {
    const allocator = VulkanAllocator.init(if (callbacks) |c| c.* else null, .instance).allocator();

    const dispatchable_instance = dispatchable.fromHandle(Self, @intFromEnum(p_instance)) catch return;
    defer dispatchable_instance.destroy(allocator);

    const self: *const Self = @ptrCast(dispatchable_instance.object);
    if (self.dispatch_table.destroyInstance) |pfnDestroyInstance| {
        pfnDestroyInstance(self, allocator) catch return;
    } else if (std.process.hasEnvVar(allocator, root.DRIVER_LOGS_ENV_NAME) catch false) {
        std.log.scoped(.vkDestroyInstance).warn("Missing dispatch implementation", .{});
    }
}

pub fn enumeratePhysicalDevices(p_instance: vk.Instance, count: *u32, p_devices: ?[*]vk.PhysicalDevice) callconv(vk.vulkan_call_conv) vk.Result {
    const self = dispatchable.fromHandleObject(Self, @intFromEnum(p_instance)) catch return .error_unknown;
    count.* = @intCast(self.physical_devices.items.len);
    if (p_devices) |devices| {
        @memcpy(devices[0..self.physical_devices.items.len], self.physical_devices.items);
    }
    return .success;
}

pub fn getProcAddr(name: []const u8) vk.PfnVoidFunction {
    const allocator = std.heap.c_allocator;

    const KV = struct { []const u8, vk.PfnVoidFunction };
    const pfn_map = std.StaticStringMap(vk.PfnVoidFunction).init([_]KV{
        .{ "vkDestroyInstance", @ptrCast(&destroy) },
        .{ "vkEnumeratePhysicalDevices", @ptrCast(&enumeratePhysicalDevices) },
        //.{ "vkGetPhysicalDeviceProperties", @ptrCast(self.dispatch_table.getPhysicalDeviceProperties) },
    }, allocator) catch return null;
    defer pfn_map.deinit(allocator);

    // Falling back on PhysicalDevice's getProcAddr which will return null if not found
    return if (pfn_map.get(name)) |pfn| pfn else PhysicalDevice.getProcAddr(name);
}
