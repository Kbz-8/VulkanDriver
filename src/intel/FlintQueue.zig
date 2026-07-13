const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const FlintBinarySemaphore = @import("FlintBinarySemaphore.zig");
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
    const allocator = interface.host_allocator.allocator();

    try self.completion.interface.reset();

    for (infos, 0..) |info, info_index| {
        const last_info = info_index + 1 == infos.len;
        const request_count = @max(info.command_buffers.items.len, 1);

        for (0..request_count) |request_index| {
            const first_request = request_index == 0;
            const last_request = request_index + 1 == request_count;

            var syncs = std.ArrayList(kmd.SyncDependency).empty;
            defer syncs.deinit(allocator);

            if (first_request) {
                for (info.wait_semaphores.items) |base_semaphore| {
                    const semaphore: *FlintBinarySemaphore = @alignCast(@fieldParentPtr("interface", base_semaphore));
                    syncs.append(allocator, .{ .handle = semaphore.handle, .wait = true }) catch return VkError.OutOfHostMemory;
                }
            }

            if (last_request) {
                for (info.signal_semaphores.items) |base_semaphore| {
                    const semaphore: *FlintBinarySemaphore = @alignCast(@fieldParentPtr("interface", base_semaphore));
                    syncs.append(allocator, .{ .handle = semaphore.handle, .signal = true }) catch return VkError.OutOfHostMemory;
                }

                if (last_info) {
                    syncs.append(allocator, .{ .handle = self.completion.handle, .signal = true }) catch return VkError.OutOfHostMemory;
                    if (fence) |base_fence| {
                        const flint_fence: *FlintFence = @alignCast(@fieldParentPtr("interface", base_fence));
                        syncs.append(allocator, .{ .handle = flint_fence.handle, .signal = true }) catch return VkError.OutOfHostMemory;
                    }
                }
            }

            if (info.command_buffers.items.len == 0) {
                try device.kmd.submitBatch(
                    interface.owner.io(),
                    allocator,
                    &.{},
                    &.{},
                    syncs.items,
                );
            } else {
                const command_buffer = info.command_buffers.items[request_index];
                const intel_command_buffer: *FlintCommandBuffer = @alignCast(@fieldParentPtr("interface", command_buffer));
                try intel_command_buffer.submitGpuBatch(syncs.items);
            }

            if (first_request) {
                for (info.wait_semaphores.items) |base_semaphore| {
                    const semaphore: *FlintBinarySemaphore = @alignCast(@fieldParentPtr("interface", base_semaphore));
                    try FlintBinarySemaphore.reset(&semaphore.interface);
                }
            }
        }
    }

    if (infos.len == 0) {
        var syncs: [2]kmd.SyncDependency = undefined;
        var sync_count: usize = 1;
        syncs[0] = .{ .handle = self.completion.handle, .signal = true };
        if (fence) |base_fence| {
            const flint_fence: *FlintFence = @alignCast(@fieldParentPtr("interface", base_fence));
            syncs[sync_count] = .{ .handle = flint_fence.handle, .signal = true };
            sync_count += 1;
        }

        try device.kmd.submitBatch(
            interface.owner.io(),
            allocator,
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
