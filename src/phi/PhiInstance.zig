const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("lib.zig");
const mic = lib.mic;

const PhiPhysicalDevice = @import("PhiPhysicalDevice.zig");

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

    mic.unload();
}

fn requestPhysicalDevices(interface: *Interface, allocator: std.mem.Allocator, _: []base.drm.Card) VkError!void {
    if (interface.physical_devices.items.len != 0) {
        return;
    }

    mic.load() catch |err| {
        std.log.scoped(.MIC).err("Failed to load libmicmgmt: {s}", .{@errorName(err)});
        return VkError.InitializationFailed;
    };

    var devices = mic.DeviceList.init() catch |err| {
        std.log.scoped(.MIC).err("Failed to create device list: {s}", .{@errorName(err)});
        return VkError.InitializationFailed;
    };
    defer devices.deinit();

    const count = devices.count() catch |err| {
        std.log.scoped(.MIC).err("Failed to fetch device list count: {s}", .{@errorName(err)});
        return VkError.InitializationFailed;
    };

    for (0..count) |index| {
        const device_num = devices.deviceAtIndex(index) catch |err| {
            std.log.scoped(.MIC).err("Failed to fetch device: {s}", .{@errorName(err)});
            continue;
        };

        var device = mic.Device.open(device_num) catch |err| {
            std.log.scoped(.MIC).err("Failed to open device {d}: {s}", .{ device_num, @errorName(err) });
            continue;
        };
        defer device.deinit();

        const physical_device = try PhiPhysicalDevice.create(allocator, interface, device, device_num);
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
