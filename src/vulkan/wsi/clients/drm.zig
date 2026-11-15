//! Linear Wayland DMA-BUF allocation using the drm package

const std = @import("std");
const builtin = @import("builtin");
const lib = @import("../../lib.zig");
const drm = @import("drm");

const VkError = lib.VkError;
const ioctl = std.os.linux.IOCTL;

const PrimeHandle = extern struct {
    handle: u32,
    flags: u32 = @bitCast(std.os.linux.O{ .ACCMODE = .RDWR, .CLOEXEC = true }),
    fd: i32 = -1,
};

const DmaBufSync = extern struct {
    flags: u64,
};

const prime_handle_to_fd = ioctl.IOWR('d', 0x2d, PrimeHandle);
const dma_buf_sync = ioctl.IOW('b', 0, DmaBufSync);

pub fn openCard(io: std.Io) VkError!drm.Card {
    if (comptime builtin.os.tag != .linux)
        return VkError.InitializationFailed;

    const dir = std.Io.Dir.openDirAbsolute(io, drm.dir_name, .{ .iterate = true }) catch return VkError.InitializationFailed;
    defer dir.close(io);

    var iterator = dir.iterate();
    while (iterator.next(io) catch return VkError.InitializationFailed) |entry| {
        if (entry.kind != .character_device or !std.mem.startsWith(u8, entry.name, drm.primary_minor_name))
            continue;

        const card: drm.Card = .{
            .handle = dir.openFile(io, entry.name, .{ .mode = .read_write }) catch continue,
        };

        var probe = Buffer.create(card, io, 1, 1) catch {
            card.close(io);
            continue;
        };

        probe.deinit(card, io);
        return card;
    }

    std.log.scoped(.DRM).err("Could not open a DRM primary node. Check /dev/dri/card* permissions", .{});
    return VkError.InitializationFailed;
}

pub const Buffer = struct {
    dumb: drm.DumbBuffer,
    file: std.Io.File,
    data: []align(std.heap.page_size_min) u8,

    /// The caller owns `card` and must keep it alive until deinit
    pub fn create(card: drm.Card, io: std.Io, width: u32, height: u32) VkError!Buffer {
        const minimum_stride = std.math.mul(u32, width, 4) catch return VkError.OutOfDeviceMemory;
        if (width == 0 or height == 0)
            return VkError.OutOfDeviceMemory;

        const dumb = card.createDumbBuffer(io, width, height, 32) catch return VkError.OutOfDeviceMemory;
        errdefer destroyHandle(card, io, dumb.handle);

        const minimum_size = std.math.mul(usize, dumb.stride, height) catch return VkError.OutOfDeviceMemory;
        if (dumb.stride < minimum_stride or dumb.size < minimum_size)
            return VkError.OutOfDeviceMemory;

        var prime: PrimeHandle = .{ .handle = dumb.handle };
        const errno = lib.utils.ioctlErrno(card.handle, io, prime_handle_to_fd, &prime) catch return VkError.InitializationFailed;

        if (errno != .SUCCESS or prime.fd < 0)
            return VkError.InitializationFailed;

        const dma_buf: std.Io.File = .{ .handle = prime.fd, .flags = .{ .nonblocking = false } };
        errdefer dma_buf.close(io);

        const offset = card.mapDumbBuffer(io, dumb, 0) catch return VkError.MemoryMapFailed;
        const data = std.posix.mmap(
            null,
            dumb.size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            card.handle.handle,
            offset,
        ) catch return VkError.MemoryMapFailed;

        return .{ .dumb = dumb, .file = dma_buf, .data = data };
    }

    pub fn deinit(self: *Buffer, card: drm.Card, io: std.Io) void {
        std.posix.munmap(self.data);
        self.file.close(io);
        destroyHandle(card, io, self.dumb.handle);
        self.* = undefined;
    }

    pub fn beginWrite(self: *const Buffer, io: std.Io) VkError!void {
        try self.sync(io, false);
    }

    pub fn endWrite(self: *const Buffer, io: std.Io) VkError!void {
        try self.sync(io, true);
    }

    fn sync(self: *const Buffer, io: std.Io, end: bool) VkError!void {
        var request: DmaBufSync = .{ .flags = 2 | (if (end) @as(u64, 4) else 0) };
        while (true) {
            const errno = lib.utils.ioctlErrno(self.file, io, dma_buf_sync, &request) catch return VkError.MemoryMapFailed;
            switch (errno) {
                .SUCCESS => return,
                .INTR, .AGAIN => continue,
                else => return VkError.MemoryMapFailed,
            }
        }
    }
};

fn destroyHandle(card: drm.Card, io: std.Io, handle: u32) void {
    card.destroyDumbBuffer(io, handle) catch
        std.log.scoped(.DRM).warn("Could not destroy DRM dumb buffer {d}", .{handle});
}
