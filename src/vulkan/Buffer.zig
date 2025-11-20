const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const DeviceMemory = @import("DeviceMemory.zig");
const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .buffer;

owner: *Device,
size: vk.DeviceSize,
offset: vk.DeviceSize,
usage: vk.BufferUsageFlags,
memory: ?*DeviceMemory,
allowed_memory_types: u32,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
    getMemoryRequirements: *const fn (*Self, *vk.MemoryRequirements) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.BufferCreateInfo) VkError!Self {
    _ = allocator;
    return .{
        .owner = device,
        .size = info.size,
        .offset = 0,
        .usage = info.usage,
        .memory = null,
        .allowed_memory_types = 0,
        .vtable = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}

pub inline fn bindMemory(self: *Self, memory: *DeviceMemory, offset: vk.DeviceSize) VkError!void {
    if (offset >= self.size or self.allowed_memory_types & memory.memory_type_index == 0) {
        return VkError.ValidationFailed;
    }
    self.memory = memory;
    self.offset = offset;
}

pub inline fn getMemoryRequirements(self: *Self, requirements: *vk.MemoryRequirements) void {
    requirements.size = self.size;
    requirements.memory_type_bits = self.allowed_memory_types;
    self.vtable.getMemoryRequirements(self, requirements);
}
