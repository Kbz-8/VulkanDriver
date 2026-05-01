const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("../error_set.zig").VkError;

const Device = @import("../Device.zig");
const DeviceMemory = @import("../DeviceMemory.zig");
const Image = @import("../Image.zig");

pub const State = enum {
    Available,
    Drawing,
    Presenting,
};

const Self = @This();

image: *Image,
memory: *DeviceMemory,
state: State,

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.ImageCreateInfo) VkError!Self {
    const image = try device.createImage(allocator, info);
    errdefer image.destroy(allocator);

    const requirements: vk.MemoryRequirements = undefined;
    try image.getMemoryRequirements(&requirements);

    const memory = try device.allocateMemory(allocator, &.{
        .allocation_size = requirements.size,
        .memory_type_index = requirements.memory_type_bits,
    });
    errdefer memory.destroy(allocator);

    try image.bindMemory(memory, 0);

    return .{
        .image = image,
        .memory = memory,
        .state = .Available,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.image.destroy(allocator);
    self.memory.destroy(allocator);
}
