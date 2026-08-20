const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("lib.zig");
const proto = lib.proto;

const PhiBinarySemaphore = @import("PhiBinarySemaphore.zig");
const PhiCommandBuffer = @import("PhiCommandBuffer.zig");
const PhiDevice = @import("PhiDevice.zig");
const PhiFence = @import("PhiFence.zig");
const PhiTransport = @import("PhiTransport.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Queue;

const ring_capacity: usize = @intCast(proto.PHI_QUEUE_RING_CAPACITY);
const ring_capacity_u64: u64 = @intCast(ring_capacity);
const shutdown_sequence = std.math.maxInt(u64);

const PreparedSubmit = struct {
    wait_semaphores: std.ArrayList(*base.BinarySemaphore),
    signal_semaphores: std.ArrayList(*base.BinarySemaphore),
    command_backing: ?[]u8,
    scif_offset: ?u64,
    registered_size: usize,
    command_size: usize,
    command_count: u64,
};

const PendingCompletion = struct {
    signal_semaphores: std.ArrayList(*base.BinarySemaphore),
    fence: ?*base.Fence,
    command_backing: ?[]u8,
    scif_offset: ?u64,
    registered_size: usize,
};

const TaskData = struct {
    queue: *Self,
    sequence: usize,
    submits: std.ArrayList(PreparedSubmit),
    fence: ?*base.Fence,
};

interface: Interface,
transport: PhiTransport,
ring_backing: []u8,
ring_offset: u64,
shared: *proto.PhiQueueShared,

submit_group: std.Io.Group,
completion_group: std.Io.Group,
mutex: std.Io.Mutex,
condition: std.Io.Condition,

next_task_sequence: usize,
executing_task_sequence: usize,
next_remote_sequence: u64,
completed_sequence: u64,
pending: [ring_capacity]?PendingCompletion,

error_state: ?VkError,
shutting_down: bool,
remote_stopped: bool,

pub fn create(allocator: std.mem.Allocator, device: *base.Device, index: u32, family_index: u32, flags: vk.DeviceQueueCreateFlags) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, device, index, family_index, flags);
    interface.dispatch_table = &.{
        .bindSparse = bindSparse,
        .submit = submit,
        .waitIdle = waitIdle,
    };

    const phi_device: *PhiDevice = @alignCast(@fieldParentPtr("interface", device));
    var transport = try phi_device.transport.connectPeer();
    errdefer transport.close();

    const device_allocator = device.device_allocator.allocator();
    const page_size = std.heap.pageSize();
    const registered_size = std.mem.alignForward(usize, @sizeOf(proto.PhiQueueShared), page_size);
    const ring_backing = device_allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_max),
        registered_size,
    ) catch return VkError.OutOfHostMemory;
    errdefer device_allocator.free(ring_backing);
    @memset(ring_backing, 0);

    const ring_offset = try transport.registerHostMemory(ring_backing);
    errdefer transport.unregisterHostMemory(ring_offset, ring_backing.len) catch {};

    const setup_request: proto.PhiQueueSetupRequest = .{
        .scif_offset = ring_offset,
        .scif_size = ring_backing.len,
        .ring_capacity = @intCast(ring_capacity),
        .reserved = 0,
    };
    var setup_reply = std.mem.zeroes(proto.PhiResultReply);
    try transport.request(
        proto.PHI_PACKET_QUEUE_SETUP,
        std.mem.asBytes(&setup_request),
        std.mem.asBytes(&setup_reply),
    );
    if (setup_reply.result.status != proto.PHI_STATUS_OK) {
        return PhiTransport.statusToErr(setup_reply.result.status);
    }

    const shared: *proto.PhiQueueShared = @ptrCast(@alignCast(ring_backing.ptr));

    self.* = .{
        .interface = interface,
        .transport = transport,
        .ring_backing = ring_backing,
        .ring_offset = ring_offset,
        .shared = shared,
        .submit_group = .init,
        .completion_group = .init,
        .mutex = .init,
        .condition = .init,
        .next_task_sequence = 0,
        .executing_task_sequence = 0,
        .next_remote_sequence = 1,
        .completed_sequence = 0,
        .pending = [_]?PendingCompletion{null} ** ring_capacity,
        .error_state = null,
        .shutting_down = false,
        .remote_stopped = false,
    };

    self.completion_group.async(device.io(), completionRunner, .{self});
    return &self.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const io = interface.owner.io();
    const device_allocator = interface.owner.device_allocator.allocator();

    waitIdle(interface) catch |err| {
        std.log.scoped(.PhiQueue).warn("Queue did not become idle during destruction: {s}", .{@errorName(err)});
    };

    var graceful_shutdown = true;
    self.mutex.lock(io) catch {
        graceful_shutdown = false;
    };
    if (graceful_shutdown) {
        self.shutting_down = true;
        self.condition.broadcast(io);
        self.mutex.unlock(io);

        self.transport.sendQueueDoorbell(shutdown_sequence) catch |err| {
            graceful_shutdown = false;
            std.log.scoped(.PhiQueue).warn("Failed to send queue shutdown doorbell: {s}", .{@errorName(err)});
            self.transport.close();
        };
    } else {
        // Wake the blocking completion receiver before releasing queue storage
        self.transport.close();
    }

    self.completion_group.await(io) catch |err| {
        graceful_shutdown = false;
        std.log.scoped(.PhiQueue).warn("Failed while joining completion receiver: {s}", .{@errorName(err)});
    };

    if (graceful_shutdown) {
        self.mutex.lock(io) catch {
            graceful_shutdown = false;
        };
        if (graceful_shutdown) {
            graceful_shutdown = self.remote_stopped;
            self.mutex.unlock(io);
        }
    }

    if (graceful_shutdown) {
        self.transport.unregisterHostMemory(self.ring_offset, self.ring_backing.len) catch |err| {
            std.log.scoped(.PhiQueue).warn("Failed to unregister queue ring: {s}", .{@errorName(err)});
        };
    }

    self.transport.close();
    cleanupPendingAfterClose(self, device_allocator);
    device_allocator.free(self.ring_backing);
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
    const io = interface.owner.io();
    const allocator = interface.owner.device_allocator.allocator();

    try self.checkHealthy();

    const data = allocator.create(TaskData) catch return VkError.OutOfDeviceMemory;
    errdefer allocator.destroy(data);

    var prepared_submits = try prepareSubmits(self, allocator, infos);
    errdefer deinitPreparedSubmits(self, allocator, &prepared_submits);

    const sequence = blk: {
        self.mutex.lock(io) catch return VkError.DeviceLost;
        defer self.mutex.unlock(io);

        if (self.error_state) |err| return err;
        if (self.shutting_down) return VkError.DeviceLost;

        const value = self.next_task_sequence;
        self.next_task_sequence += 1;
        break :blk value;
    };

    data.* = .{
        .queue = self,
        .sequence = sequence,
        .submits = prepared_submits,
        .fence = fence,
    };

    self.submit_group.async(io, taskRunner, .{data});
}

