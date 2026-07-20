const std = @import("std");

pub const TypeTag = opaque {};
pub const ConstantTag = opaque {};
pub const ValueTag = opaque {};
pub const InstructionTag = opaque {};
pub const BlockTag = opaque {};
pub const FunctionTag = opaque {};
pub const InterfaceVariableTag = opaque {};
pub const ResourceTag = opaque {};

pub const TypeId = Id(TypeTag);
pub const ConstantId = Id(ConstantTag);
pub const ValueId = Id(ValueTag);
pub const InstructionId = Id(InstructionTag);
pub const BlockId = Id(BlockTag);
pub const FunctionId = Id(FunctionTag);
pub const InterfaceVariableId = Id(InterfaceVariableTag);
pub const ResourceId = Id(ResourceTag);

pub fn Id(comptime Tag: type) type {
    return enum(u32) {
        _,

        pub const tag_type = Tag;

        pub fn fromIndex(item_index: usize) @This() {
            std.debug.assert(item_index <= std.math.maxInt(u32));
            return @enumFromInt(item_index);
        }

        pub fn index(self: @This()) usize {
            return @intFromEnum(self);
        }
    };
}

pub fn Store(comptime IdType: type, comptime T: type) type {
    return struct {
        const Self = @This();

        entries: std.ArrayList(?T) = .empty,

        pub fn add(self: *Self, allocator: std.mem.Allocator, value: T) !IdType {
            const id = IdType.fromIndex(self.entries.items.len);
            try self.entries.append(allocator, value);
            return id;
        }

        pub fn get(self: *const Self, id: IdType) ?*const T {
            if (id.index() >= self.entries.items.len)
                return null;

            const entry = &self.entries.items[id.index()];
            return if (entry.*) |*value| value else null;
        }

        pub fn getMut(self: *Self, id: IdType) ?*T {
            if (id.index() >= self.entries.items.len)
                return null;

            const entry = &self.entries.items[id.index()];
            return if (entry.*) |*value| value else null;
        }

        /// Removing an object leaves a tombstone as IDs are deliberately not recycled
        /// so they are never silently redirected to a different object.
        pub fn remove(self: *Self, id: IdType) bool {
            if (id.index() >= self.entries.items.len)
                return false;

            const entry = &self.entries.items[id.index()];
            if (entry.* == null)
                return false;

            entry.* = null;
            return true;
        }

        pub fn isLive(self: *const Self, id: IdType) bool {
            return self.get(id) != null;
        }
    };
}
