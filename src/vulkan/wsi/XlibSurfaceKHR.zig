const std = @import("std");
const vk = @import("vulkan");

const lib = @import("../lib.zig");
const xlib = @import("clients/xlib.zig");
const PresentImage = @import("PresentImage.zig");
const scale = @import("scale.zig");

const VkError = lib.VkError;
const Instance = lib.Instance;

const Self = @This();
pub const Interface = @import("SurfaceKHR.zig");

const XlibImage = struct {
    image: *xlib.XImage,
    data: []u8,
    scaled_data: ?[]u8,
    width: u32,
    height: u32,
    surface_width: u32,
    surface_height: u32,
};

interface: Interface,
display: *xlib.Display,
window: xlib.Window,
gc: *xlib.GC,
visual: *xlib.Visual,
depth: u32,
image_map: std.AutoHashMapUnmanaged(*PresentImage, *XlibImage),

pub fn supportsPresentation(display: *vk.Display, visual_id: vk.VisualID) bool {
    xlib.load() catch return false;
    defer xlib.unload();
    return xlib.supportsVisual(display, visual_id);
}

pub fn create(instance: *Instance, allocator: std.mem.Allocator, info: *const vk.XlibSurfaceCreateInfoKHR) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    try xlib.load();
    errdefer xlib.unload();

    const geometry = try xlib.getGeometry(info.dpy, info.window);
    if (geometry.depth != 24 and geometry.depth != 32)
        return VkError.FormatNotSupported;

    const gc = try xlib.createGc(info.dpy, info.window);
    errdefer xlib.freeGc(info.dpy, gc);

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
        .display = info.dpy,
        .window = info.window,
        .gc = gc,
        .visual = geometry.visual,
        .depth = geometry.depth,
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
        destroyXlibImage(allocator, image.*);
    self.image_map.deinit(allocator);

    xlib.freeGc(self.display, self.gc);
    allocator.destroy(self);
    xlib.unload();
}

pub fn getCapabilities(interface: *const Interface, capabilities: *vk.SurfaceCapabilitiesKHR) VkError!void {
    const self: *const Self = @alignCast(@fieldParentPtr("interface", interface));
    const geometry = try xlib.getGeometry(self.display, self.window);
    capabilities.current_extent = .{ .width = geometry.width, .height = geometry.height };
    capabilities.max_image_extent = .{ .width = std.math.maxInt(u16), .height = std.math.maxInt(u16) };
}

pub fn attachImage(interface: *Interface, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    if (self.image_map.contains(image))
        return;

    const width = image.image.extent.width;
    const height = image.image.extent.height;
    const geometry = try xlib.getGeometry(self.display, self.window);
    if (width > std.math.maxInt(u16) or height > std.math.maxInt(u16) or
        geometry.width > std.math.maxInt(u16) or geometry.height > std.math.maxInt(u16))
        return VkError.OutOfDeviceMemory;

    const row_size = std.math.mul(usize, width, 4) catch return VkError.OutOfHostMemory;
    const size = std.math.mul(usize, row_size, height) catch return VkError.OutOfHostMemory;
    const surface_row_size = std.math.mul(usize, geometry.width, 4) catch return VkError.OutOfHostMemory;
    const surface_size = std.math.mul(usize, surface_row_size, geometry.height) catch return VkError.OutOfHostMemory;

    const xlib_image = allocator.create(XlibImage) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(xlib_image);

    const data = allocator.alloc(u8, size) catch return VkError.OutOfHostMemory;
    errdefer allocator.free(data);

    const scaled_data = if (width != geometry.width or height != geometry.height)
        allocator.alloc(u8, surface_size) catch return VkError.OutOfHostMemory
    else
        null;
    errdefer if (scaled_data) |staging| allocator.free(staging);

    const native_data = scaled_data orelse data;
    const native_image = try xlib.createImage(
        self.display,
        self.visual,
        self.depth,
        geometry.width,
        geometry.height,
        surface_row_size,
        native_data,
    );
    errdefer xlib.destroyImage(native_image);

    xlib_image.* = .{
        .image = native_image,
        .data = data,
        .scaled_data = scaled_data,
        .width = width,
        .height = height,
        .surface_width = geometry.width,
        .surface_height = geometry.height,
    };
    self.image_map.put(allocator, image, xlib_image) catch return VkError.OutOfHostMemory;
}

pub fn detachImage(interface: *Interface, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const entry = self.image_map.fetchRemove(image) orelse return;
    destroyXlibImage(allocator, entry.value);
}

pub fn waitForImage(_: *Interface, _: u64) VkError!void {}

pub fn presentImage(interface: *Interface, _: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    errdefer image.state = .available;

    const xlib_image = self.image_map.get(image) orelse return VkError.Unknown;
    const geometry = try xlib.getGeometry(self.display, self.window);
    if (geometry.width != xlib_image.surface_width or geometry.height != xlib_image.surface_height)
        return VkError.OutOfDateKhr;

    try image.image.copyToMemory(xlib_image.data, .{
        .aspect_mask = .{ .color_bit = true },
        .mip_level = 0,
        .base_array_layer = 0,
        .layer_count = 1,
    });

    if (xlib_image.scaled_data) |scaled_data|
        scale.scaleBgra8Nearest(
            xlib_image.data,
            xlib_image.width,
            xlib_image.height,
            scaled_data,
            xlib_image.surface_width,
            xlib_image.surface_height,
        ) catch return VkError.ValidationFailed;

    xlib.putImage(self.display, self.window, self.gc, xlib_image.image, xlib_image.surface_width, xlib_image.surface_height);
    image.state = .available;
}

fn destroyXlibImage(allocator: std.mem.Allocator, image: *XlibImage) void {
    xlib.destroyImage(image.image);
    if (image.scaled_data) |scaled_data|
        allocator.free(scaled_data);
    allocator.free(image.data);
    allocator.destroy(image);
}
