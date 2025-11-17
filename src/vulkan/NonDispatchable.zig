const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;

pub fn NonDispatchable(comptime T: type) type {
    return struct {
        const Self = @This();

        object_type: vk.ObjectType,
        object: *T,

        pub fn wrap(allocator: std.mem.Allocator, object: *T) VkError!*Self {
            const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
            self.* = .{
                .object_type = T.ObjectType,
                .object = object,
            };
            return self;
        }

        pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            allocator.destroy(self);
        }

        pub inline fn toHandle(self: *Self) usize {
            return @intFromPtr(self);
        }

        pub inline fn toVkHandle(self: *Self, comptime VkT: type) VkT {
            return @enumFromInt(@intFromPtr(self));
        }

        pub inline fn fromHandle(vk_handle: anytype) VkError!*Self {
            const handle = @intFromEnum(vk_handle);
            if (handle == 0) {
                return VkError.ValidationFailed;
            }
            const non_dispatchable: *Self = @ptrFromInt(handle);
            if (non_dispatchable.object_type != T.ObjectType) {
                return VkError.ValidationFailed;
            }
            return non_dispatchable;
        }

        pub inline fn fromHandleObject(handle: anytype) VkError!*T {
            const non_dispatchable_handle = try Self.fromHandle(handle);
            return non_dispatchable_handle.object;
        }
    };
}
