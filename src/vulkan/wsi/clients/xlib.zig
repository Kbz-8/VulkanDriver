//! Minimal dynamically loaded Xlib client used by the Xlib WSI backend.

const std = @import("std");
const vk = @import("vulkan");
const lib = @import("../../lib.zig");

const VkError = lib.VkError;

pub const Display = vk.Display;
pub const Window = vk.Window;
pub const Drawable = c_ulong;
pub const Visual = opaque {};
pub const Screen = opaque {};
pub const GC = opaque {};

const z_pixmap: c_int = 2;
const lsb_first: c_int = 0;
const visual_id_mask: c_long = 0x1;

pub const XImage = extern struct {
    width: c_int,
    height: c_int,
    xoffset: c_int,
    format: c_int,
    data: [*c]u8,
    byte_order: c_int,
    bitmap_unit: c_int,
    bitmap_bit_order: c_int,
    bitmap_pad: c_int,
    depth: c_int,
    bytes_per_line: c_int,
    bits_per_pixel: c_int,
    red_mask: c_ulong,
    green_mask: c_ulong,
    blue_mask: c_ulong,
    obdata: ?*anyopaque,
    f: extern struct {
        create_image: ?*const fn (*Display, *Visual, c_uint, c_int, c_int, [*c]u8, c_uint, c_uint, c_int, c_int) callconv(.c) ?*XImage,
        destroy_image: *const fn (*XImage) callconv(.c) c_int,
        get_pixel: ?*const fn (*XImage, c_int, c_int) callconv(.c) c_ulong,
        put_pixel: ?*const fn (*XImage, c_int, c_int, c_ulong) callconv(.c) c_int,
        sub_image: ?*const fn (*XImage, c_int, c_int, c_uint, c_uint) callconv(.c) ?*XImage,
        add_pixel: ?*const fn (*XImage, c_long) callconv(.c) c_int,
    },
};

const VisualInfo = extern struct {
    visual: *Visual,
    visualid: c_ulong,
    screen: c_int,
    depth: c_int,
    class: c_int,
    red_mask: c_ulong,
    green_mask: c_ulong,
    blue_mask: c_ulong,
    colormap_size: c_int,
    bits_per_rgb: c_int,
};

const WindowAttributes = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    depth: c_int,
    visual: *Visual,
    root: Window,
    class: c_int,
    bit_gravity: c_int,
    win_gravity: c_int,
    backing_store: c_int,
    backing_planes: c_ulong,
    backing_pixel: c_ulong,
    save_under: c_int,
    colormap: c_ulong,
    map_installed: c_int,
    map_state: c_int,
    all_event_masks: c_long,
    your_event_mask: c_long,
    do_not_propagate_mask: c_long,
    override_redirect: c_int,
    screen: *Screen,
};

pub const Geometry = struct {
    width: u32,
    height: u32,
    depth: u32,
    visual: *Visual,
};

// SAFETY: load assigns every function pointer before any helper is used.
var XCreateGC: *const fn (*Display, Drawable, c_ulong, ?*anyopaque) callconv(.c) ?*GC = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var XCreateImage: *const fn (*Display, *Visual, c_uint, c_int, c_int, [*c]u8, c_uint, c_uint, c_int, c_int) callconv(.c) ?*XImage = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var XFlush: *const fn (*Display) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var XFree: *const fn (?*anyopaque) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var XFreeGC: *const fn (*Display, *GC) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var XGetVisualInfo: *const fn (*Display, c_long, *VisualInfo, *c_int) callconv(.c) ?[*]VisualInfo = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var XGetWindowAttributes: *const fn (*Display, Window, *WindowAttributes) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var XPutImage: *const fn (*Display, Drawable, *GC, *XImage, c_int, c_int, c_int, c_int, c_uint, c_uint) callconv(.c) c_int = undefined;

// SAFETY: load initializes the module before it can be closed.
var module: std.DynLib = undefined;
var ref_count = std.atomic.Value(usize).init(0);
var load_mutex: lib.SpinMutex = .{};

