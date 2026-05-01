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
        const src_map = try self.mapAsSliceWithAddedOffset(u8, region.src_offset, region.size);
        const dst_map = try dst.mapAsSliceWithAddedOffset(u8, region.dst_offset, region.size);

        @memcpy(dst_map, src_map);
    }
}

pub fn fillBuffer(self: *Self, offset: vk.DeviceSize, size: vk.DeviceSize, data: u32) VkError!void {
    const memory = if (self.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    var bytes = if (size == vk.WHOLE_SIZE) memory.size - offset else size;

    const map = try self.mapAsSliceWithOffset(u32, offset, bytes);

    var i: usize = 0;
    while (bytes >= 4) : ({
        bytes -= 4;
        i += 1;
    }) {
        map[i] = data;
    }
}

pub inline fn mapAs(self: *const Self, comptime T: type) VkError!*T {
    return self.mapAsWithAddedOffset(T, 0);
}

pub inline fn mapTo(self: *const Self, comptime T: type) VkError!T {
    return self.mapToWithAddedOffset(T, 0);
}

pub inline fn mapAsSlice(self: *const Self, comptime T: type, size: usize) VkError![]T {
    return self.mapAsSliceWithAddedOffset(T, 0, size);
}

pub inline fn mapAsWithAddedOffset(self: *const Self, comptime T: type, offset: usize) VkError!*T {
    return self.mapAsWithOffset(T, self.interface.offset + offset);
}

pub inline fn mapToWithAddedOffset(self: *const Self, comptime T: type, offset: usize) VkError!T {
    return self.mapToWithOffset(T, self.interface.offset + offset);
}

pub inline fn mapAsSliceWithAddedOffset(self: *const Self, comptime T: type, size: usize, offset: usize) VkError![]T {
    return self.mapAsSliceWithOffset(T, self.interface.offset + offset, size);
}

pub fn mapAsWithOffset(self: *const Self, comptime T: type, offset: usize) VkError!*T {
    const memory = if (self.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    const map = @as([*]u8, @ptrCast(@alignCast(try memory.map(offset, @sizeOf(T)))))[0..@sizeOf(T)];
    return @alignCast(std.mem.bytesAsValue(T, map));
}

pub fn mapToWithOffset(self: *const Self, comptime T: type, offset: usize) VkError!T {
    const memory = if (self.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    const map = @as([*]u8, @ptrCast(@alignCast(try memory.map(offset, @sizeOf(T)))))[0..@sizeOf(T)];
    return std.mem.bytesToValue(T, map);
}

pub fn mapAsSliceWithOffset(self: *const Self, comptime T: type, offset: usize, size: usize) VkError![]T {
    const memory = if (self.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    const map = @as([*]u8, @ptrCast(@alignCast(try memory.map(offset, size))))[0..size];
    return @alignCast(std.mem.bytesAsSlice(T, map));
}
