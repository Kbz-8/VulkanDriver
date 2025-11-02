const vk = @import("vulkan");
const Instance = @import("Instance.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .physical_device;

props: vk.PhysicalDeviceProperties,
queue_families: [3]vk.QueueFamilyProperties,
