const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("lib.zig");

const FlintPhysicalDevice = @import("FlintPhysicalDevice.zig");
const i915_kmd = @import("i915/kmd.zig");
const xe = @import("xe/kmd.zig");

const VkError = base.VkError;

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

pub const Device = union(lib.KmdType) {
    Invalid: void,
    I915: i915_kmd.Device,
    Xe: xe.Device,

    pub fn open(io: std.Io, physical_device: *const FlintPhysicalDevice) VkError!Device {
        return switch (physical_device.kmd_type) {
            .I915 => .{ .I915 = try i915_kmd.Device.open(io, physical_device.getNodePath()) },
            .Xe => .{ .Xe = try xe.Device.open(io, physical_device.getNodePath()) },
            .Invalid => VkError.InitializationFailed,
        };
    }

    pub fn close(self: *Device, io: std.Io) void {
        switch (self.*) {
            .I915 => |*device| device.close(io),
            .Xe => |*device| device.close(io),
            .Invalid => {},
        }
        self.* = .{ .Invalid = {} };
    }

    pub fn allocateMemory(self: *Device, io: std.Io, size: vk.DeviceSize) VkError!Memory {
        return switch (self.*) {
            .I915 => |*device| .{ .I915 = try device.allocateMemory(io, size) },
            .Xe => |*device| .{ .Xe = try device.allocateMemory(io, size) },
            .Invalid => VkError.OutOfDeviceMemory,
        };
    }

    pub fn submitBatch(self: *Device, io: std.Io, allocator: std.mem.Allocator, commands: []const u32, relocations: []const Relocation) VkError!void {
        return switch (self.*) {
            .I915 => |*device| device.submitBatch(io, allocator, commands, relocations),
            .Xe => |*device| device.submitBatch(io, allocator, commands, relocations),
            .Invalid => VkError.DeviceLost,
        };
    }
};

pub const Memory = union(lib.KmdType) {
    Invalid: void,
    I915: i915_kmd.Memory,
    Xe: xe.Memory,

    pub fn deinit(self: *Memory, device: *Device, io: std.Io) void {
        switch (self.*) {
            .I915 => |*memory| switch (device.*) {
                .I915 => |*adapter| memory.deinit(adapter, io),
                else => {},
            },
            .Xe => |*memory| switch (device.*) {
                .Xe => |*adapter| memory.deinit(adapter, io),
                else => {},
            },
            .Invalid => {},
        }
        self.* = .{ .Invalid = {} };
    }

    pub fn map(self: *Memory, device: *Device, io: std.Io, offset: vk.DeviceSize, size: vk.DeviceSize) VkError![]u8 {
        return switch (self.*) {
            .I915 => |*memory| switch (device.*) {
                .I915 => |*adapter| memory.map(adapter, io, offset, size),
                else => VkError.MemoryMapFailed,
            },
            .Xe => |*memory| switch (device.*) {
                .Xe => |*adapter| memory.map(adapter, io, offset, size),
                else => VkError.MemoryMapFailed,
            },
            .Invalid => VkError.MemoryMapFailed,
        };
    }

    pub fn unmap(self: *Memory) void {
        switch (self.*) {
            .I915 => |*memory| memory.unmap(),
            .Xe => |*memory| memory.unmap(),
            .Invalid => {},
        }
    }

    pub fn flushRange(self: *Memory, device: *Device, io: std.Io, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!void {
        return switch (self.*) {
            .I915 => |*memory| switch (device.*) {
                .I915 => |*adapter| memory.flushRange(adapter, io, offset, size),
                else => VkError.InvalidDeviceMemoryDrv,
            },
            .Xe => |*memory| switch (device.*) {
                .Xe => |*adapter| memory.flushRange(adapter, io, offset, size),
                else => VkError.InvalidDeviceMemoryDrv,
            },
            .Invalid => VkError.InvalidDeviceMemoryDrv,
        };
    }

    pub fn invalidateRange(self: *Memory, device: *Device, io: std.Io, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!void {
        return switch (self.*) {
            .I915 => |*memory| switch (device.*) {
                .I915 => |*adapter| memory.invalidateRange(adapter, io, offset, size),
                else => VkError.InvalidDeviceMemoryDrv,
            },
            .Xe => |*memory| switch (device.*) {
                .Xe => |*adapter| memory.invalidateRange(adapter, io, offset, size),
                else => VkError.InvalidDeviceMemoryDrv,
            },
            .Invalid => VkError.InvalidDeviceMemoryDrv,
        };
    }

    pub fn handle(self: *const Memory) VkError!u32 {
        return switch (self.*) {
            .I915 => |*memory| memory.handle,
            .Xe => VkError.FeatureNotPresent,
            .Invalid => VkError.InvalidDeviceMemoryDrv,
        };
    }
};
