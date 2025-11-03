const std = @import("std");
const vk = @import("vulkan");
const root = @import("lib.zig");
const c = @cImport({
    @cInclude("vulkan/vk_icd.h");
});

const Instance = @import("Instance.zig");
const dispatchable = @import("dispatchable.zig");

pub fn getInstanceProcAddr(global_pfn_map: std.StaticStringMap(vk.PfnVoidFunction), p_instance: vk.Instance, name: []const u8) vk.PfnVoidFunction {
    const allocator = std.heap.c_allocator;
    const get_proc_log = std.log.scoped(.vkGetInstanceProcAddr);

    if (std.process.hasEnvVar(allocator, root.DRIVER_LOGS_ENV_NAME) catch false) {
        get_proc_log.info("Loading {s}...", .{name});
    }

    if (global_pfn_map.get(name)) |pfn| {
        return pfn;
    }

    // Checks if instance is NULL
    _ = dispatchable.fromHandle(Instance, @intFromEnum(p_instance)) catch |e| {
        if (std.process.hasEnvVar(allocator, root.DRIVER_LOGS_ENV_NAME) catch false) {
            get_proc_log.err("{any}", .{e});
        }
        return null;
    };
    return Instance.getProcAddr(name);
}
