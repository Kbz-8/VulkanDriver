const std = @import("std");
const vk = @import("vulkan");
const c = @cImport({
    @cInclude("vulkan/vk_icd.h");
});

const VkError = @import("error_set.zig").VkError;

pub fn Dispatchable(comptime T: type) type {
    return extern struct {
        const Self = @This();

        loader_data: c.VK_LOADER_DATA,
        object_type: vk.ObjectType,
        object: *T,

        pub fn wrap(allocator: std.mem.Allocator, object: *T) VkError!*Self {
            const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
            self.* = .{
                .loader_data = .{ .loaderMagic = c.ICD_LOADER_MAGIC },
                .object_type = T.ObjectType,
                .object = object,
            };
            return self;
        }

        pub inline fn intrusiveDestroy(self: *Self, allocator: std.mem.Allocator) void {
            self.object.destroy(allocator);
            allocator.destroy(self);
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
            const dispatchable: *Self = @ptrFromInt(handle);
            if (dispatchable.object_type != T.ObjectType) {
                return VkError.ValidationFailed;
            }
            return dispatchable;
        }

        pub inline fn fromHandleObject(handle: anytype) VkError!*T {
            const dispatchable_handle = try Self.fromHandle(handle);
            return dispatchable_handle.object;
        }

        pub inline fn checkHandleValidity(handle: anytype) VkError!void {
            _ = try Self.fromHandle(handle);
        }
    };
}
