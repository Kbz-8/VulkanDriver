const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const utils = @import("utils.zig");
const drm = @import("drm.zig");
const lib = @import("lib.zig");

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

/// Dummy
pub const EXTENSIONS = [_]vk.ExtensionProperties{};

physical_devices: std.ArrayList(*Dispatchable(PhysicalDevice)),

dispatch_table: *const DispatchTable,
vtable: *const VTable,

pub const VTable = struct {
    releasePhysicalDevices: *const fn (*Self, std.mem.Allocator) VkError!void,
    requestPhysicalDevices: *const fn (*Self, std.mem.Allocator, []lib.drm.Card) VkError!void,
    io: *const fn (*Self) std.Io,
};

pub const DispatchTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) VkError!void,
};

pub fn init(allocator: std.mem.Allocator, infos: *const vk.InstanceCreateInfo) VkError!Self {
    _ = allocator;
    _ = infos;
    return .{
        .physical_devices = .empty,
        // SAFETY: the backend assigns both tables before returning the instance.
        .dispatch_table = undefined,
        // SAFETY: the backend assigns both tables before returning the instance.
        .vtable = undefined,
    };
}

pub fn validateCreateInfo(info: *const vk.InstanceCreateInfo) VkError!void {
    if (info.p_application_info) |application_info| {
        const requested: vk.Version = @bitCast(application_info.api_version);
        const supported: vk.Version = if (comptime builtin.is_test)
            vk.API_VERSION_1_0
        else
            @bitCast(root.VULKAN_VERSION);
        if (requested.variant != 0 or requested.major > supported.major or (requested.major == supported.major and requested.minor > supported.minor)) {
            return VkError.IncompatibleDriver;
        }
    }

    if (info.enabled_layer_count != 0) {
        const names = info.pp_enabled_layer_names orelse return VkError.LayerNotPresent;
        for (0..info.enabled_layer_count) |i| {
            _ = utils.boundedName(names[i], vk.MAX_EXTENSION_NAME_SIZE) orelse return VkError.LayerNotPresent;
            return VkError.LayerNotPresent;
        }
    }

    if (info.enabled_extension_count != 0) {
        const names = info.pp_enabled_extension_names orelse return VkError.ExtensionNotPresent;

        const supported_extensions = if (comptime !@hasDecl(root, "Instance"))
            &[_]vk.ExtensionProperties{}
        else
            root.Instance.EXTENSIONS[0..];

        for (0..info.enabled_extension_count) |i| {
            const name = utils.boundedName(names[i], vk.MAX_EXTENSION_NAME_SIZE) orelse return VkError.ExtensionNotPresent;
            if (!utils.isSupportedExtension(name, supported_extensions)) {
                return VkError.ExtensionNotPresent;
            }
        }
    }
}

/// Dummy to avoid compile error in tests and doc generation
pub fn create(allocator: std.mem.Allocator, infos: *const vk.InstanceCreateInfo) VkError!*Self {
    _ = allocator;
    _ = infos;
    return VkError.IncompatibleDriver;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) VkError!void {
    try self.releasePhysicalDevices(allocator);
    try self.dispatch_table.destroy(self, allocator);
}

pub fn enumerateLayerProperties(count: *u32, p_properties: ?[*]vk.LayerProperties) VkError!void {
    if (comptime !builtin.is_test and @hasDecl(root.Instance, "LAYERS")) {
        const available = root.Instance.LAYERS.len;
        if (p_properties) |properties| {
            const write_count = @min(count.*, available);
            for (root.Instance.LAYERS[0..write_count], properties[0..write_count]) |layer, *prop| {
                prop.* = layer;
            }
            count.* = @intCast(write_count);
            if (write_count < available) return VkError.Incomplete;
        } else {
            count.* = @intCast(available);
        }
    } else {
        count.* = 0;
    }
}

pub fn enumerateExtensionProperties(layer_name: ?[]const u8, count: *u32, p_properties: ?[*]vk.ExtensionProperties) VkError!void {
    if (layer_name) |_| {
        return VkError.LayerNotPresent;
    }

    if (comptime !builtin.is_test and @hasDecl(root.Instance, "EXTENSIONS")) {
        const available = root.Instance.EXTENSIONS.len;
        if (p_properties) |properties| {
            const write_count = @min(count.*, available);
            for (root.Instance.EXTENSIONS[0..write_count], properties[0..write_count]) |ext, *prop| {
                prop.* = ext;
            }
            count.* = @intCast(write_count);
            if (write_count < available) return VkError.Incomplete;
        } else {
            count.* = @intCast(available);
        }
    } else {
        count.* = 0;
    }
}

pub fn enumerateVersion(version: *u32) VkError!void {
    if (comptime builtin.is_test) {
        version.* = @bitCast(vk.makeApiVersion(0, 1, 0, 0));
    } else {
        version.* = @bitCast(root.VULKAN_VERSION);
    }
}

pub fn releasePhysicalDevices(self: *Self, allocator: std.mem.Allocator) VkError!void {
    try self.vtable.releasePhysicalDevices(self, allocator);
}

pub fn requestPhysicalDevices(self: *Self, allocator: std.mem.Allocator) VkError!void {
    const devices = try drm.enumerateDrmPhysicalDevices(allocator, self);
    defer allocator.free(devices);

    try self.vtable.requestPhysicalDevices(self, allocator, devices);

    if (self.physical_devices.items.len == 0) {
        std.log.scoped(.vkCreateInstance).err("No VkPhysicalDevice found", .{});
        return;
    }

    for (self.physical_devices.items) |physical_device| {
        std.log.scoped(.vkCreateInstance).debug("Found VkPhysicalDevice named {s}", .{physical_device.object.props.device_name});
    }
}

pub fn io(self: *Self) std.Io {
    return self.vtable.io(self);
}
