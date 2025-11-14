const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const VkError = @import("error_set.zig").VkError;
const Dispatchable = @import("Dispatchable.zig").Dispatchable;
const PhysicalDevice = @import("PhysicalDevice.zig");

const root = @import("root");

comptime {
    if (!builtin.is_test) {
        if (!@hasDecl(root, "VULKAN_VERSION")) {
            @compileError("Missing VULKAN_VERSION in module root");
        }
    }
}

const Self = @This();
pub const ObjectType: vk.ObjectType = .instance;

physical_devices: std.ArrayList(*Dispatchable(PhysicalDevice)),
dispatch_table: *const DispatchTable,
vtable: *const VTable,

pub const VTable = struct {
    releasePhysicalDevices: *const fn (*Self, std.mem.Allocator) VkError!void,
    requestPhysicalDevices: *const fn (*Self, std.mem.Allocator) VkError!void,
};

pub const DispatchTable = struct {
    destroyInstance: *const fn (*Self, std.mem.Allocator) VkError!void,
};

pub fn init(allocator: std.mem.Allocator, infos: *const vk.InstanceCreateInfo) VkError!Self {
    _ = allocator;
    _ = infos;
    return .{
        .physical_devices = .empty,
        .dispatch_table = undefined,
        .vtable = undefined,
    };
}

// Dummy for docs creation and stuff
pub fn create(allocator: std.mem.Allocator, infos: *const vk.InstanceCreateInfo) VkError!*Self {
    _ = allocator;
    _ = infos;
    return VkError.IncompatibleDriver;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) VkError!void {
    try self.releasePhysicalDevices(allocator);
    try self.dispatch_table.destroyInstance(self, allocator);
}

pub fn enumerateExtensionProperties(layer_name: ?[]const u8, property_count: *u32, properties: ?*vk.ExtensionProperties) VkError!void {
    if (layer_name) |_| {
        return VkError.LayerNotPresent;
    }

    _ = properties;
    _ = std.StaticStringMap(vk.ExtensionProperties).initComptime(.{});

    property_count.* = 0;
}

pub fn enumerateVersion(version: *u32) VkError!void {
    if (!builtin.is_test) {
        version.* = @bitCast(root.VULKAN_VERSION);
    } else {
        version.* = @bitCast(vk.makeApiVersion(0, 1, 0, 0));
    }
}

pub fn releasePhysicalDevices(self: *Self, allocator: std.mem.Allocator) VkError!void {
    try self.vtable.releasePhysicalDevices(self, allocator);
}

pub fn requestPhysicalDevices(self: *Self, allocator: std.mem.Allocator) VkError!void {
    try self.vtable.requestPhysicalDevices(self, allocator);
    if (self.physical_devices.items.len == 0) {
        std.log.scoped(.vkCreateInstance).info("No VkPhysicalDevice found", .{});
        return;
    }
    for (self.physical_devices.items) |physical_device| {
        std.log.scoped(.vkCreateInstance).info("Found VkPhysicalDevice named {s}", .{physical_device.object.props.device_name});
    }
}
