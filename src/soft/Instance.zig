const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const PhysicalDevice = @import("PhysicalDevice.zig");

const Dispatchable = base.Dispatchable;

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Instance;

interface: Interface,

export fn __vkImplCreateInstance(allocator: *const std.mem.Allocator, infos: *const vk.InstanceCreateInfo) ?*Interface {
    return realVkImplInstanceInit(allocator.*, infos) catch return null;
}

// Pure Zig implementation to leverage `errdefer` and avoid memory leaks or complex resources handling
fn realVkImplInstanceInit(allocator: std.mem.Allocator, infos: *const vk.InstanceCreateInfo) !?*Interface {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.interface = try base.Instance.init(allocator, infos);
    self.interface.dispatch_table = &.{
        .requestPhysicalDevices = requestPhysicalDevices,
        .releasePhysicalDevices = releasePhysicalDevices,
        .destroyInstance = destroyInstance,
    };
    return &self.interface;
}

fn requestPhysicalDevices(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    // Software driver only has one physical device (the CPU)
    const physical_device = try PhysicalDevice.create(allocator, interface);
    errdefer physical_device.interface.releasePhysicalDevice(allocator) catch {};
    interface.physical_devices.append(allocator, try Dispatchable(PhysicalDevice.Interface).wrap(allocator, &physical_device.interface)) catch return VkError.OutOfHostMemory;
}

fn releasePhysicalDevices(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    defer {
        interface.physical_devices.deinit(allocator);
        interface.physical_devices = .empty;
    }

    const physical_device = interface.physical_devices.getLast();
    try physical_device.object.releasePhysicalDevice(allocator);
    physical_device.destroy(allocator);
}

fn destroyInstance(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}
