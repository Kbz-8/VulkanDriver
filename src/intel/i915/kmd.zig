const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const _i915 = @import("i915.zig");
const common_kmd = @import("../kmd.zig");

const VkError = base.VkError;

const RelocationGroup = struct {
    source_handle: u32,
    entries: std.ArrayList(_i915.RelocationEntry) = .empty,
};

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
        var create = _i915.GemCreate{
            .size = size,
            .handle = 0,
            .pad = 0,
        };
        base.utils.ioctl(
            self.card.handle,
            io,
            common_kmd.drmIoctlIowr(_i915.command_base + _i915.gem_create, _i915.GemCreate),
            &create,
        ) catch return VkError.OutOfDeviceMemory;

        var memory = Memory{
            .handle = create.handle,
            .size = create.size,
            .mapping = null,
        };
        errdefer memory.deinit(self, io);

        try memory.setDomain(self, io, _i915.gem_domain_cpu, 0);
        return memory;
    }

    pub fn submitBatch(
        self: *Device,
        io: std.Io,
        allocator: std.mem.Allocator,
        engine: common_kmd.Engine,
        commands: []const u32,
        relocations: []const common_kmd.Relocation,
        syncs: []const common_kmd.SyncDependency,
    ) VkError!void {
        const trailer_words: usize = switch (engine) {
            .blitter => 6,
            .render => if (commands.len % 2 == 0) 2 else 1,
        };
        const batch_size = (commands.len + trailer_words) * @sizeOf(u32);
        var batch = try self.allocateMemory(io, batch_size);
        defer batch.deinit(self, io);

        {
            const batch_map = try batch.map(self, io, 0, batch_size);
            const batch_words = std.mem.bytesAsSlice(u32, batch_map);
            @memcpy(batch_words[0..commands.len], commands);
            @memset(batch_words[commands.len..], 0);
            switch (engine) {
                .blitter => {
                    batch_words[commands.len] = _i915.mi_flush_dw;
                    batch_words[commands.len + 5] = _i915.mi_batch_buffer_end;
                },
                .render => batch_words[commands.len] = _i915.mi_batch_buffer_end,
            }
            batch.unmap();
        }
        try batch.flushRange(self, io, 0, batch_size);

        var object_handles = std.ArrayList(u32).empty;
        defer object_handles.deinit(allocator);
        for (relocations) |relocation| {
            if (relocation.source_handle) |source| {
                if (std.mem.indexOfScalar(u32, object_handles.items, source) == null)
                    object_handles.append(allocator, source) catch return VkError.OutOfHostMemory;
            }
            if (std.mem.indexOfScalar(u32, object_handles.items, relocation.target_handle) == null)
                object_handles.append(allocator, relocation.target_handle) catch return VkError.OutOfHostMemory;
        }
        if (std.mem.indexOfScalar(u32, object_handles.items, batch.handle) == null)
            object_handles.append(allocator, batch.handle) catch return VkError.OutOfHostMemory;

        var groups = std.ArrayList(RelocationGroup).empty;
        defer {
            for (groups.items) |*group| group.entries.deinit(allocator);
            groups.deinit(allocator);
        }
        for (relocations) |relocation| {
            const source = relocation.source_handle orelse batch.handle;
            var group_index = std.mem.indexOfScalar(u32, object_handles.items, source) orelse return VkError.DeviceLost;
            for (groups.items, 0..) |group, index| {
                if (group.source_handle == source) {
                    group_index = index;
                    break;
                }
            } else {
                groups.append(allocator, .{ .source_handle = source }) catch return VkError.OutOfHostMemory;
                group_index = groups.items.len - 1;
            }

            groups.items[group_index].entries.append(allocator, relocationEntry(relocation)) catch return VkError.OutOfHostMemory;
        }

        var objects = std.ArrayList(_i915.ExecObject2).empty;
        defer objects.deinit(allocator);
        for (object_handles.items) |handle| {
            var flags: u64 = 0;
            for (relocations) |relocation| {
                if (relocation.target_handle == handle and relocation.write)
                    flags |= _i915.exec_object_write;
            }

            var relocation_count: u32 = 0;
            var relocs_ptr: u64 = 0;
            for (groups.items) |group| {
                if (group.source_handle == handle) {
                    relocation_count = @intCast(group.entries.items.len);
                    relocs_ptr = @intFromPtr(group.entries.items.ptr);
                    break;
                }
            }
            objects.append(allocator, .{
                .handle = handle,
                .relocation_count = relocation_count,
                .relocs_ptr = relocs_ptr,
                .alignment = 0,
                .offset = 0,
                .flags = flags,
                .rsvd1 = 0,
                .rsvd2 = 0,
            }) catch return VkError.OutOfHostMemory;
        }

        var exec_fences = std.ArrayList(_i915.ExecFence).empty;
        defer exec_fences.deinit(allocator);
        for (syncs) |sync| {
            exec_fences.append(allocator, .{
                .handle = sync.handle,
                .flags = (if (sync.wait) _i915.exec_fence_wait else 0) | (if (sync.signal) _i915.exec_fence_signal else 0),
            }) catch return VkError.OutOfHostMemory;
        }

        var execbuffer = _i915.ExecBuffer2{
            .buffers_ptr = @intFromPtr(objects.items.ptr),
            .buffer_count = @intCast(objects.items.len),
            .batch_start_offset = 0,
            .batch_len = @intCast(batch_size),
            .DR1 = 0,
            .DR4 = 0,
            .num_cliprects = @intCast(exec_fences.items.len),
            .cliprects_ptr = if (exec_fences.items.len == 0) 0 else @intFromPtr(exec_fences.items.ptr),
            .flags = @as(u64, switch (engine) {
                .blitter => _i915.exec_blt,
                .render => _i915.exec_render,
            }) | (if (exec_fences.items.len == 0) 0 else _i915.exec_fence_array),
            .rsvd1 = 0,
            .rsvd2 = 0,
        };
        base.utils.ioctl(
            self.card.handle,
            io,
            common_kmd.drmIoctlIowr(_i915.command_base + _i915.gem_execbuffer2, _i915.ExecBuffer2),
            &execbuffer,
        ) catch return VkError.DeviceLost;
    }
};

