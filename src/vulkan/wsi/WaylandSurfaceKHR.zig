const std = @import("std");
const vk = @import("vulkan");

const lib = @import("../lib.zig");
const wayland = @import("clients/wayland.zig");
const PresentImage = @import("PresentImage.zig");

const VkError = @import("../error_set.zig").VkError;
const Instance = lib.Instance;

const Self = @This();
pub const Interface = @import("SurfaceKHR.zig");

const WaylandImage = struct {
    buffer: *wayland.wl_buffer,
    data: []align(std.heap.page_size_min) u8,
    width: u32,
    height: u32,
    stride: u32,
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

pub fn create(instance: *Instance, allocator: std.mem.Allocator, info: *const vk.WaylandSurfaceCreateInfoKHR) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    try wayland.load();

    var interface = try Interface.init(instance, allocator);

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

    if (self.image_map.contains(image))
        return;

    const width: u32 = image.image.extent.width;
    const height: u32 = image.image.extent.height;

    const stride: u32 = @intCast(image.image.getRowPitchMemSizeForMipLevel(.{ .color_bit = true }, 0));
    const size: usize = @as(usize, stride) * @as(usize, height);

    const wl_image = allocator.create(WaylandImage) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(wl_image);

    const fd = try createShmFile(size);
    defer _ = std.c.close(fd);

    const data = std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch return VkError.OutOfHostMemory;
    errdefer std.posix.munmap(data);

    const pool = wayland.wl_shm_create_pool(self.shm, fd, @intCast(size)) orelse return VkError.Unknown;
    defer wayland.wl_shm_pool_destroy(pool);

    const buffer = wayland.wl_shm_pool_create_buffer(pool, 0, @intCast(width), @intCast(height), @intCast(stride), wayland.WL_SHM_FORMAT_ARGB8888) orelse return VkError.Unknown;
    errdefer wayland.wl_buffer_destroy(buffer);

    wl_image.* = .{
        .buffer = buffer,
        .data = data,
        .width = width,
        .height = height,
        .stride = stride,
    };

    self.image_map.put(allocator, image, wl_image) catch return VkError.OutOfHostMemory;
}

pub fn detachImage(interface: *Interface, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const entry = self.image_map.fetchRemove(image) orelse return;
    const wl_image = entry.value;

    wayland.wl_buffer_destroy(wl_image.buffer);
    std.posix.munmap(wl_image.data);
    allocator.destroy(wl_image);
}

pub fn presentImage(interface: *Interface, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = allocator;

    const wl_image = self.image_map.get(image) orelse return VkError.Unknown;

    try image.image.copyToMemory(wl_image.data, .{
        .aspect_mask = .{ .color_bit = true },
        .mip_level = 0,
        .base_array_layer = 0,
        .layer_count = 1,
    });

    wayland.wl_surface_attach(self.surface, wl_image.buffer, 0, 0);
    wayland.wl_surface_damage(self.surface, 0, 0, @intCast(wl_image.width), @intCast(wl_image.height));
    wayland.wl_surface_commit(self.surface);

    // Better: bind wl_display_flush in wayland.zig and call it here.
    // With the currently available bindings, roundtrip forces the commit out,
    // but it is heavier than necessary.
    _ = wayland.wl_display_roundtrip(self.display);

    image.state = .Available;
}

fn createShmFile(size: usize) VkError!std.posix.fd_t {
    const name = "stroll_vk_wayland_surface";

    const fd = std.posix.memfd_create(name, std.posix.FD_CLOEXEC) catch return VkError.Unknown;
    errdefer std.c.close(fd);

    _ = std.c.ftruncate(fd, @intCast(size));

    return fd;
}