pub fn waitIdle(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const io = interface.owner.io();

    self.submit_group.await(io) catch {
        self.markLost(VkError.DeviceLost);
        return VkError.DeviceLost;
    };

    self.mutex.lock(io) catch return VkError.DeviceLost;
    defer self.mutex.unlock(io);

    while (self.completed_sequence + 1 < self.next_remote_sequence and self.error_state == null) {
        self.condition.wait(io, &self.mutex) catch return VkError.DeviceLost;
    }

    if (self.error_state) |err| return err;
}

fn checkHealthy(self: *Self) VkError!void {
    const io = self.interface.owner.io();
    self.mutex.lock(io) catch return VkError.DeviceLost;
    defer self.mutex.unlock(io);

    if (self.error_state) |err| return err;
    if (self.shutting_down) return VkError.DeviceLost;
}

fn prepareSubmits(self: *Self, allocator: std.mem.Allocator, infos: []Interface.SubmitInfo) VkError!std.ArrayList(PreparedSubmit) {
    var submits = std.ArrayList(PreparedSubmit).initCapacity(allocator, infos.len) catch return VkError.OutOfDeviceMemory;
    errdefer deinitPreparedSubmits(self, allocator, &submits);

    for (infos) |info| {
        var prepared = try prepareSubmit(self, allocator, info);
        submits.append(allocator, prepared) catch {
            deinitPreparedSubmit(self, allocator, &prepared);
            return VkError.OutOfDeviceMemory;
        };
    }

    return submits;
}

