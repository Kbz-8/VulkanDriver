const std = @import("std");
const vk = @import("vulkan");

pub const icd = @import("icd.zig");
pub const Instance = @import("Instance.zig");
pub const PhysicalDevice = @import("PhysicalDevice.zig");

pub export fn vkGetInstanceProcAddr(instance: vk.Instance, pName: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    if (pName == null) {
        return null;
    }
    const name = std.mem.span(pName.?);
    return icd.getInstanceProcAddr(instance, name);
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
