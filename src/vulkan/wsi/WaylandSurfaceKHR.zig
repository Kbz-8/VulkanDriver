const std = @import("std");
const vk = @import("vulkan");

const lib = @import("../lib.zig");
const wayland = @import("clients/wayland.zig");
const PresentImage = @import("PresentImage.zig");

const VkError = @import("../error_set.zig").VkError;
const Device = @import("../Device.zig");

const Self = @This();
pub const Interface = @import("SurfaceKHR.zig");

const WaylandImage = struct {
    buffer: *wayland.wl_buffer,
    data: []u8,
};

fn wlRegistryHandleGlobal(data: *anyopaque, registry: *wayland.wl_registry, name: c_uint, interface: [*:0]const u8, _: c_uint) callconv(.c) void {
    const pshm: **wayland.wl_shm = @ptrCast(@alignCast(data));
    if (std.mem.eql(u8, std.mem.span(interface), "wl_shm")) {
        if (wayland.wl_registry_bind(registry, name, wayland.wl_shm_interface, 1)) |shm| {
            pshm.* = @ptrCast(@alignCast(shm));
        }
    }
}

fn wlRegistryHandleGlobalRemove(_: *anyopaque, _: *wayland.wl_registry, _: c_uint) callconv(.c) void {}

const wl_registry_listener: wayland.wl_registry_listener = .{
    .global = wlRegistryHandleGlobal,
    .global_remove = wlRegistryHandleGlobalRemove,
};

interface: Interface,
display: *wayland.wl_display,
surface: *wayland.wl_surface,
shm: *wayland.wl_shm,
image_map: std.AutoHashMapUnmanaged(*PresentImage, *WaylandImage),

pub fn create(device: *Device, allocator: std.mem.Allocator, info: *const vk.WaylandSurfaceCreateInfoKHR) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    try wayland.load();

    var interface = try Interface.init(device, allocator);

    interface.vtable = &.{
        .destroy = destroy,
        .getCapabilities = getCapabilities,
        .attachImage = attachImage,
        .detachImage = detachImage,
        .presentImage = presentImage,
    };

    self.* = .{
        .interface = interface,
        .display = info.display,
        .surface = info.surface,
        .shm = undefined,
        .image_map = .empty,
    };

    const registry = wayland.wl_display_get_registry(self.display) orelse return VkError.Unknown;
    _ = wayland.wl_registry_add_listener(registry, &wl_registry_listener, @ptrCast(&self.shm));
    _ = wayland.wl_display_dispatch(self.display);

    return &self.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.image_map.deinit(allocator);
    allocator.destroy(self);
    wayland.unload();
}

pub fn getCapabilities(interface: *const Interface, capabilities: *vk.SurfaceCapabilitiesKHR) VkError!void {
    // No-op
    _ = interface;
    _ = capabilities;
}

pub fn attachImage(interface: *Interface, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = self;
    _ = image;
    _ = allocator;
}

pub fn detachImage(interface: *Interface, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = self;
    _ = image;
    _ = allocator;
}

pub fn presentImage(interface: *Interface, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = self;
    _ = image;
    _ = allocator;
}
