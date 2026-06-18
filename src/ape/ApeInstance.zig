const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const soft = @import("soft");
const flint = @import("flint");

const Dispatchable = base.Dispatchable;
const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Instance;

interface: Interface,
backend_instances: std.ArrayList(*Interface),

pub const EXTENSIONS = soft.Instance.EXTENSIONS;

pub fn create(allocator: std.mem.Allocator, infos: *const vk.InstanceCreateInfo) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    self.* = .{
        .interface = try base.Instance.init(allocator, infos),
        .backend_instances = .empty,
    };
    errdefer destroyBackendInstances(self, allocator);

    self.interface.dispatch_table = &.{
        .destroy = destroy,
    };
    self.interface.vtable = &.{
        .requestPhysicalDevices = requestPhysicalDevices,
        .releasePhysicalDevices = releasePhysicalDevices,
        .io = io,
    };

    const soft_instance = try soft.Instance.create(allocator, infos);
    errdefer soft_instance.deinit(allocator) catch {};
    self.backend_instances.append(allocator, soft_instance) catch return VkError.OutOfHostMemory;

    const flint_instance = try flint.Instance.create(allocator, infos);
    errdefer flint_instance.deinit(allocator) catch {};
    self.backend_instances.append(allocator, flint_instance) catch return VkError.OutOfHostMemory;

    return &self.interface;
}

fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    destroyBackendInstances(self, allocator);
    self.backend_instances.deinit(allocator);
    allocator.destroy(self);
}

fn requestPhysicalDevices(interface: *Interface, allocator: std.mem.Allocator, _: []base.drm.Card) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    for (self.backend_instances.items) |backend| {
        try appendBackendPhysicalDevices(self, allocator, backend);
    }
}

fn appendBackendPhysicalDevices(self: *Self, allocator: std.mem.Allocator, backend: *Interface) VkError!void {
    try backend.requestPhysicalDevices(allocator);
    errdefer backend.releasePhysicalDevices(allocator) catch {};

    self.interface.physical_devices.appendSlice(allocator, backend.physical_devices.items) catch return VkError.OutOfHostMemory;
    backend.physical_devices.deinit(allocator);
    backend.physical_devices = .empty;
}

fn releasePhysicalDevices(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    for (interface.physical_devices.items) |physical_device| {
        try physical_device.object.release(allocator);
        physical_device.destroy(allocator);
    }

    interface.physical_devices.deinit(allocator);
    interface.physical_devices = .empty;
}

fn destroyBackendInstances(self: *Self, allocator: std.mem.Allocator) void {
    for (self.backend_instances.items) |backend| {
        backend.dispatch_table.destroy(backend, allocator) catch |err| {
            base.errors.errorLogger(err);
        };
    }
    self.backend_instances.clearRetainingCapacity();
}

fn io(interface: *Interface) std.Io {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    if (self.backend_instances.items.len != 0) {
        return self.backend_instances.items[0].io();
    }
    unreachable;
}
