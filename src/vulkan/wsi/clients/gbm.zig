//! Minimal dynamically loaded GBM client used to allocate DMA-BUFs.

const std = @import("std");
const lib = @import("../../lib.zig");

const VkError = lib.VkError;

pub const drm_format_argb8888 = fourccCode('A', 'R', '2', '4');
pub const drm_format_modifier_linear: u64 = 0;
pub const drm_format_modifier_invalid: u64 = 0x00ff_ffff_ffff_ffff;

const bo_use_rendering: u32 = 1 << 2;
const bo_use_linear: u32 = 1 << 4;
const bo_transfer_write: u32 = 1 << 1;

pub const gbm_device = opaque {};
pub const gbm_bo = opaque {};

// SAFETY: load assigns every function pointer before any public GBM wrapper is used.
var gbm_create_device: *const fn (fd: c_int) callconv(.c) ?*gbm_device = undefined;
// SAFETY: load assigns every function pointer before any public GBM wrapper is used.
var gbm_device_destroy: *const fn (device: *gbm_device) callconv(.c) void = undefined;
// SAFETY: load assigns every function pointer before any public GBM wrapper is used.
var gbm_device_is_format_supported: *const fn (device: *gbm_device, format: u32, usage: u32) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any public GBM wrapper is used.
var gbm_bo_create: *const fn (device: *gbm_device, width: u32, height: u32, format: u32, usage: u32) callconv(.c) ?*gbm_bo = undefined;
// SAFETY: load assigns every function pointer before any public GBM wrapper is used.
var gbm_bo_destroy: *const fn (bo: *gbm_bo) callconv(.c) void = undefined;
// SAFETY: load assigns every function pointer before any public GBM wrapper is used.
var gbm_bo_get_fd: *const fn (bo: *gbm_bo) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any public GBM wrapper is used.
var gbm_bo_get_modifier: *const fn (bo: *gbm_bo) callconv(.c) u64 = undefined;
// SAFETY: load assigns every function pointer before any public GBM wrapper is used.
var gbm_bo_get_plane_count: *const fn (bo: *gbm_bo) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any public GBM wrapper is used.
var gbm_bo_get_stride: *const fn (bo: *gbm_bo) callconv(.c) u32 = undefined;
// SAFETY: load assigns every function pointer before any public GBM wrapper is used.
var gbm_bo_map: *const fn (bo: *gbm_bo, x: u32, y: u32, width: u32, height: u32, flags: u32, stride: *u32, map_data: *?*anyopaque) callconv(.c) ?*anyopaque = undefined;
// SAFETY: load assigns every function pointer before any public GBM wrapper is used.
var gbm_bo_unmap: *const fn (bo: *gbm_bo, map_data: ?*anyopaque) callconv(.c) void = undefined;

// SAFETY: load initializes the module before it can be closed or queried.
var module: std.DynLib = undefined;
var ref_count = std.atomic.Value(usize).init(0);
var load_mutex: lib.SpinMutex = .{};

pub fn load() VkError!void {
    load_mutex.lock();
    defer load_mutex.unlock();

    if (ref_count.load(.monotonic) != 0) {
        _ = ref_count.fetchAdd(1, .monotonic);
        return;
    }

    module = std.DynLib.open("libgbm.so.1") catch {
        std.log.scoped(.GBM).err("Could not open 'libgbm.so.1'", .{});
        return VkError.InitializationFailed;
    };
    errdefer module.close();

    gbm_create_device = module.lookup(@TypeOf(gbm_create_device), "gbm_create_device") orelse return VkError.InitializationFailed;
    gbm_device_destroy = module.lookup(@TypeOf(gbm_device_destroy), "gbm_device_destroy") orelse return VkError.InitializationFailed;
    gbm_device_is_format_supported = module.lookup(@TypeOf(gbm_device_is_format_supported), "gbm_device_is_format_supported") orelse return VkError.InitializationFailed;
    gbm_bo_create = module.lookup(@TypeOf(gbm_bo_create), "gbm_bo_create") orelse return VkError.InitializationFailed;
    gbm_bo_destroy = module.lookup(@TypeOf(gbm_bo_destroy), "gbm_bo_destroy") orelse return VkError.InitializationFailed;
    gbm_bo_get_fd = module.lookup(@TypeOf(gbm_bo_get_fd), "gbm_bo_get_fd") orelse return VkError.InitializationFailed;
    gbm_bo_get_modifier = module.lookup(@TypeOf(gbm_bo_get_modifier), "gbm_bo_get_modifier") orelse return VkError.InitializationFailed;
    gbm_bo_get_plane_count = module.lookup(@TypeOf(gbm_bo_get_plane_count), "gbm_bo_get_plane_count") orelse return VkError.InitializationFailed;
    gbm_bo_get_stride = module.lookup(@TypeOf(gbm_bo_get_stride), "gbm_bo_get_stride") orelse return VkError.InitializationFailed;
    gbm_bo_map = module.lookup(@TypeOf(gbm_bo_map), "gbm_bo_map") orelse return VkError.InitializationFailed;
    gbm_bo_unmap = module.lookup(@TypeOf(gbm_bo_unmap), "gbm_bo_unmap") orelse return VkError.InitializationFailed;

    _ = ref_count.fetchAdd(1, .monotonic);
    std.log.scoped(.GBM).debug("Loaded GBM", .{});
}

