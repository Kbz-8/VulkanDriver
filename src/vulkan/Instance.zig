const std = @import("std");
const vk = @import("vulkan");
const root = @import("lib.zig");
const VkError = @import("error_set.zig").VkError;

extern fn __vkImplInstanceInit(*Self, *const std.mem.Allocator, *const vk.InstanceCreateInfo) ?*anyopaque;

const Self = @This();
pub const ObjectType: vk.ObjectType = .instance;

physical_devices: std.ArrayList(vk.PhysicalDevice),
dispatch_table: DispatchTable,
driver_data: ?*anyopaque,

pub const DispatchTable = struct {
    destroyInstance: ?*const fn (*const Self, std.mem.Allocator) anyerror!void = null,
};

pub fn init(allocator: std.mem.Allocator, infos: *const vk.InstanceCreateInfo) VkError!Self {
    var self: Self = .{
        .dispatch_table = .{},
        .physical_devices = .empty,
        .driver_data = null,
    };

    self.driver_data = __vkImplInstanceInit(&self, &allocator, infos) orelse return VkError.InitializationFailed;
    std.debug.assert(self.physical_devices.items.len != 0);

    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (self.dispatch_table.destroyInstance) |pfnDestroyInstance| {
        pfnDestroyInstance(self, allocator) catch return;
    } else if (std.process.hasEnvVar(allocator, root.DRIVER_LOGS_ENV_NAME) catch false) {
        std.log.scoped(.vkDestroyInstance).warn("Missing dispatch implementation", .{});
    }
}
