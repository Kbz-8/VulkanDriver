const std = @import("std");
const vk = @import("vulkan");

const lib = @import("../lib.zig");
const xcb = @import("clients/xcb.zig");
const PresentImage = @import("PresentImage.zig");
const scale = @import("scale.zig");

const VkError = lib.VkError;
const Instance = lib.Instance;

const Self = @This();
pub const Interface = @import("SurfaceKHR.zig");

const XcbImage = struct {
    data: []u8,
    scaled_data: ?[]u8,
    width: u32,
    height: u32,
    row_size: usize,
    surface_width: u32,
    surface_height: u32,
    surface_row_size: usize,
};

interface: Interface,
connection: *xcb.Connection,
window: xcb.Window,
gc: xcb.Gcontext,
depth: u8,
maximum_image_payload: usize,
image_map: std.AutoHashMapUnmanaged(*PresentImage, *XcbImage),

pub fn supportsPresentation(connection: *vk.xcb_connection_t, visual_id: vk.xcb_visualid_t) bool {
    xcb.load() catch return false;
    defer xcb.unload();
    return xcb.supportsVisual(connection, visual_id) catch false;
}

pub fn create(instance: *Instance, allocator: std.mem.Allocator, info: *const vk.XcbSurfaceCreateInfoKHR) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    try xcb.load();
    errdefer xcb.unload();
    try xcb.checkConnection(info.connection);

    const geometry = try xcb.getGeometry(info.connection, info.window);
    if (geometry.depth != 24 and geometry.depth != 32)
        return VkError.FormatNotSupported;

    const gc = try xcb.createGc(info.connection, info.window);
    errdefer xcb.freeGc(info.connection, gc);

    var interface = try Interface.init(instance, allocator);
    interface.vtable = &.{
        .destroy = destroy,
        .getCapabilities = getCapabilities,
        .attachImage = attachImage,
        .detachImage = detachImage,
        .waitForImage = waitForImage,
        .presentImage = presentImage,
    };

    self.* = .{
        .interface = interface,
        .connection = info.connection,
        .window = info.window,
        .gc = gc,
        .depth = geometry.depth,
        .maximum_image_payload = try xcb.maximumImagePayload(info.connection),
        .image_map = .empty,
    };
    return &self.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    if (interface.swapchain) |swapchain|
        swapchain.surface = null;

    var image_iterator = self.image_map.valueIterator();
    while (image_iterator.next()) |image|
        destroyXcbImage(allocator, image.*);
    self.image_map.deinit(allocator);

    xcb.freeGc(self.connection, self.gc);
    allocator.destroy(self);
    xcb.unload();
}

pub fn getCapabilities(interface: *const Interface, capabilities: *vk.SurfaceCapabilitiesKHR) VkError!void {
    const self: *const Self = @alignCast(@fieldParentPtr("interface", interface));
    const geometry = try xcb.getGeometry(self.connection, self.window);
    capabilities.current_extent = .{ .width = geometry.width, .height = geometry.height };
    capabilities.max_image_extent = .{ .width = std.math.maxInt(i16), .height = std.math.maxInt(i16) };
}

pub fn attachImage(interface: *Interface, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    if (self.image_map.contains(image))
        return;

    const width = image.image.extent.width;
    const height = image.image.extent.height;
    const geometry = try xcb.getGeometry(self.connection, self.window);
    if (width > std.math.maxInt(i16) or height > std.math.maxInt(i16) or
        geometry.width > std.math.maxInt(i16) or geometry.height > std.math.maxInt(i16))
        return VkError.OutOfDeviceMemory;

    const row_size = std.math.mul(usize, width, 4) catch return VkError.OutOfHostMemory;
    const size = std.math.mul(usize, row_size, height) catch return VkError.OutOfHostMemory;
    const surface_row_size = std.math.mul(usize, geometry.width, 4) catch return VkError.OutOfHostMemory;
    const surface_size = std.math.mul(usize, surface_row_size, geometry.height) catch return VkError.OutOfHostMemory;

    const xcb_image = allocator.create(XcbImage) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(xcb_image);

    const data = allocator.alloc(u8, size) catch return VkError.OutOfHostMemory;
    errdefer allocator.free(data);

    const scaled_data = if (width != geometry.width or height != geometry.height)
        allocator.alloc(u8, surface_size) catch return VkError.OutOfHostMemory
    else
        null;
    errdefer if (scaled_data) |staging| allocator.free(staging);

    xcb_image.* = .{
        .data = data,
        .scaled_data = scaled_data,
        .width = width,
        .height = height,
        .row_size = row_size,
        .surface_width = geometry.width,
        .surface_height = geometry.height,
        .surface_row_size = surface_row_size,
    };
    self.image_map.put(allocator, image, xcb_image) catch return VkError.OutOfHostMemory;
}

pub fn detachImage(interface: *Interface, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const entry = self.image_map.fetchRemove(image) orelse return;
    destroyXcbImage(allocator, entry.value);
}

pub fn waitForImage(_: *Interface, _: u64) VkError!void {}

pub fn presentImage(interface: *Interface, _: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    errdefer image.state = .available;

    const xcb_image = self.image_map.get(image) orelse return VkError.Unknown;
    const geometry = try xcb.getGeometry(self.connection, self.window);
    if (geometry.width != xcb_image.surface_width or geometry.height != xcb_image.surface_height)
        return VkError.OutOfDateKhr;

    try image.image.copyToMemory(xcb_image.data, .{
        .aspect_mask = .{ .color_bit = true },
        .mip_level = 0,
        .base_array_layer = 0,
        .layer_count = 1,
    });

    if (xcb_image.scaled_data) |scaled_data|
        scale.scaleBgra8Nearest(
            xcb_image.data,
            xcb_image.width,
            xcb_image.height,
            scaled_data,
            xcb_image.surface_width,
            xcb_image.surface_height,
        ) catch return VkError.ValidationFailed;

    try xcb.putImage(
        self.connection,
        self.window,
        self.gc,
        self.depth,
        xcb_image.surface_width,
        xcb_image.surface_height,
        xcb_image.surface_row_size,
        xcb_image.scaled_data orelse xcb_image.data,
        self.maximum_image_payload,
    );
    image.state = .available;
}

fn destroyXcbImage(allocator: std.mem.Allocator, image: *XcbImage) void {
    if (image.scaled_data) |scaled_data|
        allocator.free(scaled_data);
    allocator.free(image.data);
    allocator.destroy(image);
}
