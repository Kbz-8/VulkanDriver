const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const SoftDevice = @import("SoftDevice.zig");
const SoftDeviceMemory = @import("SoftDeviceMemory.zig");
const SoftFence = @import("SoftFence.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Queue;

interface: Interface,
wait_group: std.Thread.WaitGroup,
mutex: std.Thread.Mutex,
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
        .mutex = .{},
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

pub fn submit(interface: *Interface, info: []const vk.SubmitInfo, fence: ?*base.Fence) VkError!void {
    var self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = info;

    const Runner = struct {
        fn run(queue: *Self, p_fence: ?*base.Fence) void {
            // Waiting for older submits to finish execution
            queue.worker_mutex.lock();
            defer queue.worker_mutex.unlock();

            // TODO: commands executions

            std.log.debug("Queue execution", .{});
            std.Thread.sleep(1_000_000_000);
            if (p_fence) |fence_obj| {
                fence_obj.signal() catch {};
            }
        }
    };

    self.mutex.lock();
    defer self.mutex.unlock();

    var soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", interface.owner));
    soft_device.workers.spawnWg(&self.wait_group, Runner.run, .{ self, fence });
}

pub fn waitIdle(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    self.mutex.lock();
    defer self.mutex.unlock();

    self.wait_group.wait();
}