pub fn unload() void {
    load_mutex.lock();
    defer load_mutex.unlock();

    if (ref_count.fetchSub(1, .release) == 1) {
        module.close();
        std.log.scoped(.GBM).debug("Unloaded GBM", .{});
    }
}

pub const Device = struct {
    handle: *gbm_device,
    fd: std.posix.fd_t,

    pub fn open() VkError!Device {
        var path_buffer: [64]u8 = undefined;

        for (128..192) |node| {
            const path = std.fmt.bufPrint(&path_buffer, "/dev/dri/renderD{d}", .{node}) catch return VkError.Unknown;
            if (tryOpen(path)) |device|
                return device;
        }

        for (0..16) |node| {
            const path = std.fmt.bufPrint(&path_buffer, "/dev/dri/card{d}", .{node}) catch return VkError.Unknown;
            if (tryOpen(path)) |device|
                return device;
        }

        std.log.scoped(.GBM).err("Could not find a DRM device capable of allocating linear ARGB8888 buffers", .{});
        return VkError.InitializationFailed;
    }

    fn tryOpen(path: []const u8) ?Device {
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch return null;

        const handle = gbm_create_device(fd) orelse {
            _ = std.c.close(fd);
            return null;
        };

        if (gbm_device_is_format_supported(handle, drm_format_argb8888, bo_use_linear | bo_use_rendering) == 0) {
            gbm_device_destroy(handle);
            _ = std.c.close(fd);
            return null;
        }

        return .{ .handle = handle, .fd = fd };
    }

    pub fn deinit(self: *Device) void {
        gbm_device_destroy(self.handle);
        _ = std.c.close(self.fd);
        self.* = undefined;
    }

    pub fn createBuffer(self: *Device, width: u32, height: u32) VkError!Buffer {
        const handle = gbm_bo_create(self.handle, width, height, drm_format_argb8888, bo_use_linear | bo_use_rendering) orelse return VkError.OutOfDeviceMemory;
        errdefer gbm_bo_destroy(handle);

        if (gbm_bo_get_plane_count(handle) != 1)
            return VkError.FormatNotSupported;

        const stride = gbm_bo_get_stride(handle);
        const minimum_stride = std.math.mul(u32, width, 4) catch return VkError.OutOfDeviceMemory;
        if (stride < minimum_stride)
            return VkError.Unknown;

        return .{
            .handle = handle,
            .width = width,
            .height = height,
            .stride = stride,
            .modifier = gbm_bo_get_modifier(handle),
        };
    }
};

pub const Buffer = struct {
    handle: *gbm_bo,
    width: u32,
    height: u32,
    stride: u32,
    modifier: u64,

    pub fn deinit(self: *Buffer) void {
        gbm_bo_destroy(self.handle);
        self.* = undefined;
    }

    pub fn exportFd(self: *const Buffer) VkError!std.posix.fd_t {
        const fd = gbm_bo_get_fd(self.handle);
        if (fd < 0)
            return VkError.Unknown;
        return fd;
    }

    pub fn mapWrite(self: *Buffer) VkError!Mapping {
        var stride: u32 = 0;
        var map_data: ?*anyopaque = null;
        const pointer = gbm_bo_map(self.handle, 0, 0, self.width, self.height, bo_transfer_write, &stride, &map_data) orelse return VkError.MemoryMapFailed;
        errdefer gbm_bo_unmap(self.handle, map_data);

        const size = std.math.mul(usize, stride, self.height) catch return VkError.OutOfHostMemory;
        const minimum_stride = std.math.mul(u32, self.width, 4) catch return VkError.OutOfHostMemory;
        if (stride < minimum_stride or map_data == null)
            return VkError.MemoryMapFailed;

        return .{
            .data = @as([*]u8, @ptrCast(pointer))[0..size],
            .stride = stride,
            .map_data = map_data,
        };
    }

    pub fn unmap(self: *Buffer, mapping: Mapping) void {
        gbm_bo_unmap(self.handle, mapping.map_data);
    }
};

pub const Mapping = struct {
    data: []u8,
    stride: u32,
    map_data: ?*anyopaque,
};

fn fourccCode(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) |
        (@as(u32, b) << 8) |
        (@as(u32, c) << 16) |
        (@as(u32, d) << 24);
}
