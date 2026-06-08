const std = @import("std");
const vk = @import("vulkan");

const NonDispatchable = @import("NonDispatchable.zig");

const VkError = @import("error_set.zig").VkError;
const root = @import("lib.zig");

const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .pipeline_cache;

owner: *Device,
data_available: bool,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub const Header = vk.PipelineCacheHeaderVersionOne;

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.PipelineCacheCreateInfo) VkError!Self {
    _ = allocator;
    const has_initial_data = info.initial_data_size != 0 or info.p_initial_data != null;
    return .{
        .owner = device,
        .data_available = !has_initial_data or info.initial_data_size >= dataSize(),
        .vtable = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}

pub fn merge(self: *Self) VkError!void {
    _ = self;
}

pub fn getData(self: *Self, data: ?[]u8) vk.Result {
    if (!self.data_available) {
        return .success;
    }

    const cache_header = self.header();
    const bytes = std.mem.asBytes(&cache_header);

    if (data) |dst| {
        if (dst.len < bytes.len) {
            return .incomplete;
        }

        @memcpy(dst[0..bytes.len], bytes);
    }

    return .success;
}

pub inline fn dataSize() usize {
    return @sizeOf(Header);
}

pub inline fn availableDataSize(self: *const Self) usize {
    return if (self.data_available) dataSize() else 0;
}

fn header(self: *const Self) Header {
    return .{
        .header_size = @sizeOf(Header),
        .header_version = .one,
        .vendor_id = @intCast(root.VULKAN_VENDOR_ID),
        .device_id = self.owner.physical_device.props.device_id,
        .pipeline_cache_uuid = self.owner.physical_device.props.pipeline_cache_uuid,
    };
}
