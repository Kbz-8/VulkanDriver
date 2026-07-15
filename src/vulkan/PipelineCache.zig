const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;
const root = @import("lib.zig");

const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .pipeline_cache;

owner: *Device,
data: []u8,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub const Header = vk.PipelineCacheHeaderVersionOne;

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.PipelineCacheCreateInfo) VkError!Self {
    _ = allocator;
    if (info.initial_data_size != 0 and info.p_initial_data == null) {
        return VkError.ValidationFailed;
    }

    const initial_data = if (info.p_initial_data) |ptr|
        @as([*]const u8, @ptrCast(ptr))[0..info.initial_data_size]
    else
        &.{};

    const data_allocator = device.host_allocator.allocator();
    const data = if (isCompatibleInitialData(device, initial_data))
        data_allocator.dupe(u8, initial_data) catch return VkError.OutOfHostMemory
    else
        createEmptyData(device, data_allocator) catch return VkError.OutOfHostMemory;

    return .{
        .owner = device,
        .data = data,
        // SAFETY: the backend assigns the vtable before returning the pipeline cache.
        .vtable = undefined,
    };
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.owner.host_allocator.allocator().free(self.data);
    self.vtable.destroy(self, allocator);
}

pub fn merge(self: *Self, source: *const Self) VkError!void {
    if (source.data.len <= @sizeOf(Header)) {
        return;
    }
    if (!isCompatibleInitialData(self.owner, source.data)) {
        return;
    }

    const old_len = self.data.len;
    const source_payload = source.data[@sizeOf(Header)..];
    self.data = self.owner.host_allocator.allocator().realloc(self.data, old_len + source_payload.len) catch return VkError.OutOfHostMemory;
    @memcpy(self.data[old_len..], source_payload);
}

pub fn appendPayload(self: *Self, payload: []const u8) VkError!void {
    if (payload.len == 0) {
        return;
    }

    const old_len = self.data.len;
    self.data = self.owner.host_allocator.allocator().realloc(self.data, old_len + payload.len) catch return VkError.OutOfHostMemory;
    @memcpy(self.data[old_len..], payload);
}

pub fn getData(self: *Self, data: ?[]u8) vk.Result {
    if (data) |dst| {
        const written = @min(dst.len, self.data.len);
        @memcpy(dst[0..written], self.data[0..written]);
        if (written < self.data.len) {
            return .incomplete;
        }
    }

    return .success;
}

pub inline fn availableDataSize(self: *const Self) usize {
    return self.data.len;
}

fn makeHeader(device: *const Device) Header {
    return .{
        .header_size = @sizeOf(Header),
        .header_version = .one,
        .vendor_id = @intCast(root.VULKAN_VENDOR_ID),
        .device_id = device.physical_device.props.device_id,
        .pipeline_cache_uuid = device.physical_device.props.pipeline_cache_uuid,
    };
}

fn createEmptyData(device: *const Device, allocator: std.mem.Allocator) VkError![]u8 {
    const cache_header = makeHeader(device);
    return allocator.dupe(u8, std.mem.asBytes(&cache_header)) catch VkError.OutOfHostMemory;
}

fn isCompatibleInitialData(device: *const Device, initial_data: []const u8) bool {
    if (initial_data.len == 0) {
        return false;
    }
    if (initial_data.len < @sizeOf(Header)) {
        return false;
    }

    const cache_header = readHeader(initial_data);
    const expected = makeHeader(device);
    return cache_header.header_size == @sizeOf(Header) and
        cache_header.header_version == .one and
        cache_header.vendor_id == expected.vendor_id and
        cache_header.device_id == expected.device_id and
        std.mem.eql(u8, &cache_header.pipeline_cache_uuid, &expected.pipeline_cache_uuid);
}

inline fn readHeader(bytes: []const u8) Header {
    return std.mem.bytesToValue(Header, bytes);
}
