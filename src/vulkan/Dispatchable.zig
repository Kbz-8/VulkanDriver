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
        is_owner: bool = false,

        pub fn create(allocator: std.mem.Allocator, args: anytype) VkError!*Self {
            comptime {
                const ti = @typeInfo(@TypeOf(args));
                if (ti != .@"struct" or !ti.@"struct".is_tuple) {
                    @compileError("pass a tuple literal like .{...}");
                }

                if (!std.meta.hasMethod(T, "init")) {
                    @compileError("Dispatchable types are expected to have 'init' and 'deinit' methods.");
                }
                const init_params = @typeInfo(@TypeOf(T.init)).@"fn".params;
                if (init_params.len < 1 or init_params[0].type != std.mem.Allocator) {
                    @compileError("Dispatchable types 'init' method should take a 'std.mem.Allocator' as its first parameter.");
                }
            }

            const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
            const object = allocator.create(T) catch return VkError.OutOfHostMemory;
            object.* = try @call(.auto, T.init, .{allocator} ++ args);
            self.is_owner = true;
            return self.wrap(object);
        }

        pub fn wrap(allocator: std.mem.Allocator, object: *T) VkError!*Self {
            const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
            self.* = .{
                .loader_data = .{ .loaderMagic = c.ICD_LOADER_MAGIC },
                .object_type = T.ObjectType,
                .object = object,
            };
            return self;
        }

        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            if (self.is_owner) {
                allocator.destroy(self.object);
            }
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
                return VkError.Unknown;
            }
            const dispatchable: *Self = @ptrFromInt(handle);
            if (dispatchable.object_type != T.ObjectType) {
                return VkError.Unknown;
            }
            return dispatchable;
        }

        pub inline fn fromHandleObject(handle: anytype) VkError!*T {
            const dispatchable_handle = try Self.fromHandle(handle);
            return dispatchable_handle.object;
        }
    };
}
