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
scif_offset: ?u64,

/// Size of the region registered with SCIF.
/// This is allocation size rounded up to page size.
registered_size: usize,

/// Bytes exposed through vkMapMemory.
/// For HOST_VISIBLE memory this is a slice of host_backing.
data: ?[]u8,

/// Full page-aligned/page-rounded allocation registered with SCIF.
host_backing: ?[]u8,

pub fn create(device: *PhiDevice, allocator: std.mem.Allocator, size: vk.DeviceSize, memory_type_index: u32) VkError!*Self {
    if (memory_type_index >= device.interface.physical_device.mem_props.memory_type_count) {
        return VkError.ValidationFailed;
    }

    const allocation_size =
        std.math.cast(usize, size) orelse return VkError.OutOfDeviceMemory;

    const memory_type =
        device.interface.physical_device.mem_props.memory_types[memory_type_index];

    const host_visible = memory_type.property_flags.host_visible_bit;

    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(
        &device.interface,
        size,
        memory_type_index,
    );

    interface.vtable = &.{
        .destroy = destroy,
        .map = map,
        .unmap = unmap,
        .flushRange = flushRange,
        .invalidateRange = invalidateRange,
    };

    if (host_visible) {
        const page_size = std.heap.pageSize();
        const registered_size = std.mem.alignForward(usize, allocation_size, page_size);

        // This needs to be page aligned
        const backing = device.interface.device_allocator.allocator().alignedAlloc(u8, .fromByteUnits(std.heap.page_size_max), registered_size) catch return VkError.OutOfHostMemory;
        errdefer device.interface.device_allocator.allocator().free(backing);

        const offset = device.transport.registerHostMemory(backing) catch return VkError.OutOfHostMemory;
        errdefer device.transport.unregisterHostMemory(offset, backing.len) catch {};

        const request: proto.PhiMapHostMemoryRequest = .{
            .scif_offset = offset,
            .scif_size = backing.len,
            .size = allocation_size,
        };

        var reply = std.mem.zeroes(proto.PhiNewMemoryReply);

        try device.transport.request(
            proto.PHI_PACKET_MAP_HOST_MEMORY,
            std.mem.asBytes(&request),
            std.mem.asBytes(&reply),
        );

        if (reply.result.status != proto.PHI_STATUS_OK) {
            return PhiTransport.statusToErr(reply.result.status);
        }

        self.* = .{
            .interface = interface,
            .remote_handle = reply.remote_handle,
            .scif_offset = offset,
            .registered_size = registered_size,
            .data = backing[0..allocation_size],
            .host_backing = backing,
        };
    } else {
        const request: proto.PhiAllocMemoryRequest = .{
            .size = size,
            .memory_type_index = memory_type_index,
            .flags = 0,
        };

        var reply = std.mem.zeroes(proto.PhiNewMemoryReply);

        try device.transport.request(
            proto.PHI_PACKET_ALLOC_MEMORY,
            std.mem.asBytes(&request),
            std.mem.asBytes(&reply),
        );

        if (reply.result.status != proto.PHI_STATUS_OK) {
            return PhiTransport.statusToErr(reply.result.status);
        }

        self.* = .{
            .interface = interface,
            .remote_handle = reply.remote_handle,
            .scif_offset = null,
            .registered_size = 0,
            .data = null,
            .host_backing = null,
        };
    }

    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self =
        @alignCast(@fieldParentPtr("interface", interface));

    const device: *PhiDevice =
        @alignCast(@fieldParentPtr("interface", interface.owner));

    if (self.remote_handle != 0) {
        const request_payload: proto.PhiDestroyMemoryRequest = .{
            .remote_handle = self.remote_handle,
        };

        var reply = std.mem.zeroes(proto.PhiResultReply);

        device.transport.request(proto.PHI_PACKET_DESTROY_MEMORY, std.mem.asBytes(&request_payload), std.mem.asBytes(&reply)) catch |err| {
            std.log.scoped(.PhiDeviceMemory).err("Remote free/unmap failed for handle 0x{X}: {s}", .{ self.remote_handle, @errorName(err) });
            return;
        };

        if (reply.result.status != proto.PHI_STATUS_OK) {
            std.log.scoped(.PhiDeviceMemory).err("Remote free/unmap for handle 0x{X} returned status {d}", .{ self.remote_handle, reply.result.status });
        }
    }

    if (self.scif_offset) |scif_offset| {
        device.transport.unregisterHostMemory(scif_offset, self.interface.size) catch |err| {
            std.log.scoped(.PhiDeviceMemory).err("SCIF unregister failed: {s}", .{@errorName(err)});
        };
    }

    if (self.host_backing) |host_backing| {
        interface.owner.device_allocator.allocator().free(host_backing);
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

    return data[map_offset .. map_offset + map_size];
}

pub fn unmap(_: *Interface) void {}
