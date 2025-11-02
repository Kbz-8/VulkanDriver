const std = @import("std");
const vk = @import("vulkan");
const common = @import("common");

const Instance = @import("Instance.zig");

pub const VULKAN_VERSION = vk.makeApiVersion(0, 1, 0, 0);
pub const DRIVER_VERSION = vk.makeApiVersion(0, 0, 0, 1);
pub const DEVICE_ID = 0x600DCAFE;

const global_pfn_map = std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
    .{ "vkGetInstanceProcAddr", @as(vk.PfnVoidFunction, @ptrCast(&common.icd.getInstanceProcAddr)) },
    .{ "vkCreateInstance", @as(vk.PfnVoidFunction, @ptrCast(&Instance.create)) },
});

pub export fn vkGetInstanceProcAddr(p_instance: vk.Instance, pName: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    if (pName == null) {
        return null;
    }
    const name = std.mem.span(pName.?);
    return common.icd.getInstanceProcAddr(global_pfn_map, p_instance, name);
}
