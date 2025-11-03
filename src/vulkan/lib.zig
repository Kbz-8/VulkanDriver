const std = @import("std");
const vk = @import("vulkan");

pub const icd = @import("icd.zig");
pub const dispatchable = @import("dispatchable.zig");

pub const Instance = @import("Instance.zig");
pub const PhysicalDevice = @import("PhysicalDevice.zig");
pub const VulkanAllocator = @import("VulkanAllocator.zig");
pub const Device = @import("Device.zig");

pub const VULKAN_VENDOR_ID = @typeInfo(vk.VendorId).@"enum".fields[@typeInfo(vk.VendorId).@"enum".fields.len - 1].value + 1;
pub const DRIVER_LOGS_ENV_NAME = "DRIVER_LOGS";

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logFn,
};

pub fn logFn(comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    _ = level;
    _ = scope;
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.fs.File.stderr().deprecatedWriter();
    nosuspend stderr.print(format ++ "\n", args) catch return;
}

pub fn retrieveDriverDataAs(handle: anytype, comptime T: type) !*T {
    comptime {
        switch (@typeInfo(@TypeOf(handle))) {
            .pointer => |p| std.debug.assert(@hasField(p.child, "driver_data")),
            else => @compileError("Invalid type passed to 'retrieveDriverDataAs': " ++ @typeName(@TypeOf(handle))),
        }
    }
    return @ptrCast(@alignCast(@field(handle, "driver_data")));
}

const global_pfn_map = std.StaticStringMap(vk.PfnVoidFunction).initComptime(.{
    .{ "vkGetInstanceProcAddr", @as(vk.PfnVoidFunction, @ptrCast(&icd.getInstanceProcAddr)) },
    .{ "vkCreateInstance", @as(vk.PfnVoidFunction, @ptrCast(&Instance.create)) },
});

pub export fn vkGetInstanceProcAddr(p_instance: vk.Instance, p_name: ?[*:0]const u8) callconv(vk.vulkan_call_conv) vk.PfnVoidFunction {
    if (p_name == null) {
        return null;
    }
    const name = std.mem.span(p_name.?);
    return icd.getInstanceProcAddr(global_pfn_map, p_instance, name);
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
