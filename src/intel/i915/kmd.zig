const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const drm = @import("drm.zig");
const common_kmd = @import("../kmd.zig");

const VkError = base.VkError;

const IOCTL = std.os.linux.IOCTL;

const Mapping = struct {
    bytes: []align(std.heap.page_size_min) u8,

    inline fn slice(self: Mapping, offset: vk.DeviceSize, size: vk.DeviceSize) VkError![]u8 {
        const start: usize = @intCast(offset);
        const len: usize = @intCast(size);
        return self.bytes[start .. start + len];
    }
};

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

    pub fn allocateMemory(self: *Device, io: std.Io, size: vk.DeviceSize) VkError!Memory {
        var create = drm.GemCreate{
            .size = size,
            .handle = 0,
            .pad = 0,
        };
        base.utils.ioctl(self.card.handle, io, common_kmd.drmIoctlIowr(drm.command_base + drm.i915_gem_create, drm.GemCreate), &create) catch return VkError.OutOfDeviceMemory;

        var memory = Memory{
            .handle = create.handle,
            .size = create.size,
            .mapping = null,
        };
        errdefer memory.deinit(self, io);

        try memory.setDomain(self, io, drm.i915_gem_domain_cpu, 0);
        return memory;
    }

    pub fn submitBatch(self: *Device, io: std.Io, allocator: std.mem.Allocator, commands: []const u32, relocations: []const common_kmd.Relocation, syncs: []const common_kmd.SyncDependency) VkError!void {
        const trailer_words = 6;
        const batch_size = (commands.len + trailer_words) * @sizeOf(u32);
        var batch = try self.allocateMemory(io, batch_size);
        defer batch.deinit(self, io);

        {
            const batch_map = try batch.map(self, io, 0, batch_size);
            const batch_words = std.mem.bytesAsSlice(u32, batch_map);
            @memcpy(batch_words[0..commands.len], commands);
            batch_words[commands.len + 0] = drm.mi_flush_dw;
            batch_words[commands.len + 1] = 0;
            batch_words[commands.len + 2] = 0;
            batch_words[commands.len + 3] = 0;
            batch_words[commands.len + 4] = 0;
            batch_words[commands.len + 5] = 0x05000000;
            batch.unmap();
        }
        try batch.flushRange(self, io, 0, batch_size);

        var objects = std.ArrayList(drm.ExecObject2).empty;
        defer objects.deinit(allocator);

        var object_handles = std.ArrayList(u32).empty;
        defer object_handles.deinit(allocator);

        for (relocations) |relocation| {
            if (std.mem.indexOfScalar(u32, object_handles.items, relocation.target_handle) == null) {
                object_handles.append(allocator, relocation.target_handle) catch return VkError.OutOfHostMemory;
                objects.append(allocator, .{
                    .handle = relocation.target_handle,
                    .relocation_count = 0,
                    .relocs_ptr = 0,
                    .alignment = 0,
                    .offset = 0,
                    .flags = if (relocation.write) drm.exec_object_write else 0,
                    .rsvd1 = 0,
                    .rsvd2 = 0,
                }) catch return VkError.OutOfHostMemory;
            } else if (relocation.write) {
                const index = std.mem.indexOfScalar(u32, object_handles.items, relocation.target_handle).?;
                objects.items[index].flags |= drm.exec_object_write;
            }
        }

        var i915_relocations = std.ArrayList(drm.RelocationEntry).empty;
        defer i915_relocations.deinit(allocator);

        for (relocations) |relocation| {
            i915_relocations.append(allocator, .{
                .target_handle = relocation.target_handle,
                .delta = relocation.delta,
                .offset = relocation.offset,
                .presumed_offset = 0,
                .read_domains = 0,
                .write_domain = 0,
            }) catch return VkError.OutOfHostMemory;
        }

        objects.append(allocator, .{
            .handle = batch.handle,
            .relocation_count = @intCast(i915_relocations.items.len),
            .relocs_ptr = @intFromPtr(i915_relocations.items.ptr),
            .alignment = 0,
            .offset = 0,
            .flags = 0,
            .rsvd1 = 0,
            .rsvd2 = 0,
        }) catch return VkError.OutOfHostMemory;

        var exec_fences = std.ArrayList(drm.ExecFence).empty;
        defer exec_fences.deinit(allocator);
        for (syncs) |sync| {
            exec_fences.append(allocator, .{
                .handle = sync.handle,
                .flags = (if (sync.wait) drm.i915_exec_fence_wait else 0) |
                    (if (sync.signal) drm.i915_exec_fence_signal else 0),
            }) catch return VkError.OutOfHostMemory;
        }

        var execbuffer = drm.ExecBuffer2{
            .buffers_ptr = @intFromPtr(objects.items.ptr),
            .buffer_count = @intCast(objects.items.len),
            .batch_start_offset = 0,
            .batch_len = @intCast(batch_size),
            .DR1 = 0,
            .DR4 = 0,
            .num_cliprects = @intCast(exec_fences.items.len),
            .cliprects_ptr = if (exec_fences.items.len == 0) 0 else @intFromPtr(exec_fences.items.ptr),
            .flags = drm.i915_exec_blt | (if (exec_fences.items.len == 0) 0 else drm.i915_exec_fence_array),
            .rsvd1 = 0,
            .rsvd2 = 0,
        };
        base.utils.ioctl(self.card.handle, io, common_kmd.drmIoctlIowr(drm.command_base + drm.i915_gem_execbuffer2, drm.ExecBuffer2), &execbuffer) catch return VkError.DeviceLost;
    }
};

