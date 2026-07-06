const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("lib.zig");
const proto = lib.proto;

const PhiDevice = @import("PhiDevice.zig");
const PhiTransport = @import("PhiTransport.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.DeviceMemory;

interface: Interface,
remote_handle: u64,
data: ?[]u8,

pub fn create(device: *PhiDevice, allocator: std.mem.Allocator, size: vk.DeviceSize, memory_type_index: u32) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(&device.interface, size, memory_type_index);

    interface.vtable = &.{
        .destroy = destroy,
        .map = map,
        .unmap = unmap,
        .flushRange = flushRange,
        .invalidateRange = invalidateRange,
    };

    if (memory_type_index >= device.interface.physical_device.mem_props.memory_type_count) {
        return VkError.ValidationFailed;
    }

    const memory_type = device.interface.physical_device.mem_props.memory_types[memory_type_index];
    const host_visible = memory_type.property_flags.host_visible_bit;
    const device_local = memory_type.property_flags.device_local_bit;
    const allocation_size = std.math.cast(usize, size) orelse return VkError.OutOfDeviceMemory;

    const remote_handle = if (device_local) blk: {
        const alloc_request: proto.PhiAllocMemoryRequest = .{
            .size = size,
            .memory_type_index = memory_type_index,
            .flags = 0,
        };

        var reply: proto.PhiAllocMemoryReply = undefined;
        try device.transport.request(proto.PHI_COMMAND_ALLOC_MEMORY, std.mem.asBytes(&alloc_request), std.mem.asBytes(&reply));

        if (reply.result.status != proto.PHI_STATUS_OK) {
            return PhiTransport.statusToErr(reply.result.status);
        }

        std.log.scoped(.PhiDeviceMemory).info("Recieved remote handle 0x{X}", .{reply.remote_handle});

        break :blk reply.remote_handle;
    } else 0;
    errdefer if (remote_handle != 0) self.interface.destroy(allocator);

    const data = if (host_visible)
        device.interface.device_allocator.allocator().alloc(u8, allocation_size) catch return VkError.OutOfDeviceMemory
    else
        null;

    self.* = .{
        .interface = interface,
        .remote_handle = remote_handle,
        .data = data,
    };

    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device: *PhiDevice = @alignCast(@fieldParentPtr("interface", interface.owner));
    if (self.data) |data| {
        interface.owner.device_allocator.allocator().free(data);
    }
    if (self.remote_handle != 0) {
        const request_payload: proto.PhiFreeMemoryRequest = .{
            .remote_handle = self.remote_handle,
        };
        var reply: proto.PhiFreeMemoryReply = undefined;
        device.transport.request(proto.PHI_COMMAND_FREE_MEMORY, std.mem.asBytes(&request_payload), std.mem.asBytes(&reply)) catch |err| {
            std.log.scoped(.PhiTransport).err("Remote free failed: {s}", .{@errorName(err)});
            return;
        };
        if (reply.result.status != proto.PHI_STATUS_OK) {
            std.log.scoped(.PhiTransport).err("Remote free returned status {d}", .{reply.result.status});
        }
    }
    allocator.destroy(self);
}

pub fn flushRange(interface: *Interface, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!void {
    _ = interface;
    _ = offset;
    _ = size;
}

pub fn invalidateRange(interface: *Interface, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!void {
    _ = interface;
    _ = offset;
    _ = size;
}

pub fn map(interface: *Interface, offset: vk.DeviceSize, size: vk.DeviceSize) VkError![]u8 {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const data = self.data orelse return VkError.MemoryMapFailed;
    const map_offset = std.math.cast(usize, offset) orelse return VkError.MemoryMapFailed;
    if (map_offset >= data.len) {
        return VkError.MemoryMapFailed;
    }
    const map_size = if (size == vk.WHOLE_SIZE)
        data.len - map_offset
    else
        std.math.cast(usize, size) orelse return VkError.MemoryMapFailed;
    if (map_size > data.len - map_offset) {
        return VkError.MemoryMapFailed;
    }
    return data[map_offset..(map_offset + map_size)];
}

pub fn unmap(_: *Interface) void {}
