const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const FlintPhysicalDevice = @import("FlintPhysicalDevice.zig");

const Dispatchable = base.Dispatchable;

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Instance;

interface: Interface,
threaded: std.Io.Threaded,
io_impl: std.Io,
allocator: std.mem.Allocator,

fn castExtension(comptime ext: vk.ApiInfo) vk.ExtensionProperties {
    var props: vk.ExtensionProperties = .{
        .extension_name = @splat(0),
        .spec_version = @bitCast(ext.version),
    };
    @memcpy(props.extension_name[0..ext.name.len], ext.name);
    return props;
}

pub const EXTENSIONS = [_]vk.ExtensionProperties{
    castExtension(vk.extensions.khr_device_group_creation),
    castExtension(vk.extensions.khr_get_physical_device_properties_2),
    castExtension(vk.extensions.khr_surface),
    castExtension(vk.extensions.khr_wayland_surface),
};

pub fn create(allocator: std.mem.Allocator, infos: *const vk.InstanceCreateInfo) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    self.allocator = std.heap.smp_allocator;
    self.threaded = std.Io.Threaded.init(self.allocator, .{});
    self.io_impl = self.threaded.io();

    self.interface = try base.Instance.init(allocator, infos);
    self.interface.dispatch_table = &.{
        .destroy = destroy,
    };

    self.interface.vtable = &.{
        .requestPhysicalDevices = requestPhysicalDevices,
        .releasePhysicalDevices = releasePhysicalDevices,
        .io = io,
    };

    return &self.interface;
}

fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.threaded.deinit();
    allocator.destroy(self);
}

fn requestPhysicalDevices(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    _ = interface;
    _ = allocator;
}

fn releasePhysicalDevices(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    _ = interface;
    _ = allocator;
}

fn io(interface: *Interface) std.Io {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    return self.io_impl;
}
