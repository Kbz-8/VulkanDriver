const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const ExecutionDevice = @import("device/Device.zig");

const SoftDevice = @import("SoftDevice.zig");
const SoftCommandBuffer = @import("SoftCommandBuffer.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Queue;

interface: Interface,
group: std.Io.Group,
mutex: std.Io.Mutex,
condition: std.Io.Condition,
next_sequence: usize,
executing_sequence: usize,

const TaskData = struct {
    queue: *Self,
    soft_device: *SoftDevice,
    sequence: usize,
    infos: std.ArrayList(Interface.SubmitInfo),
    fence: ?*base.Fence,
};

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
        .group = .init,
        .mutex = .init,
        .condition = .init,
        .next_sequence = 0,
        .executing_sequence = 0,
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
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", interface.owner));
    const io = interface.owner.io();
    const allocator = interface.owner.device_allocator.allocator();

    const data = allocator.create(TaskData) catch return VkError.OutOfDeviceMemory;
    errdefer allocator.destroy(data);

    var cloned_infos = try cloneSubmitInfos(allocator, infos);
    errdefer deinitSubmitInfos(allocator, &cloned_infos);

    const sequence = blk: {
        self.mutex.lock(io) catch return VkError.DeviceLost;
        defer self.mutex.unlock(io);

        const seq = self.next_sequence;
        self.next_sequence += 1;

        break :blk seq;
    };

    data.* = .{
        .queue = self,
        .soft_device = soft_device,
        .sequence = sequence,
        .infos = cloned_infos,
        .fence = p_fence,
    };

    self.group.async(io, taskRunner, .{data});
}

pub fn waitIdle(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const io = interface.owner.io();
    self.group.await(io) catch return VkError.DeviceLost;
}

fn executeSubmitInfo(soft_device: *SoftDevice, info: Interface.SubmitInfo) VkError!void {
    for (info.wait_semaphores.items) |semaphore| {
        try semaphore.wait();
    }

    // SAFETY: setup initializes every field before execution_device is read.
    var execution_device: ExecutionDevice = undefined;
    execution_device.setup(soft_device);
    defer execution_device.deinit(soft_device.interface.device_allocator.allocator());

    for (info.command_buffers.items) |command_buffer| {
        const soft_command_buffer: *SoftCommandBuffer = @alignCast(@fieldParentPtr("interface", command_buffer));
        try soft_command_buffer.execute(&execution_device);
    }

    for (info.signal_semaphores.items) |semaphore| {
        try semaphore.signal();
    }
}

fn taskRunner(data: *TaskData) void {
    const io = data.queue.interface.owner.io();
    const allocator = data.soft_device.interface.device_allocator.allocator();

    defer {
        deinitSubmitInfos(allocator, &data.infos);
        allocator.destroy(data);
    }

    {
        data.queue.mutex.lock(io) catch return;
        defer data.queue.mutex.unlock(io);

        while (data.sequence != data.queue.executing_sequence) {
            data.queue.condition.wait(io, &data.queue.mutex) catch return;
        }
    }

    for (data.infos.items) |info| {
        executeSubmitInfo(data.soft_device, info) catch |err| {
            std.log.scoped(.SoftQueue).err("Command buffer execution failed with '{s}'", .{@errorName(err)});
            break;
        };
    }

    if (data.fence) |fence| {
        fence.signal() catch |err| {
            std.log.scoped(.SoftQueue).err("Queue submit fence signal failed with '{s}'", .{@errorName(err)});
        };
    }

    data.queue.mutex.lock(io) catch return;
    defer data.queue.mutex.unlock(io);

    data.queue.executing_sequence += 1;
    data.queue.condition.broadcast(io);
}

fn cloneSubmitInfos(allocator: std.mem.Allocator, infos: []Interface.SubmitInfo) VkError!std.ArrayList(Interface.SubmitInfo) {
    var cloned_infos = std.ArrayList(Interface.SubmitInfo).initCapacity(allocator, infos.len) catch return VkError.OutOfDeviceMemory;
    errdefer deinitSubmitInfos(allocator, &cloned_infos);

    for (infos) |info| {
        var wait_semaphores = info.wait_semaphores.clone(allocator) catch return VkError.OutOfDeviceMemory;
        errdefer wait_semaphores.deinit(allocator);

        var command_buffers = info.command_buffers.clone(allocator) catch return VkError.OutOfDeviceMemory;
        errdefer command_buffers.deinit(allocator);

        var signal_semaphores = info.signal_semaphores.clone(allocator) catch return VkError.OutOfDeviceMemory;
        errdefer signal_semaphores.deinit(allocator);

        cloned_infos.append(allocator, .{
            .wait_semaphores = wait_semaphores,
            .command_buffers = command_buffers,
            .signal_semaphores = signal_semaphores,
        }) catch return VkError.OutOfDeviceMemory;
    }

    return cloned_infos;
}

fn deinitSubmitInfos(allocator: std.mem.Allocator, infos: *std.ArrayList(Interface.SubmitInfo)) void {
    for (infos.items) |*info| {
        info.wait_semaphores.deinit(allocator);
        info.command_buffers.deinit(allocator);
        info.signal_semaphores.deinit(allocator);
    }
    infos.deinit(allocator);
}
