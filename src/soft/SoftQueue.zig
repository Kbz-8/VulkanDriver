const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const Executor = @import("Executor.zig");
const Dispatchable = base.Dispatchable;

const CommandBuffer = base.CommandBuffer;
const SoftDevice = @import("SoftDevice.zig");

const SoftDeviceMemory = @import("SoftDeviceMemory.zig");
const SoftFence = @import("SoftFence.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Queue;

interface: Interface,
wait_group: std.Thread.WaitGroup,
worker_mutex: std.Thread.Mutex,

pub fn create(allocator: std.mem.Allocator, device: *base.Device, index: u32, family_index: u32, flags: vk.DeviceQueueCreateFlags) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, device, index, family_index, flags);

    interface.dispatch_table = &.{
        .bindSparse = bindSparse,
        .submit = submit,
        .waitIdle = waitIdle,
    };

    self.* = .{
        .interface = interface,
        .wait_group = .{},
        .worker_mutex = .{},
    };
    return &self.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn bindSparse(interface: *Interface, info: []const vk.BindSparseInfo, fence: ?*base.Fence) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = self;
    _ = info;
    _ = fence;
    return VkError.FeatureNotPresent;
}

pub fn submit(interface: *Interface, infos: []Interface.SubmitInfo, p_fence: ?*base.Fence) VkError!void {
    var self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    var soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", interface.owner));

    if (p_fence) |fence| {
        const soft_fence: *SoftFence = @alignCast(@fieldParentPtr("interface", fence));
        soft_fence.concurrent_submits_count = std.atomic.Value(usize).init(infos.len);
    }

    for (infos) |info| {
        // Cloning info to keep them alive until commands dispatch end
        const cloned_info: Interface.SubmitInfo = .{
            .command_buffers = info.command_buffers.clone(soft_device.device_allocator.allocator()) catch return VkError.OutOfDeviceMemory,
        };
        soft_device.workers.spawnWg(&self.wait_group, Self.taskRunner, .{ self, cloned_info, p_fence });
    }
}

pub fn waitIdle(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.wait_group.wait();
}

fn taskRunner(self: *Self, info: Interface.SubmitInfo, p_fence: ?*base.Fence) void {
    var soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", self.interface.owner));
    defer {
        var command_buffers = info.command_buffers;
        command_buffers.deinit(soft_device.device_allocator.allocator());
    }

    var executor = Executor.init();
    defer executor.deinit();

    loop: for (info.command_buffers.items) |command_buffer| {
        command_buffer.submit() catch continue :loop;
        for (command_buffer.commands.items) |command| {
            executor.dispatch(&command);
        }
    }

    if (p_fence) |fence| {
        const soft_fence: *SoftFence = @alignCast(@fieldParentPtr("interface", fence));
        if (soft_fence.concurrent_submits_count.fetchSub(1, .release) == 1) {
            fence.signal() catch {};
        }
    }
}
