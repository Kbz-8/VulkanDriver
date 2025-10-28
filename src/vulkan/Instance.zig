const vk = @import("vulkan");
const Object = @import("object.zig").Object;

pub const Instance = extern struct {
    const Self = @This();
    const ObjectType: vk.ObjectType = .instance;

    object: Object,
};
