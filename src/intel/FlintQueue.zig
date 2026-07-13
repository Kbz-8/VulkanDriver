const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const FlintCommandBuffer = @import("FlintCommandBuffer.zig");
const FlintDevice = @import("FlintDevice.zig");
const FlintFence = @import("FlintFence.zig");
const kmd = @import("kmd.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Queue;

interface: Interface,
completion: *FlintFence,

pub fn create(allocator: std.mem.Allocator, device: *base.Device, index: u32, family_index: u32, flags: vk.DeviceQueueCreateFlags) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, device, index, family_index, flags);
    const completion = try FlintFence.create(device, allocator, &.{
        .s_type = .fence_create_info,
        .p_next = null,
        .flags = .{ .signaled_bit = true },
    });
    errdefer completion.interface.destroy(allocator);
    interface.dispatch_table = &.{
        .bindSparse = bindSparse,
        .submit = submit,
        .waitIdle = waitIdle,
    };

    self.* = .{
        .interface = interface,
        .completion = completion,
    };
    return &self.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.completion.interface.destroy(allocator);
    allocator.destroy(self);
}

pub fn bindSparse(interface: *Interface, info: []const vk.BindSparseInfo, fence: ?*base.Fence) VkError!void {
    _ = interface;
    _ = info;
    _ = fence;
    return VkError.FeatureNotPresent;
}

pub fn submit(interface: *Interface, infos: []Interface.SubmitInfo, fence: ?*base.Fence) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const device: *FlintDevice = @alignCast(@fieldParentPtr("interface", interface.owner));

    var remaining_batches: usize = 0;
    for (infos) |info| {
        for (info.command_buffers.items) |command_buffer| {
            const intel_command_buffer: *FlintCommandBuffer = @alignCast(@fieldParentPtr("interface", command_buffer));
            if (intel_command_buffer.batch.items.len != 0) remaining_batches += 1;
        }
    }
    const batch_count = remaining_batches;

    try self.completion.interface.reset();

    for (infos) |info| {
        for (info.wait_semaphores.items) |semaphore| {
            try semaphore.wait();
        }

        for (info.command_buffers.items) |command_buffer| {
            const intel_command_buffer: *FlintCommandBuffer = @alignCast(@fieldParentPtr("interface", command_buffer));
            if (intel_command_buffer.batch.items.len == 0) {
                try intel_command_buffer.submitGpuBatch(&.{});
                continue;
            }

            remaining_batches -= 1;
            var syncs: [2]kmd.SyncDependency = undefined;
            var sync_count: usize = 0;
            if (remaining_batches == 0) {
                syncs[sync_count] = .{ .handle = self.completion.handle, .signal = true };
                sync_count += 1;
                if (fence) |base_fence| {
                    const flint_fence: *FlintFence = @alignCast(@fieldParentPtr("interface", base_fence));
                    syncs[sync_count] = .{ .handle = flint_fence.handle, .signal = true };
                    sync_count += 1;
                }
            }
            try intel_command_buffer.submitGpuBatch(syncs[0..sync_count]);
        }

        for (info.signal_semaphores.items) |semaphore| {
            try semaphore.signal();
        }
    }

    if (batch_count == 0) {
        var syncs: [2]kmd.SyncDependency = undefined;
        var sync_count: usize = 1;
        syncs[0] = .{ .handle = self.completion.handle, .signal = true };
        if (fence) |base_fence| {
            const flint_fence: *FlintFence = @alignCast(@fieldParentPtr("interface", base_fence));
            syncs[sync_count] = .{ .handle = flint_fence.handle, .signal = true };
            sync_count += 1;
        }

        // A real no-op request preserves queue order: its output fence cannot
        // signal ahead of an earlier request that is still running.
        try device.kmd.submitBatch(
            interface.owner.io(),
            interface.host_allocator.allocator(),
            &.{},
            &.{},
            syncs[0..sync_count],
        );
    }
}

pub fn waitIdle(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    try self.completion.interface.wait(std.math.maxInt(u64));
}
