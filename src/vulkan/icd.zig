const std = @import("std");
const vk = @import("vulkan");
const c = @cImport({
    @cInclude("vulkan/vk_icd.h");
});

const Instance = @import("Instance.zig").Instance;
const fromHandle = @import("object.zig").fromHandle;

const global_pfn_map = std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
    .{ "vkGetInstanceProcAddr", @as(vk.PfnVoidFunction, @ptrCast(&getInstanceProcAddr)) },
    .{ "vkCreateInstance", @as(vk.PfnVoidFunction, @ptrCast(&Instance.vtable.createInstance)) },
});

pub fn getInstanceProcAddr(instance: vk.Instance, name: []const u8) vk.PfnVoidFunction {
    if (global_pfn_map.get(name)) |pfn| {
        return pfn;
    }
    if (instance != .null_handle) {}
    return null;
}