fn prepareSubmit(self: *Self, allocator: std.mem.Allocator, info: Interface.SubmitInfo) VkError!PreparedSubmit {
    var wait_semaphores = info.wait_semaphores.clone(allocator) catch return VkError.OutOfDeviceMemory;
    errdefer wait_semaphores.deinit(allocator);

    var signal_semaphores = info.signal_semaphores.clone(allocator) catch return VkError.OutOfDeviceMemory;
    errdefer signal_semaphores.deinit(allocator);

    var command_size: usize = 0;
    var command_count: u64 = 0;
    for (info.command_buffers.items) |command_buffer| {
        const phi_command_buffer: *PhiCommandBuffer = @alignCast(@fieldParentPtr("interface", command_buffer));

        if (phi_command_buffer.commands.items.len > std.math.maxInt(usize) - command_size) {
            return VkError.OutOfHostMemory;
        }
        command_size += phi_command_buffer.commands.items.len;

        const serialized_cmd_count: u64 = @intCast(phi_command_buffer.serialized_cmd_count);
        if (serialized_cmd_count > std.math.maxInt(u64) - command_count) {
            return VkError.OutOfHostMemory;
        }
        command_count += serialized_cmd_count;
    }

    var command_backing: ?[]u8 = null;
    var scif_offset: ?u64 = null;
    var registered_size: usize = 0;

    if (command_size != 0) {
        const page_size = std.heap.pageSize();
        if (command_size > std.math.maxInt(usize) - (page_size - 1)) {
            return VkError.OutOfHostMemory;
        }
        registered_size = std.mem.alignForward(usize, command_size, page_size);

        const backing = allocator.alignedAlloc(
            u8,
            .fromByteUnits(std.heap.page_size_max),
            registered_size,
        ) catch return VkError.OutOfHostMemory;
        errdefer allocator.free(backing);
        @memset(backing, 0);

        var write_offset: usize = 0;
        for (info.command_buffers.items) |command_buffer| {
            const phi_command_buffer: *PhiCommandBuffer = @alignCast(@fieldParentPtr("interface", command_buffer));
            const commands = phi_command_buffer.commands.items;
            @memcpy(backing[write_offset .. write_offset + commands.len], commands);
            write_offset += commands.len;
        }

        const offset = try self.transport.registerHostMemory(backing);
        errdefer self.transport.unregisterHostMemory(offset, backing.len) catch {};

        command_backing = backing;
        scif_offset = offset;
    }

    return .{
        .wait_semaphores = wait_semaphores,
        .signal_semaphores = signal_semaphores,
        .command_backing = command_backing,
        .scif_offset = scif_offset,
        .registered_size = registered_size,
        .command_size = command_size,
        .command_count = command_count,
    };
}

fn deinitPreparedSubmits(self: *Self, allocator: std.mem.Allocator, submits: *std.ArrayList(PreparedSubmit)) void {
    for (submits.items) |*prepared| {
        deinitPreparedSubmit(self, allocator, prepared);
    }
    submits.deinit(allocator);
}

fn deinitPreparedSubmit(self: *Self, allocator: std.mem.Allocator, prepared: *PreparedSubmit) void {
    prepared.wait_semaphores.deinit(allocator);
    prepared.signal_semaphores.deinit(allocator);

    if (prepared.scif_offset) |offset| {
        self.transport.unregisterHostMemory(offset, prepared.registered_size) catch |err| {
            std.log.scoped(.PhiQueue).warn("Failed to unregister staged command buffer: {s}", .{@errorName(err)});
        };
    }
    if (prepared.command_backing) |backing| allocator.free(backing);

    prepared.command_backing = null;
    prepared.scif_offset = null;
    prepared.registered_size = 0;
    prepared.command_size = 0;
    prepared.command_count = 0;
}

