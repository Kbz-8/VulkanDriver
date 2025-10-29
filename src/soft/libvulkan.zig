const std = @import("std");
const vk = @import("vulkan");
const common = @import("common");

pub export fn vk_icdGetInstanceProcAddr(instance: vk.Instance, pName: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    if (pName == null) {
        return null;
    }
    const name = std.mem.span(pName.?);
    return common.icd.getInstanceProcAddr(instance, name);
}
