const std = @import("std");
const vk = @import("vulkan");
const c = @cImport({
    @cInclude("vulkan/vk_icd.h");
});

const Instance = @import("Instance.zig");
const dispatchable = @import("dispatchable.zig");

pub fn getInstanceProcAddr(global_pfn_map: std.StaticStringMap(vk.PfnVoidFunction), p_instance: vk.Instance, name: []const u8) vk.PfnVoidFunction {
    const allocator = std.heap.c_allocator;
    const get_proc_log = std.log.scoped(.vkGetInstanceProcAddr);

    if (std.process.hasEnvVar(allocator, "DRIVER_LOGS") catch false) {
        get_proc_log.info("Loading {s}...", .{name});
    }

    if (global_pfn_map.get(name)) |pfn| {
        return pfn;
    }
    const instance = dispatchable.fromHandle(Instance, @intFromEnum(p_instance)) catch |e| {
        if (std.process.hasEnvVar(allocator, "DRIVER_LOGS") catch false) {
            get_proc_log.err("{any}", .{e});
        }
        return null;
    };
    return instance.object.getProcAddr(name);
}
