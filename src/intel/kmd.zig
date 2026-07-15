const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const KmdType = @import("lib.zig").KmdType;

const FlintPhysicalDevice = @import("FlintPhysicalDevice.zig");
const i915_kmd = @import("i915/kmd.zig");
const xe = @import("xe/kmd.zig");

const VkError = base.VkError;
const IOCTL = std.os.linux.IOCTL;

pub const xy_src_copy_blt: u32 = (2 << 29) | (0x53 << 22) | 8;
pub const xy_blt_write_alpha: u32 = 1 << 21;
pub const xy_blt_write_rgb: u32 = 1 << 20;
pub const mi_store_data_imm_dword: u32 = (0x20 << 23) | 2;
pub const blt_depth_8: u32 = 0 << 24;
pub const rop_source_copy: u32 = 0xcc << 16;
pub const max_blt_span: vk.DeviceSize = 32 * 1024 - 1;

pub const Relocation = struct {
    target_handle: u32,
    offset: u64,
    delta: u32,
    read: bool = false,
    write: bool = false,
};

pub const SyncDependency = struct {
    handle: u32,
    wait: bool = false,
    signal: bool = false,
};

pub const Device = union(KmdType) {
    invalid: void,
    i915: i915_kmd.Device,
    xe: xe.Device,

    pub fn open(io: std.Io, physical_device: *const FlintPhysicalDevice) VkError!Device {
        return switch (physical_device.kmd_type) {
            .i915 => .{ .i915 = try i915_kmd.Device.open(io, physical_device.getNodePath()) },
            .xe => .{ .xe = try xe.Device.open(io, physical_device.getNodePath()) },
            .invalid => VkError.InitializationFailed,
        };
    }

    pub fn close(self: *Device, io: std.Io) void {
        switch (self.*) {
            .i915 => |*device| device.close(io),
            .xe => |*device| device.close(io),
            .invalid => {},
        }
        self.* = .{ .invalid = {} };
    }

    pub fn allocateMemory(self: *Device, io: std.Io, size: vk.DeviceSize) VkError!Memory {
        return switch (self.*) {
            .i915 => |*device| .{ .i915 = try device.allocateMemory(io, size) },
            .xe => |*device| .{ .xe = try device.allocateMemory(io, size) },
            .invalid => VkError.OutOfDeviceMemory,
        };
    }

    pub fn submitBatch(self: *Device, io: std.Io, allocator: std.mem.Allocator, commands: []const u32, relocations: []const Relocation, syncs: []const SyncDependency) VkError!void {
        return switch (self.*) {
            .i915 => |*device| device.submitBatch(io, allocator, commands, relocations, syncs),
            .xe => |*device| device.submitBatch(io, allocator, commands, relocations, syncs),
            .invalid => VkError.DeviceLost,
        };
    }

    pub fn file(self: *Device) VkError!std.Io.File {
        return switch (self.*) {
            .i915 => |*device| device.card.handle,
            .xe => |*device| device.card.handle,
            .invalid => VkError.DeviceLost,
        };
    }
};

pub const Memory = union(KmdType) {
    invalid: void,
    i915: i915_kmd.Memory,
    xe: xe.Memory,

    pub fn deinit(self: *Memory, device: *Device, io: std.Io) void {
        switch (self.*) {
            .i915 => |*memory| switch (device.*) {
                .i915 => |*adapter| memory.deinit(adapter, io),
                else => {},
            },
            .xe => |*memory| switch (device.*) {
                .xe => |*adapter| memory.deinit(adapter, io),
                else => {},
            },
            .invalid => {},
        }
        self.* = .{ .invalid = {} };
    }

    pub fn map(self: *Memory, device: *Device, io: std.Io, offset: vk.DeviceSize, size: vk.DeviceSize) VkError![]u8 {
        return switch (self.*) {
            .i915 => |*memory| switch (device.*) {
                .i915 => |*adapter| memory.map(adapter, io, offset, size),
                else => VkError.MemoryMapFailed,
            },
            .xe => |*memory| switch (device.*) {
                .xe => |*adapter| memory.map(adapter, io, offset, size),
                else => VkError.MemoryMapFailed,
            },
            .invalid => VkError.MemoryMapFailed,
        };
    }

    pub fn unmap(self: *Memory) void {
        switch (self.*) {
            .i915 => |*memory| memory.unmap(),
            .xe => |*memory| memory.unmap(),
            .invalid => {},
        }
    }

    pub fn flushRange(self: *Memory, device: *Device, io: std.Io, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!void {
        return switch (self.*) {
            .i915 => |*memory| switch (device.*) {
                .i915 => |*adapter| memory.flushRange(adapter, io, offset, size),
                else => VkError.InvalidDeviceMemoryDrv,
            },
            .xe => |*memory| switch (device.*) {
                .xe => |*adapter| memory.flushRange(adapter, io, offset, size),
                else => VkError.InvalidDeviceMemoryDrv,
            },
            .invalid => VkError.InvalidDeviceMemoryDrv,
        };
    }

    pub fn invalidateRange(self: *Memory, device: *Device, io: std.Io, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!void {
        return switch (self.*) {
            .i915 => |*memory| switch (device.*) {
                .i915 => |*adapter| memory.invalidateRange(adapter, io, offset, size),
                else => VkError.InvalidDeviceMemoryDrv,
            },
            .xe => |*memory| switch (device.*) {
                .xe => |*adapter| memory.invalidateRange(adapter, io, offset, size),
                else => VkError.InvalidDeviceMemoryDrv,
            },
            .invalid => VkError.InvalidDeviceMemoryDrv,
        };
    }

    pub fn handle(self: *const Memory) VkError!u32 {
        return switch (self.*) {
            .i915 => |*memory| memory.handle,
            .xe => VkError.FeatureNotPresent,
            .invalid => VkError.InvalidDeviceMemoryDrv,
        };
    }
};

pub inline fn drmIoctlIow(nr: u8, comptime T: type) u32 {
    return IOCTL.IOW('d', nr, T);
}

pub inline fn drmIoctlIowr(nr: u8, comptime T: type) u32 {
    return IOCTL.IOWR('d', nr, T);
}
