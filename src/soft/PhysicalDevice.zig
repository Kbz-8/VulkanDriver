const std = @import("std");
const vk = @import("vulkan");
const Instance = @import("Instance.zig");
const common = @import("common");

const dispatchable = common.dispatchable;

const Self = @This();
const ObjectType: vk.ObjectType = .physical_device;

instance: *const Instance,
common_physical_device: common.PhysicalDevice,

pub fn init(self: *Self) !void {
    self.common_physical_device.props = .{
			.apiVersion = ,
			.driverVersion = VKD_DRIVER_VERSION,
			.vendorID = 0x0601,
			.deviceID = 0x060103,
			.deviceType = VK_PHYSICAL_DEVICE_TYPE_CPU,
			.deviceName = {},
			.pipelineCacheUUID = {},
			.limits = {},
			.sparseProperties = {},
		};
}
