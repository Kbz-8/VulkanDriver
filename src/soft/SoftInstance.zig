const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const SoftPhysicalDevice = @import("SoftPhysicalDevice.zig");

const Dispatchable = base.Dispatchable;

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Instance;

interface: Interface,

fn castExtension(comptime ext: vk.ApiInfo) vk.ExtensionProperties {
    var props: vk.ExtensionProperties = .{
        .extension_name = undefined,
        .spec_version = @bitCast(ext.version),
    };
    @memcpy(props.extension_name[0..ext.name.len], ext.name);
    return props;
}

pub const EXTENSIONS = [_]vk.ExtensionProperties{
    castExtension(vk.extensions.khr_get_physical_device_properties_2),
};

pub fn create(allocator: std.mem.Allocator, infos: *const vk.InstanceCreateInfo) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    self.interface = try base.Instance.init(allocator, infos);
    self.interface.dispatch_table = &.{
        .destroy = destroy,
    };
    self.interface.vtable = &.{
        .requestPhysicalDevices = requestPhysicalDevices,
        .releasePhysicalDevices = releasePhysicalDevices,
    };
    return &self.interface;
}

fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

fn requestPhysicalDevices(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    // Software driver has only one physical device (the CPU)
    const physical_device = try SoftPhysicalDevice.create(allocator, interface);
    errdefer physical_device.interface.releasePhysicalDevice(allocator) catch {};
    interface.physical_devices.append(allocator, try Dispatchable(base.PhysicalDevice).wrap(allocator, &physical_device.interface)) catch return VkError.OutOfHostMemory;
}

fn releasePhysicalDevices(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const physical_device = interface.physical_devices.getLast();
    try physical_device.object.releasePhysicalDevice(allocator);
    physical_device.destroy(allocator);

    interface.physical_devices.deinit(allocator);
    interface.physical_devices = .empty;
}
