const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const RefCounter = base.RefCounter;

const Device = @import("device/Device.zig");
const Dispatchable = base.Dispatchable;

const CommandBuffer = base.CommandBuffer;
const SoftDevice = @import("SoftDevice.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Queue;

interface: Interface,
lock: std.Thread.RwLock,

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
        .lock = .{},
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

    const allocator = soft_device.device_allocator.allocator();

    // Lock here to avoid acquiring it in `waitIdle` before runners start
    self.lock.lockShared();
    defer self.lock.unlockShared();

    for (infos) |info| {
        // Cloning info to keep them alive until commands dispatch end
        const cloned_info: Interface.SubmitInfo = .{
            .command_buffers = info.command_buffers.clone(allocator) catch return VkError.OutOfDeviceMemory,
        };
        const runners_counter = allocator.create(RefCounter) catch return VkError.OutOfDeviceMemory;
        runners_counter.* = .init;
        soft_device.workers.spawn(Self.taskRunner, .{ self, cloned_info, p_fence, runners_counter }) catch return VkError.Unknown;
    }
}

pub fn waitIdle(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.lock.lock();
    defer self.lock.unlock();
}

fn taskRunner(self: *Self, info: Interface.SubmitInfo, p_fence: ?*base.Fence, runners_counter: *RefCounter) void {
    self.lock.lockShared();
    defer self.lock.unlockShared();

    runners_counter.ref();
    defer {
        runners_counter.unref();
        if (!runners_counter.hasRefs()) {
            const soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", self.interface.owner));
            const allocator = soft_device.device_allocator.allocator();
            allocator.destroy(runners_counter);
        }
    }

    var soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", self.interface.owner));
    defer {
        var command_buffers = info.command_buffers;
        command_buffers.deinit(soft_device.device_allocator.allocator());
    }

    var device = Device.init();
    defer device.deinit();

    loop: for (info.command_buffers.items) |command_buffer| {
        command_buffer.submit() catch continue :loop;
        for (command_buffer.commands.items) |command| {
            device.dispatch(&command) catch |err| base.errors.errorLoggerContext(err, "the software command dispatcher");
        }
    }

    if (p_fence) |fence| {
        if (runners_counter.getRefsCount() == 1) {
            fence.signal() catch {};
        }
    }
}
