const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const kmd = @import("kmd.zig");

const VkError = base.VkError;
const Device = base.Device;
const FlintDevice = @import("FlintDevice.zig");

const drm_syncobj_create = 0xbf;
const drm_syncobj_destroy = 0xc0;
const drm_syncobj_wait = 0xc3;
const drm_syncobj_reset = 0xc4;
const drm_syncobj_signal = 0xc5;

const syncobj_create_signaled: u32 = 1 << 0;
const syncobj_wait_all: u32 = 1 << 0;
const syncobj_wait_for_submit: u32 = 1 << 1;

const SyncObjCreate = extern struct {
    handle: u32,
    flags: u32,
};

const SyncObjDestroy = extern struct {
    handle: u32,
    pad: u32,
};

const SyncObjWait = extern struct {
    handles: u64,
    timeout_nsec: i64,
    count_handles: u32,
    flags: u32,
    first_signaled: u32,
    pad: u32,
    deadline_nsec: u64,
};

const SyncObjArray = extern struct {
    handles: u64,
    count_handles: u32,
    pad: u32,
};

const Self = @This();
pub const Interface = base.Fence;

interface: Interface,
handle: u32,

pub fn create(device: *Device, allocator: std.mem.Allocator, info: *const vk.FenceCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);
    const flint_device: *FlintDevice = @alignCast(@fieldParentPtr("interface", device));
    var create_info = SyncObjCreate{
        .handle = 0,
        .flags = if (info.flags.signaled_bit) syncobj_create_signaled else 0,
    };

    base.utils.ioctl(
        try flint_device.kmd.file(),
        device.io(),
        kmd.drmIoctlIowr(drm_syncobj_create, SyncObjCreate),
        &create_info,
    ) catch return VkError.DeviceLost;

    errdefer destroyHandle(flint_device, device.io(), create_info.handle);

    interface.vtable = &.{
        .destroy = destroy,
        .getStatus = getStatus,
        .reset = reset,
        .signal = signal,
        .wait = wait,
    };

    self.* = .{
        .interface = interface,
        .handle = create_info.handle,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device: *FlintDevice = @alignCast(@fieldParentPtr("interface", interface.owner));
    destroyHandle(device, interface.owner.io(), self.handle);
    allocator.destroy(self);
}

pub fn getStatus(interface: *Interface) VkError!void {
    wait(interface, 0) catch |err| switch (err) {
        VkError.Timeout => return VkError.NotReady,
        else => return err,
    };
}

pub fn reset(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device: *FlintDevice = @alignCast(@fieldParentPtr("interface", interface.owner));
    var handles = [_]u32{self.handle};
    var reset_info = SyncObjArray{
        .handles = @intFromPtr(&handles),
        .count_handles = handles.len,
        .pad = 0,
    };
    base.utils.ioctl(
        try device.kmd.file(),
        interface.owner.io(),
        kmd.drmIoctlIowr(drm_syncobj_reset, SyncObjArray),
        &reset_info,
    ) catch return VkError.DeviceLost;
}

pub fn signal(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device: *FlintDevice = @alignCast(@fieldParentPtr("interface", interface.owner));
    var handles = [_]u32{self.handle};
    var signal_info = SyncObjArray{
        .handles = @intFromPtr(&handles),
        .count_handles = handles.len,
        .pad = 0,
    };
    base.utils.ioctl(
        try device.kmd.file(),
        interface.owner.io(),
        kmd.drmIoctlIowr(drm_syncobj_signal, SyncObjArray),
        &signal_info,
    ) catch return VkError.DeviceLost;
}

pub fn wait(interface: *Interface, timeout: u64) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device: *FlintDevice = @alignCast(@fieldParentPtr("interface", interface.owner));
    var handles = [_]u32{self.handle};
    var wait_info = SyncObjWait{
        .handles = @intFromPtr(&handles),
        .timeout_nsec = absoluteTimeout(interface.owner.io(), timeout),
        .count_handles = handles.len,
        .flags = syncobj_wait_all | syncobj_wait_for_submit,
        .first_signaled = 0,
        .pad = 0,
        .deadline_nsec = 0,
    };

    const errno = base.utils.ioctlErrno(
        try device.kmd.file(),
        interface.owner.io(),
        kmd.drmIoctlIowr(drm_syncobj_wait, SyncObjWait),
        &wait_info,
    ) catch return VkError.DeviceLost;

    return switch (errno) {
        .SUCCESS => {},
        .TIME => VkError.Timeout,
        else => VkError.DeviceLost,
    };
}

fn destroyHandle(device: *FlintDevice, io: std.Io, handle: u32) void {
    var destroy_info = SyncObjDestroy{
        .handle = handle,
        .pad = 0,
    };
    base.utils.ioctl(
        device.kmd.file() catch return,
        io,
        kmd.drmIoctlIowr(drm_syncobj_destroy, SyncObjDestroy),
        &destroy_info,
    ) catch @panic("ioctl failed");
}

fn absoluteTimeout(io: std.Io, timeout: u64) i64 {
    if (timeout == std.math.maxInt(u64)) return std.math.maxInt(i64);

    const now = std.Io.Clock.awake.now(io).nanoseconds;
    const deadline: i96 = now + @as(i96, timeout);
    return @intCast(@min(deadline, std.math.maxInt(i64)));
}
