const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const Io = @import("Io/Io.zig");
const PsvkPhysicalDevice = @import("PsvkPhysicalDevice.zig");

const Dispatchable = base.Dispatchable;

const VkError = base.VkError;

const Self = @This();

pub const Interface = base.Instance;
pub const extensions = [_]vk.ExtensionProperties{};

interface: Interface,
host_allocator: base.VulkanAllocator,
threaded: Io.Threaded,
io_impl: std.Io,

pub fn create(allocator: std.mem.Allocator, info: *const vk.InstanceCreateInfo) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    self.host_allocator = base.VulkanAllocator.from(allocator).clone();

    self.threaded = Io.Threaded.init(self.host_allocator.allocator(), .{}) catch return VkError.InitializationFailed;
    errdefer self.threaded.deinit();

    self.io_impl = self.threaded.io();

    var interface = try Interface.init(allocator, info);

    interface.dispatch_table = &.{
        .destroy = destroy,
    };

    interface.vtable = &.{
        .requestPhysicalDevices = requestPhysicalDevices,
        .releasePhysicalDevices = releasePhysicalDevices,
        .io = io,
        .enumerate_drm_devices = false,
    };

    self.interface = interface;

    return &self.interface;
}

fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.threaded.deinit();
    allocator.destroy(self);
}

fn requestPhysicalDevices(interface: *Interface, allocator: std.mem.Allocator, _: []base.drm.Card) VkError!void {
    if (interface.physical_devices.items.len != 0) {
        return;
    }

    // PSVK exposes the Vita GPU as a single Vulkan physical device.
    const physical_device = try PsvkPhysicalDevice.create(allocator, interface);
    errdefer physical_device.interface.release(allocator) catch @panic("Caught an error while handling an error");

    const dispatchable = try Dispatchable(base.PhysicalDevice).wrap(allocator, &physical_device.interface);
    errdefer dispatchable.destroy(allocator);

    interface.physical_devices.append(allocator, dispatchable) catch return VkError.OutOfHostMemory;
}

fn releasePhysicalDevices(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    for (interface.physical_devices.items) |physical_device| {
        try physical_device.object.release(allocator);
        physical_device.destroy(allocator);
    }
    interface.physical_devices.deinit(allocator);
    interface.physical_devices = .empty;
}

fn io(interface: *Interface) std.Io {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    return self.io_impl;
}