fn relocationEntry(relocation: common_kmd.Relocation) _i915.RelocationEntry {
    const domain: u32 = switch (relocation.domain) {
        .none => 0,
        .render => _i915.gem_domain_render,
        .instruction => _i915.gem_domain_instruction,
    };
    return .{
        .target_handle = relocation.target_handle,
        .delta = relocation.delta,
        .offset = relocation.offset,
        // GPU address zero is valid. These locations have not been patched yet,
        // so never let i915 skip the initial relocation, including its delta.
        .presumed_offset = std.math.maxInt(u64),
        .read_domains = if (relocation.read) domain else 0,
        .write_domain = if (relocation.write) domain else 0,
    };
}

pub const Memory = struct {
    handle: u32,
    size: vk.DeviceSize,
    mapping: ?Mapping,

    pub fn deinit(self: *Memory, device: *Device, io: std.Io) void {
        self.unmap();

        var close = _i915.GemClose{
            .handle = self.handle,
            .pad = 0,
        };
        base.utils.ioctl(device.card.handle, io, common_kmd.drmIoctlIow(_i915.gem_close, _i915.GemClose), &close) catch @panic("Caught an error while handling an error");

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

        var mmap_offset = _i915.GemMmapOffset{
            .handle = self.handle,
            .pad = 0,
            .offset = 0,
            .flags = _i915.mmap_offset_wb,
            .extensions = 0,
        };
        base.utils.ioctl(
            device.card.handle,
            io,
            common_kmd.drmIoctlIowr(_i915.command_base + _i915.gem_mmap_gtt, _i915.GemMmapOffset),
            &mmap_offset,
        ) catch return VkError.MemoryMapFailed;

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
        try self.setDomain(device, io, _i915.gem_domain_cpu, 0);
    }

    pub fn invalidateRange(self: *Memory, device: *Device, io: std.Io, offset: vk.DeviceSize, size: vk.DeviceSize) VkError!void {
        _ = offset;
        _ = size;
        try self.setDomain(device, io, _i915.gem_domain_cpu, 0);
    }

    fn setDomain(self: *Memory, device: *Device, io: std.Io, read_domains: u32, write_domain: u32) VkError!void {
        var domain = _i915.GemSetDomain{
            .handle = self.handle,
            .read_domains = read_domains,
            .write_domain = write_domain,
        };
        base.utils.ioctl(
            device.card.handle,
            io,
            common_kmd.drmIoctlIow(_i915.command_base + _i915.gem_set_domain, _i915.GemSetDomain),
            &domain,
        ) catch return VkError.DeviceLost;
    }
};

test "[i915] initial relocations force patching even at GPU address zero" {
    const entry = relocationEntry(.{
        .source_handle = 4,
        .target_handle = 4,
        .offset = 64,
        .delta = 1920,
        .read = true,
        .write = false,
        .domain = .render,
    });
    try std.testing.expectEqual(std.math.maxInt(u64), entry.presumed_offset);
    try std.testing.expectEqual(@as(u32, 1920), entry.delta);
    try std.testing.expectEqual(@as(u64, 64), entry.offset);
    try std.testing.expectEqual(@as(u32, 4), entry.target_handle);
    try std.testing.expectEqual(_i915.gem_domain_render, entry.read_domains);
    try std.testing.expectEqual(@as(u32, 0), entry.write_domain);
}
