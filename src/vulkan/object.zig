const vk = @import("vulkan");
const c = @cImport({
    @cInclude("vulkan/vk_icd.h");
});

pub const Object = extern struct {
    const Self = @This();

    loader_data: c.VK_LOADER_DATA,
    kind: vk.ObjectType,
    owner: ?*anyopaque,
    // VK_EXT_debug_utils
    name: ?[]const u8,

    pub fn init(owner: ?*anyopaque, kind: vk.ObjectType) Self {
        return .{
            .loader_data = c.ICD_LOADER_MAGIC,
            .kind = kind,
            .owner = owner,
            .name = null,
        };
    }
};

pub inline fn fromHandle(comptime T: type, comptime VkT: type, handle: VkT) !*T {
    if (handle == .null_handle) {
        return error.NullHandle;
    }

    if (!@hasDecl(T, "object")) {
        return error.NotAnObject;
    }
    if (!@hasDecl(T, "ObjectType") || @TypeOf(T.ObjectType) != vk.ObjectType) {
        @panic("Object type \"" ++ @typeName(T) ++ "\" is malformed.");
    }

    const dispatchable: *T = @ptrFromInt(@intFromEnum(handle));
    if (dispatchable.object.kind != T.ObjectType) {
        return error.InvalidObjectType;
    }
    return dispatchable;
}