fn taskRunner(data: *TaskData) void {
    const self = data.queue;
    const io = self.interface.owner.io();
    const allocator = self.interface.owner.device_allocator.allocator();

    defer {
        deinitPreparedSubmits(self, allocator, &data.submits);
        allocator.destroy(data);
    }

    self.mutex.lock(io) catch {
        failTask(data);
        self.markLost(VkError.DeviceLost);
        return;
    };
    while (data.sequence != self.executing_task_sequence and self.error_state == null) {
        self.condition.wait(io, &self.mutex) catch {
            self.mutex.unlock(io);
            failTask(data);
            self.markLost(VkError.DeviceLost);
            return;
        };
    }
    if (self.error_state != null) {
        self.mutex.unlock(io);
        failTask(data);
        return;
    }
    self.mutex.unlock(io);

    var task_error: ?VkError = null;

    if (data.submits.items.len == 0) {
        if (data.fence) |fence| {
            var marker: PreparedSubmit = .{
                .wait_semaphores = .empty,
                .signal_semaphores = .empty,
                .command_backing = null,
                .scif_offset = null,
                .registered_size = 0,
                .command_size = 0,
                .command_count = 0,
            };
            self.publish(&marker, fence) catch |err| {
                task_error = err;
            };
            if (task_error == null) data.fence = null;
        }
    } else {
        for (data.submits.items, 0..) |*prepared, info_index| {
            for (prepared.wait_semaphores.items) |semaphore| {
                semaphore.wait() catch |err| {
                    task_error = err;
                    break;
                };
            }
            if (task_error != null) break;

            const submission_fence = if (info_index + 1 == data.submits.items.len) data.fence else null;
            self.publish(prepared, submission_fence) catch |err| {
                task_error = err;
                break;
            };
            if (submission_fence != null) data.fence = null;
        }
    }

    if (task_error) |err| {
        failTask(data);
        self.markLost(err);
        return;
    }

    self.mutex.lock(io) catch {
        self.markLost(VkError.DeviceLost);
        return;
    };
    self.executing_task_sequence += 1;
    self.condition.broadcast(io);
    self.mutex.unlock(io);
}

fn publish(self: *Self, prepared: *PreparedSubmit, fence: ?*base.Fence) VkError!void {
    const io = self.interface.owner.io();

    self.mutex.lock(io) catch return VkError.DeviceLost;

    while ((self.next_remote_sequence - 1) - self.completed_sequence >= ring_capacity_u64 and self.error_state == null) {
        self.condition.wait(io, &self.mutex) catch {
            self.mutex.unlock(io);
            return VkError.DeviceLost;
        };
    }

    if (self.error_state) |err| {
        self.mutex.unlock(io);
        return err;
    }
    if (self.shutting_down) {
        self.mutex.unlock(io);
        return VkError.DeviceLost;
    }

    const sequence = self.next_remote_sequence;
    if (sequence == shutdown_sequence) {
        self.mutex.unlock(io);
        return VkError.DeviceLost;
    }
    const slot: usize = @intCast((sequence - 1) % ring_capacity_u64);
    if (self.pending[slot] != null) {
        self.mutex.unlock(io);
        return VkError.DeviceLost;
    }

    const command_scif_offset = prepared.scif_offset orelse 0;
    self.pending[slot] = .{
        .signal_semaphores = prepared.signal_semaphores,
        .fence = fence,
        .command_backing = prepared.command_backing,
        .scif_offset = prepared.scif_offset,
        .registered_size = prepared.registered_size,
    };

    prepared.signal_semaphores = .empty;
    prepared.command_backing = null;
    prepared.scif_offset = null;
    prepared.registered_size = 0;

    self.shared.submissions[slot] = .{
        .sequence = sequence,
        .command_scif_offset = command_scif_offset,
        .command_size = prepared.command_size,
        .command_count = prepared.command_count,
    };

    @atomicStore(
        @TypeOf(self.shared.producer_sequence),
        &self.shared.producer_sequence,
        @intCast(sequence),
        .release,
    );
    self.next_remote_sequence += 1;
    self.mutex.unlock(io);

    self.transport.sendQueueDoorbell(sequence) catch |err| {
        self.markLost(VkError.DeviceLost);
        return err;
    };
}

