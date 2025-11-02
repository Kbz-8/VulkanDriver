const std = @import("std");
const vk = @import("vulkan");
const Instance = @import("Instance.zig");
const common = @import("common");
const root = @import("root");

const dispatchable = common.dispatchable;

const Self = @This();
pub const ObjectType: vk.ObjectType = .physical_device;

instance: *const Instance,
common_physical_device: common.PhysicalDevice,

pub fn init(self: *Self) !void {
    self.common_physical_device.props = .{
        .api_version = @bitCast(root.VULKAN_VERSION),
        .driver_version = @bitCast(root.DRIVER_VERSION),
        .vendor_id = common.VULKAN_VENDOR_ID,
        .device_id = root.DEVICE_ID,
        .device_type = .cpu,
        .device_name = [_]u8{0} ** vk.MAX_PHYSICAL_DEVICE_NAME_SIZE,
        .pipeline_cache_uuid = undefined,
        .limits = undefined,
        .sparse_properties = undefined,
    };
    var writer = std.io.Writer.fixed(&self.common_physical_device.props.device_name);
    try writer.print("Software Vulkan Driver", .{});
}

pub fn getProperties(p_physical_device: vk.PhysicalDevice, properties: *vk.PhysicalDeviceProperties) callconv(vk.vulkan_call_conv) void {
    const physical_device = dispatchable.fromHandleObject(Self, @intFromEnum(p_physical_device)) catch return;
    properties.* = physical_device.common_physical_device.props;
}
