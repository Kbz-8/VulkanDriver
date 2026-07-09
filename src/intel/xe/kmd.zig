const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;

pub const Device = struct {
    card: base.drm.Card,

    pub fn open(io: std.Io, node_path: []const u8) VkError!Device {
        return .{
            .card = base.drm.Card.open(io, node_path) catch return VkError.InitializationFailed,
        };
    }

    pub fn close(self: *Device, io: std.Io) void {
        self.card.close(io);
    }

    pub fn allocateMemory(_: *Device, _: std.Io, _: vk.DeviceSize) VkError!Memory {
        return VkError.OutOfDeviceMemory;
    }

    pub fn submitBatch(_: *Device, _: std.Io, _: std.mem.Allocator, _: []const u32, _: []const @import("../kmd.zig").Relocation) VkError!void {
        return VkError.FeatureNotPresent;
    }
};

pub const Memory = struct {
    pub fn deinit(_: *Memory, _: *Device, _: std.Io) void {}

    pub fn map(_: *Memory, _: *Device, _: std.Io, _: vk.DeviceSize, _: vk.DeviceSize) VkError![]u8 {
        return VkError.MemoryMapFailed;
    }

    pub fn unmap(_: *Memory) void {}

    pub fn flushRange(_: *Memory, _: *Device, _: std.Io, _: vk.DeviceSize, _: vk.DeviceSize) VkError!void {
        return VkError.FeatureNotPresent;
    }

    pub fn invalidateRange(_: *Memory, _: *Device, _: std.Io, _: vk.DeviceSize, _: vk.DeviceSize) VkError!void {
        return VkError.FeatureNotPresent;
    }
};

test {
    std.testing.refAllDecls(@This());
}
