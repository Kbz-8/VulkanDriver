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
    comptime {
        if (!@hasDecl(T, "object") or !@hasDecl(T, "ObjectType") or @TypeOf(T.ObjectType) != vk.ObjectType) {
            @compileError("Object type \"" ++ @typeName(T) ++ "\" is malformed.");
        }
    }

    if (handle == .null_handle) {
        return error.NullHandle;
    }

    const dispatchable: *T = @ptrFromInt(@intFromEnum(handle));
    if (dispatchable.object.kind != T.ObjectType) {
        return error.InvalidObjectType;
    }
    return dispatchable;
}

pub inline fn toHandle(comptime T: type, handle: *T) usize {
    comptime {
        if (!@hasDecl(T, "object") or !@hasDecl(T, "ObjectType") or @TypeOf(T.ObjectType) != vk.ObjectType) {
            @compileError("Object type \"" ++ @typeName(T) ++ "\" is malformed.");
        }
    }
    return @intFromPtr(handle);
}
