const std = @import("std");
const vk = @import("vulkan");
const dispatchable = @import("dispatchable.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .instance;

alloc_callbacks: vk.AllocationCallbacks,

vtable: VTable,

pub fn init(self: *Self, p_infos: ?*const vk.InstanceCreateInfo, callbacks: ?*const vk.AllocationCallbacks) !void {
    const infos = p_infos orelse return error.NullCreateInfos;
    if (infos.s_type != .instance_create_info) {
        return error.InvalidCreateInfos;
    }

    self.vtable = .{};

    if (callbacks) |c| {
        self.alloc_callbacks = c.*;
    }
}

pub fn getProcAddr(self: *const Self, name: []const u8) vk.PfnVoidFunction {
    const allocator = std.heap.c_allocator;

    const KV = struct { []const u8, vk.PfnVoidFunction };
    const pfn_map = std.StaticStringMap(vk.PfnVoidFunction).init([_]KV{
        .{ "vkDestroyInstance", @ptrCast(self.vtable.destroyInstance) },
        .{ "vkEnumeratePhysicalDevices", @ptrCast(self.vtable.enumeratePhysicalDevices) },
        .{ "vkEnumerateInstanceVersion", @ptrCast(self.vtable.enumerateInstanceVersion) },
        .{ "vkEnumerateInstanceExtensionProperties", @ptrCast(self.vtable.enumerateInstanceExtensionProperties) },
        .{ "vkGetPhysicalDeviceProperties", @ptrCast(self.vtable.getPhysicalDeviceProperties) },
    }, allocator) catch return null;
    defer pfn_map.deinit(allocator);

    return if (pfn_map.get(name)) |pfn| pfn else null;
}

pub const VTable = struct {
    destroyInstance: ?vk.PfnDestroyInstance = null,
    enumeratePhysicalDevices: ?vk.PfnEnumeratePhysicalDevices = null,
    enumerateInstanceVersion: ?vk.PfnEnumerateInstanceVersion = null,
    //enumerateInstanceLayerProperties: vk.PfnEnumerateInstanceProperties = null,
    enumerateInstanceExtensionProperties: ?vk.PfnEnumerateInstanceExtensionProperties = null,
    getPhysicalDeviceProperties: ?vk.PfnGetPhysicalDeviceProperties = null,
};
