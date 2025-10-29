const std = @import("std");
const vk = @import("vulkan");
const c = @cImport({
    @cInclude("vulkan/vk_icd.h");
});

const Instance = @import("Instance.zig").Instance;
const fromHandle = @import("object.zig").fromHandle;

pub fn getInstanceProcAddr(vk_instance: vk.Instance, name: []const u8) vk.PfnVoidFunction {
    _ = fromHandle(Instance, vk.Instance, vk_instance) catch .{};

    inline for (.{
        "vkCreateInstance",
        "vkDestroyInstance",
        "vkGetInstanceProcAddr",
    }) |sym| {
        if (std.mem.eql(u8, name, sym)) {
            //const f = @field(Instance.vtable, sym);
            return @ptrFromInt(12);
        }
    }
    return null;
}
