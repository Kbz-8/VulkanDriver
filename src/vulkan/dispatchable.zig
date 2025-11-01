const std = @import("std");
const vk = @import("vulkan");
const c = @cImport({
    @cInclude("vulkan/vk_icd.h");
});

pub fn Dispatchable(comptime T: type) type {
    return extern struct {
        const Self = @This();

        loader_data: c.VK_LOADER_DATA,
        object_type: vk.ObjectType,
        object: *T,

        pub fn create(allocator: std.mem.Allocator, object_type: vk.ObjectType) !*Self {
            const object = try allocator.create(Self);
            object.* = .{
                .loader_data = .{ .loaderMagic = c.ICD_LOADER_MAGIC },
                .object_type = object_type,
                .object = try allocator.create(T),
            };
            return object;
        }

        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            allocator.destroy(self.object);
            allocator.destroy(self);
        }
    };
}

pub inline fn fromHandle(comptime T: type, handle: usize) !*Dispatchable(T) {
    if (handle == 0) {
        return error.NullHandle;
    }
    const dispatchable: *Dispatchable(T) = @ptrFromInt(handle);
    if (dispatchable.object_type != T.ObjectType) {
        return error.InvalidType;
    }
    return dispatchable;
}

pub inline fn toHandle(comptime T: type, handle: *Dispatchable(T)) usize {
    return @intFromPtr(handle);
}
