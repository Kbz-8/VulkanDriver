const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("lib.zig");

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

pub const extensions = [_]vk.ExtensionProperties{
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

fn requestPhysicalDevices(interface: *Interface, allocator: std.mem.Allocator, devices: []base.drm.Card) VkError!void {
    if (interface.physical_devices.items.len != 0) {
        return;
    }

    const io_var = interface.io();

    for (devices[0..]) |device| {
        const drm_device = device.getDevice(io_var, allocator, .{}) catch continue;

        if (drm_device.node_type != .render or
            std.meta.activeTag(drm_device.device_info) != .pci or
            drm_device.device_info.pci.vendor_id != lib.intel_pci_vendor_id)
            continue;

        const version = device.getVersion(io_var, allocator) catch continue;
        defer version.deinit(allocator);

        const kmd_type: lib.KmdType = if (std.mem.eql(u8, version.name, "i915"))
            .i915
        else if (std.mem.eql(u8, version.name, "xe"))
            .xe
        else
            .invalid;

        if (kmd_type == .invalid)
            continue;

        const physical_device = try FlintPhysicalDevice.create(allocator, interface, &drm_device, kmd_type);
        errdefer physical_device.interface.release(allocator) catch @panic("Caught an error while handling an error");

        const dispatchable = try Dispatchable(base.PhysicalDevice).wrap(allocator, &physical_device.interface);
        errdefer dispatchable.destroy(allocator);

        interface.physical_devices.append(allocator, dispatchable) catch return VkError.OutOfHostMemory;
    }
}

fn releasePhysicalDevices(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    var result: ?VkError = null;

    for (interface.physical_devices.items) |physical_device| {
        physical_device.object.release(allocator) catch |err| {
            if (result == null) {
                result = err;
            }
        };
        physical_device.destroy(allocator);
    }

    interface.physical_devices.deinit(allocator);
    interface.physical_devices = .empty;

    if (result) |err| {
        return err;
    }
}

fn io(interface: *Interface) std.Io {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    return self.io_impl;
}

fn mapDeviceEnumerationError(err: anyerror) VkError {
    return switch (err) {
        error.OutOfMemory => VkError.OutOfHostMemory,
        else => VkError.InitializationFailed,
    };
}
