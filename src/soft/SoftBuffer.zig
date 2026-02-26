const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const lib = @import("lib.zig");

const VkError = base.VkError;
const Device = base.Device;

const Self = @This();
pub const Interface = base.Buffer;

interface: Interface,

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.BufferCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);

    interface.vtable = &.{
        .destroy = destroy,
        .getMemoryRequirements = getMemoryRequirements,
    };

    self.* = .{
        .interface = interface,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn getMemoryRequirements(interface: *Interface, requirements: *vk.MemoryRequirements) void {
    requirements.alignment = lib.MEMORY_REQUIREMENTS_BUFFER_ALIGNMENT;
    if (interface.usage.uniform_texel_buffer_bit or interface.usage.uniform_texel_buffer_bit) {
        requirements.alignment = @max(requirements.alignment, lib.MIN_TEXEL_BUFFER_ALIGNMENT);
    }
    if (interface.usage.storage_buffer_bit) {
        requirements.alignment = @max(requirements.alignment, lib.MIN_STORAGE_BUFFER_ALIGNMENT);
    }
    if (interface.usage.uniform_buffer_bit) {
        requirements.alignment = @max(requirements.alignment, lib.MIN_UNIFORM_BUFFER_ALIGNMENT);
    }
}

pub fn copyBuffer(self: *const Self, dst: *Self, regions: []const vk.BufferCopy) VkError!void {
    for (regions) |region| {
        const src_memory = if (self.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
        const dst_memory = if (dst.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;

        const src_map: []u8 = @as([*]u8, @ptrCast(try src_memory.map(self.interface.offset + region.src_offset, region.size)))[0..region.size];
        const dst_map: []u8 = @as([*]u8, @ptrCast(try dst_memory.map(dst.interface.offset + region.dst_offset, region.size)))[0..region.size];

        @memcpy(dst_map, src_map);

        src_memory.unmap();
        dst_memory.unmap();
    }
}

pub fn fillBuffer(self: *Self, offset: vk.DeviceSize, size: vk.DeviceSize, data: u32) VkError!void {
    const memory = if (self.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    var memory_map: []u32 = @as([*]u32, @ptrCast(@alignCast(try memory.map(offset, size))))[0..size];

    var bytes = if (size == vk.WHOLE_SIZE) memory.size - offset else size;

    var i: usize = 0;
    while (bytes >= 4) : ({
        bytes -= 4;
        i += 1;
    }) {
        memory_map[i] = data;
    }

    memory.unmap();
}