pub fn load() VkError!void {
    load_mutex.lock();
    defer load_mutex.unlock();

    if (ref_count.load(.monotonic) != 0) {
        _ = ref_count.fetchAdd(1, .monotonic);
        return;
    }

    module = std.DynLib.open("libX11.so.6") catch {
        std.log.scoped(.XlibClient).err("Could not open 'libX11.so.6'", .{});
        return VkError.InitializationFailed;
    };
    errdefer module.close();

    XCreateGC = module.lookup(@TypeOf(XCreateGC), "XCreateGC") orelse return VkError.InitializationFailed;
    XCreateImage = module.lookup(@TypeOf(XCreateImage), "XCreateImage") orelse return VkError.InitializationFailed;
    XFlush = module.lookup(@TypeOf(XFlush), "XFlush") orelse return VkError.InitializationFailed;
    XFree = module.lookup(@TypeOf(XFree), "XFree") orelse return VkError.InitializationFailed;
    XFreeGC = module.lookup(@TypeOf(XFreeGC), "XFreeGC") orelse return VkError.InitializationFailed;
    XGetVisualInfo = module.lookup(@TypeOf(XGetVisualInfo), "XGetVisualInfo") orelse return VkError.InitializationFailed;
    XGetWindowAttributes = module.lookup(@TypeOf(XGetWindowAttributes), "XGetWindowAttributes") orelse return VkError.InitializationFailed;
    XPutImage = module.lookup(@TypeOf(XPutImage), "XPutImage") orelse return VkError.InitializationFailed;

    _ = ref_count.fetchAdd(1, .monotonic);
    std.log.scoped(.XlibClient).debug("Loaded Xlib client", .{});
}

pub fn unload() void {
    load_mutex.lock();
    defer load_mutex.unlock();

    if (ref_count.fetchSub(1, .release) == 1) {
        module.close();
        std.log.scoped(.XlibClient).debug("Unloaded Xlib client", .{});
    }
}

pub fn supportsVisual(display: *Display, visual_id: vk.VisualID) bool {
    var template = std.mem.zeroes(VisualInfo);
    template.visualid = visual_id;

    var visual_count: c_int = 0;
    const visual_infos = XGetVisualInfo(display, visual_id_mask, &template, &visual_count) orelse return false;
    defer _ = XFree(@ptrCast(visual_infos));
    if (visual_count <= 0)
        return false;

    for (visual_infos[0..@intCast(visual_count)]) |visual_info| {
        if ((visual_info.depth == 24 or visual_info.depth == 32) and
            visual_info.red_mask == 0x00ff_0000 and
            visual_info.green_mask == 0x0000_ff00 and
            visual_info.blue_mask == 0x0000_00ff)
            return true;
    }

    return false;
}

pub fn getGeometry(display: *Display, window: Window) VkError!Geometry {
    // SAFETY: will be overwritten by XGetWindowAttributes
    var attributes: WindowAttributes = undefined;
    if (XGetWindowAttributes(display, window, &attributes) == 0)
        return VkError.SurfaceLostKhr;
    if (attributes.width <= 0 or attributes.height <= 0 or attributes.depth <= 0)
        return VkError.SurfaceLostKhr;

    return .{
        .width = @intCast(attributes.width),
        .height = @intCast(attributes.height),
        .depth = @intCast(attributes.depth),
        .visual = attributes.visual,
    };
}

pub fn createGc(display: *Display, drawable: Drawable) VkError!*GC {
    return XCreateGC(display, drawable, 0, null) orelse VkError.OutOfHostMemory;
}

pub fn freeGc(display: *Display, gc: *GC) void {
    _ = XFreeGC(display, gc);
}

pub fn createImage(display: *Display, visual: *Visual, depth: u32, width: u32, height: u32, row_size: usize, data: []u8) VkError!*XImage {
    const bytes_per_line = std.math.cast(c_int, row_size) orelse return VkError.OutOfHostMemory;
    const image = XCreateImage(display, visual, depth, z_pixmap, 0, data.ptr, width, height, 32, bytes_per_line) orelse return VkError.OutOfHostMemory;
    errdefer destroyImage(image);

    if (image.byte_order != lsb_first or
        image.bits_per_pixel != 32 or
        image.bytes_per_line != bytes_per_line or
        image.red_mask != 0x00ff_0000 or
        image.green_mask != 0x0000_ff00 or
        image.blue_mask != 0x0000_00ff)
        return VkError.FormatNotSupported;

    return image;
}

pub fn destroyImage(image: *XImage) void {
    image.data = null;
    _ = image.f.destroy_image(image);
}

pub fn putImage(display: *Display, drawable: Drawable, gc: *GC, image: *XImage, width: u32, height: u32) void {
    _ = XPutImage(display, drawable, gc, image, 0, 0, 0, 0, width, height);
    _ = XFlush(display);
}