pub const Memory = struct {
    handle: u32,
    size: vk.DeviceSize,
    mapping: ?Mapping,

    pub fn deinit(self: *Memory, device: *Device, io: std.Io) void {
        self.unmap();

        var close = drm.GemClose{
            .handle = self.handle,
            .pad = 0,
        };
        base.utils.ioctl(device.card.handle, io, common_kmd.drmIoctlIow(drm.gem_close, drm.GemClose), &close) catch {};

        self.* = undefined;
    }

    pub fn map(self: *Memory, device: *Device, io: std.Io, offset: vk.DeviceSize, size: vk.DeviceSize) VkError![]u8 {
        if (offset > self.size) return VkError.MemoryMapFailed;
        const available = self.size - offset;
        const map_size = if (size == vk.WHOLE_SIZE) available else size;
        if (map_size > available) return VkError.MemoryMapFailed;
        if (map_size > std.math.maxInt(usize)) return VkError.MemoryMapFailed;

        if (self.mapping) |mapping| {
            return mapping.slice(offset, map_size);
        }

        var mmap_offset = drm.GemMmapOffset{
            .handle = self.handle,
            .pad = 0,
            .offset = 0,
            .flags = drm.i915_mmap_offset_wb,
            .extensions = 0,
        };
        base.utils.ioctl(device.card.handle, io, common_kmd.drmIoctlIowr(drm.command_base + drm.i915_gem_mmap_gtt, drm.GemMmapOffset), &mmap_offset) catch return VkError.MemoryMapFailed;

        if (self.size > std.math.maxInt(usize)) return VkError.MemoryMapFailed;
        const full_size: usize = @intCast(self.size);
        const bytes = std.posix.mmap(
            null,
            full_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            device.card.handle.handle,
            @intCast(mmap_offset.offset),
        ) catch return VkError.MemoryMapFailed;

        self.mapping = .{ .bytes = bytes };
        return self.mapping.?.slice(offset, map_size);
    }

    pub fn unmap(self: *Memory) void {
        if (self.mapping) |mapping| {
            std.posix.munmap(mapping.bytes);
            self.mapping = null;
        }
    }

    pub fn flushRange(self: *Memory, device: *Device, io: std.Io, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!void {
        _ = offset;
        _ = size;
        try self.setDomain(device, io, drm.i915_gem_domain_cpu, 0);
    }

    pub fn invalidateRange(self: *Memory, device: *Device, io: std.Io, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!void {
        _ = offset;
        _ = size;
        try self.setDomain(device, io, drm.i915_gem_domain_cpu, 0);
    }

    fn setDomain(self: *Memory, device: *Device, io: std.Io, read_domains: u32, write_domain: u32) VkError!void {
        var domain = drm.GemSetDomain{
            .handle = self.handle,
            .read_domains = read_domains,
            .write_domain = write_domain,
        };
        base.utils.ioctl(device.card.handle, io, common_kmd.drmIoctlIow(drm.command_base + drm.i915_gem_set_domain, drm.GemSetDomain), &domain) catch return VkError.DeviceLost;
    }
};
