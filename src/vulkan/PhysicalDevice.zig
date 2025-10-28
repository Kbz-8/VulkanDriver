const vk = @import("vulkan");
const Instance = @import("Instance.zig").Instance;
const Object = @import("object.zig").Object;

pub const PhysicalDevice = extern struct {
    const Self = @This();
    const ObjectType: vk.ObjectType = .physical_device;

    object: Object,

    instance: *Instance,
    props: vk.PhysicalDeviceProperties,
    queue_families: [3]vk.QueueFamilyProperties,
};