fn completionRunner(self: *Self) void {
    while (true) {
        const completion = self.transport.receiveQueueCompletion() catch {
            if (!self.isShuttingDown()) self.markLost(VkError.DeviceLost);
            return;
        };

        if (completion.sequence == shutdown_sequence) {
            const io = self.interface.owner.io();
            self.mutex.lock(io) catch return;
            self.remote_stopped = completion.status == proto.PHI_STATUS_OK;
            self.condition.broadcast(io);
            self.mutex.unlock(io);
            return;
        }

        self.completeOne(completion);
    }
}

fn completeOne(self: *Self, completion: proto.PhiQueueCompletion) void {
    const io = self.interface.owner.io();
    const allocator = self.interface.owner.device_allocator.allocator();

    self.mutex.lock(io) catch {
        self.markLost(VkError.DeviceLost);
        return;
    };

    if (completion.sequence != self.completed_sequence + 1 or completion.sequence >= self.next_remote_sequence) {
        self.mutex.unlock(io);
        self.markLost(VkError.DeviceLost);
        return;
    }

    const slot: usize = @intCast((completion.sequence - 1) % ring_capacity_u64);
    var pending = self.pending[slot] orelse {
        self.mutex.unlock(io);
        self.markLost(VkError.DeviceLost);
        return;
    };
    self.pending[slot] = null;
    self.mutex.unlock(io);

    var cleanup_failed = false;
    if (pending.scif_offset) |offset| {
        self.transport.unregisterHostMemory(offset, pending.registered_size) catch |err| {
            cleanup_failed = true;
            std.log.scoped(.PhiQueue).err("Failed to unregister completed command buffer: {s}", .{@errorName(err)});
        };
    }
    if (pending.command_backing) |backing| allocator.free(backing);

    if (completion.status != proto.PHI_STATUS_OK or cleanup_failed) {
        self.markLost(VkError.DeviceLost);
        failPending(&pending);
    } else if (self.hasError()) {
        failPending(&pending);
    } else {
        signalPending(self, &pending);
    }

    pending.signal_semaphores.deinit(allocator);

    self.mutex.lock(io) catch {
        self.markLost(VkError.DeviceLost);
        return;
    };
    self.completed_sequence = completion.sequence;
    self.condition.broadcast(io);
    self.mutex.unlock(io);
}

fn signalPending(self: *Self, pending: *PendingCompletion) void {
    var signal_failed = false;

    for (pending.signal_semaphores.items) |semaphore| {
        semaphore.signal() catch {
            signal_failed = true;
        };
    }
    if (pending.fence) |fence| {
        fence.signal() catch {
            signal_failed = true;
        };
    }

    if (signal_failed) self.markLost(VkError.DeviceLost);
}

fn failPending(pending: *PendingCompletion) void {
    for (pending.signal_semaphores.items) |semaphore| {
        PhiBinarySemaphore.fail(semaphore);
    }
    if (pending.fence) |fence| PhiFence.fail(fence);
}

fn failTask(data: *TaskData) void {
    for (data.submits.items) |*prepared| {
        for (prepared.signal_semaphores.items) |semaphore| {
            PhiBinarySemaphore.fail(semaphore);
        }
    }
    if (data.fence) |fence| PhiFence.fail(fence);
}

fn markLost(self: *Self, _: VkError) void {
    const io = self.interface.owner.io();
    self.mutex.lock(io) catch return;
    defer self.mutex.unlock(io);

    const first_failure = self.error_state == null;
    self.error_state = VkError.DeviceLost;
    self.condition.broadcast(io);

    if (!first_failure) return;

    for (&self.pending) |*entry| {
        if (entry.*) |*pending| failPending(pending);
    }
}

fn hasError(self: *Self) bool {
    const io = self.interface.owner.io();
    self.mutex.lock(io) catch return true;
    defer self.mutex.unlock(io);
    return self.error_state != null;
}

fn isShuttingDown(self: *Self) bool {
    const io = self.interface.owner.io();
    self.mutex.lock(io) catch return true;
    defer self.mutex.unlock(io);
    return self.shutting_down;
}

fn cleanupPendingAfterClose(self: *Self, allocator: std.mem.Allocator) void {
    for (&self.pending) |*entry| {
        if (entry.*) |*pending| {
            failPending(pending);
            if (pending.command_backing) |backing| allocator.free(backing);
            pending.signal_semaphores.deinit(allocator);
            entry.* = null;
        }
    }
}
