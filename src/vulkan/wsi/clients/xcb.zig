//! Minimal dynamically loaded XCB client used by the XCB WSI backend.

const std = @import("std");
const vk = @import("vulkan");
const lib = @import("../../lib.zig");

const VkError = lib.VkError;

pub const Connection = vk.xcb_connection_t;
pub const Window = vk.xcb_window_t;
pub const Drawable = u32;
pub const Gcontext = u32;

const z_pixmap: u8 = 2;
const put_image_request_size: u32 = 24;

const VoidCookie = extern struct {
    sequence: c_uint,
};

const GetGeometryCookie = extern struct {
    sequence: c_uint,
};

const GenericError = opaque {};
const Setup = opaque {};
const Screen = opaque {};

const Depth = extern struct {
    depth: u8,
    pad0: u8,
    visuals_len: u16,
    pad1: [4]u8,
};

const Format = extern struct {
    depth: u8,
    bits_per_pixel: u8,
    scanline_pad: u8,
    pad0: [5]u8,
};

const VisualType = extern struct {
    visual_id: vk.xcb_visualid_t,
    class: u8,
    bits_per_rgb_value: u8,
    colormap_entries: u16,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
    pad0: [4]u8,
};

const DepthIterator = extern struct {
    data: ?*Depth,
    rem: c_int,
    index: c_int,
};

const FormatIterator = extern struct {
    data: ?*Format,
    rem: c_int,
    index: c_int,
};

const ScreenIterator = extern struct {
    data: ?*Screen,
    rem: c_int,
    index: c_int,
};

const VisualTypeIterator = extern struct {
    data: ?*VisualType,
    rem: c_int,
    index: c_int,
};

const GetGeometryReply = extern struct {
    response_type: u8,
    depth: u8,
    sequence: u16,
    length: u32,
    root: Window,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
    pad0: [2]u8,
};

pub const Geometry = struct {
    width: u32,
    height: u32,
    depth: u8,
};

// SAFETY: load assigns every function pointer before any helper is used.
var xcb_connection_has_error: *const fn (*Connection) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_create_gc_checked: *const fn (*Connection, Gcontext, Drawable, u32, ?*const anyopaque) callconv(.c) VoidCookie = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_depth_next: *const fn (*DepthIterator) callconv(.c) void = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_depth_visuals_iterator: *const fn (*const Depth) callconv(.c) VisualTypeIterator = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_flush: *const fn (*Connection) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_format_next: *const fn (*FormatIterator) callconv(.c) void = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_free_gc: *const fn (*Connection, Gcontext) callconv(.c) VoidCookie = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_generate_id: *const fn (*Connection) callconv(.c) u32 = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_get_geometry: *const fn (*Connection, Drawable) callconv(.c) GetGeometryCookie = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_get_geometry_reply: *const fn (*Connection, GetGeometryCookie, *?*GenericError) callconv(.c) ?*GetGeometryReply = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_get_maximum_request_length: *const fn (*Connection) callconv(.c) u32 = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_get_setup: *const fn (*Connection) callconv(.c) ?*const Setup = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_put_image: *const fn (*Connection, u8, Drawable, Gcontext, u16, u16, i16, i16, u8, u8, u32, [*]const u8) callconv(.c) VoidCookie = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_request_check: *const fn (*Connection, VoidCookie) callconv(.c) ?*GenericError = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_screen_allowed_depths_iterator: *const fn (*const Screen) callconv(.c) DepthIterator = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_screen_next: *const fn (*ScreenIterator) callconv(.c) void = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_setup_pixmap_formats_iterator: *const fn (*const Setup) callconv(.c) FormatIterator = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_setup_roots_iterator: *const fn (*const Setup) callconv(.c) ScreenIterator = undefined;
// SAFETY: load assigns every function pointer before any helper is used.
var xcb_visualtype_next: *const fn (*VisualTypeIterator) callconv(.c) void = undefined;

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

    module = std.DynLib.open("libxcb.so.1") catch {
        std.log.scoped(.XcbClient).err("Could not open 'libxcb.so.1'", .{});
        return VkError.InitializationFailed;
    };
    errdefer module.close();

    xcb_connection_has_error = module.lookup(@TypeOf(xcb_connection_has_error), "xcb_connection_has_error") orelse return VkError.InitializationFailed;
    xcb_create_gc_checked = module.lookup(@TypeOf(xcb_create_gc_checked), "xcb_create_gc_checked") orelse return VkError.InitializationFailed;
    xcb_depth_next = module.lookup(@TypeOf(xcb_depth_next), "xcb_depth_next") orelse return VkError.InitializationFailed;
    xcb_depth_visuals_iterator = module.lookup(@TypeOf(xcb_depth_visuals_iterator), "xcb_depth_visuals_iterator") orelse return VkError.InitializationFailed;
    xcb_flush = module.lookup(@TypeOf(xcb_flush), "xcb_flush") orelse return VkError.InitializationFailed;
    xcb_format_next = module.lookup(@TypeOf(xcb_format_next), "xcb_format_next") orelse return VkError.InitializationFailed;
    xcb_free_gc = module.lookup(@TypeOf(xcb_free_gc), "xcb_free_gc") orelse return VkError.InitializationFailed;
    xcb_generate_id = module.lookup(@TypeOf(xcb_generate_id), "xcb_generate_id") orelse return VkError.InitializationFailed;
    xcb_get_geometry = module.lookup(@TypeOf(xcb_get_geometry), "xcb_get_geometry") orelse return VkError.InitializationFailed;
    xcb_get_geometry_reply = module.lookup(@TypeOf(xcb_get_geometry_reply), "xcb_get_geometry_reply") orelse return VkError.InitializationFailed;
    xcb_get_maximum_request_length = module.lookup(@TypeOf(xcb_get_maximum_request_length), "xcb_get_maximum_request_length") orelse return VkError.InitializationFailed;
    xcb_get_setup = module.lookup(@TypeOf(xcb_get_setup), "xcb_get_setup") orelse return VkError.InitializationFailed;
    xcb_put_image = module.lookup(@TypeOf(xcb_put_image), "xcb_put_image") orelse return VkError.InitializationFailed;
    xcb_request_check = module.lookup(@TypeOf(xcb_request_check), "xcb_request_check") orelse return VkError.InitializationFailed;
    xcb_screen_allowed_depths_iterator = module.lookup(@TypeOf(xcb_screen_allowed_depths_iterator), "xcb_screen_allowed_depths_iterator") orelse return VkError.InitializationFailed;
    xcb_screen_next = module.lookup(@TypeOf(xcb_screen_next), "xcb_screen_next") orelse return VkError.InitializationFailed;
    xcb_setup_pixmap_formats_iterator = module.lookup(@TypeOf(xcb_setup_pixmap_formats_iterator), "xcb_setup_pixmap_formats_iterator") orelse return VkError.InitializationFailed;
    xcb_setup_roots_iterator = module.lookup(@TypeOf(xcb_setup_roots_iterator), "xcb_setup_roots_iterator") orelse return VkError.InitializationFailed;
    xcb_visualtype_next = module.lookup(@TypeOf(xcb_visualtype_next), "xcb_visualtype_next") orelse return VkError.InitializationFailed;

    _ = ref_count.fetchAdd(1, .monotonic);
    std.log.scoped(.XcbClient).debug("Loaded XCB client", .{});
}

pub fn unload() void {
    load_mutex.lock();
    defer load_mutex.unlock();

    if (ref_count.fetchSub(1, .release) == 1) {
        module.close();
        std.log.scoped(.XcbClient).debug("Unloaded XCB client", .{});
    }
}

pub fn checkConnection(connection: *Connection) VkError!void {
    if (xcb_connection_has_error(connection) != 0)
        return VkError.SurfaceLostKhr;
}

pub fn supportsVisual(connection: *Connection, visual_id: vk.xcb_visualid_t) VkError!bool {
    try checkConnection(connection);
    const setup = xcb_get_setup(connection) orelse return false;

    var screen_iterator = xcb_setup_roots_iterator(setup);
    while (screen_iterator.rem > 0) : (xcb_screen_next(&screen_iterator)) {
        const screen = screen_iterator.data orelse break;
        var depth_iterator = xcb_screen_allowed_depths_iterator(screen);
        while (depth_iterator.rem > 0) : (xcb_depth_next(&depth_iterator)) {
            const depth = depth_iterator.data orelse break;
            var visual_iterator = xcb_depth_visuals_iterator(depth);
            while (visual_iterator.rem > 0) : (xcb_visualtype_next(&visual_iterator)) {
                const visual = visual_iterator.data orelse break;
                if (visual.visual_id != visual_id)
                    continue;

                if ((depth.depth != 24 and depth.depth != 32) or
                    visual.red_mask != 0x00ff_0000 or
                    visual.green_mask != 0x0000_ff00 or
                    visual.blue_mask != 0x0000_00ff)
                    return false;

                var format_iterator = xcb_setup_pixmap_formats_iterator(setup);
                while (format_iterator.rem > 0) : (xcb_format_next(&format_iterator)) {
                    const format = format_iterator.data orelse break;
                    if (format.depth == depth.depth and
                        format.bits_per_pixel == 32 and
                        format.scanline_pad != 0 and
                        32 % format.scanline_pad == 0)
                        return true;
                }
                return false;
            }
        }
    }

    return false;
}

pub fn getGeometry(connection: *Connection, drawable: Drawable) VkError!Geometry {
    try checkConnection(connection);

    var protocol_error: ?*GenericError = null;
    const reply = xcb_get_geometry_reply(connection, xcb_get_geometry(connection, drawable), &protocol_error) orelse {
        if (protocol_error) |err| std.c.free(err);
        return VkError.SurfaceLostKhr;
    };
    defer std.c.free(reply);
    if (protocol_error) |err| {
        std.c.free(err);
        return VkError.SurfaceLostKhr;
    }

    return .{ .width = reply.width, .height = reply.height, .depth = reply.depth };
}

pub fn createGc(connection: *Connection, drawable: Drawable) VkError!Gcontext {
    const gc = xcb_generate_id(connection);
    if (gc == std.math.maxInt(u32))
        return VkError.OutOfHostMemory;

    const error_reply = xcb_request_check(connection, xcb_create_gc_checked(connection, gc, drawable, 0, null));
    if (error_reply) |err| {
        std.c.free(err);
        return VkError.SurfaceLostKhr;
    }
    return gc;
}

pub fn freeGc(connection: *Connection, gc: Gcontext) void {
    _ = xcb_free_gc(connection, gc);
    _ = xcb_flush(connection);
}

pub fn maximumImagePayload(connection: *Connection) VkError!usize {
    const request_units = xcb_get_maximum_request_length(connection);
    const request_bytes = std.math.mul(u32, request_units, 4) catch return VkError.OutOfHostMemory;
    if (request_bytes <= put_image_request_size + 4)
        return VkError.InitializationFailed;
    return request_bytes - put_image_request_size;
}

pub fn putImage(connection: *Connection, drawable: Drawable, gc: Gcontext, depth: u8, width: u32, height: u32, row_size: usize, data: []const u8, maximum_payload: usize) VkError!void {
    try checkConnection(connection);

    const protocol_width = std.math.cast(u16, width) orelse return VkError.OutOfDeviceMemory;
    const protocol_height = std.math.cast(u16, height) orelse return VkError.OutOfDeviceMemory;
    const required_size = std.math.mul(usize, row_size, height) catch return VkError.OutOfHostMemory;
    if (data.len < required_size or row_size != @as(usize, width) * 4 or maximum_payload < 4)
        return VkError.ValidationFailed;

    if (row_size <= maximum_payload) {
        const rows_per_request = @max(@as(usize, 1), @min(maximum_payload / row_size, std.math.maxInt(u16)));
        var y: usize = 0;
        while (y < protocol_height) {
            const row_count = @min(rows_per_request, @as(usize, protocol_height) - y);
            const offset = y * row_size;
            const byte_count = row_count * row_size;
            _ = xcb_put_image(
                connection,
                z_pixmap,
                drawable,
                gc,
                protocol_width,
                @intCast(row_count),
                0,
                @intCast(y),
                0,
                depth,
                @intCast(byte_count),
                data[offset..][0..byte_count].ptr,
            );
            y += row_count;
        }
    } else {
        const pixels_per_request = maximum_payload / 4;
        if (pixels_per_request == 0)
            return VkError.InitializationFailed;

        for (0..protocol_height) |y| {
            var x: usize = 0;
            while (x < protocol_width) {
                const pixel_count = @min(pixels_per_request, @as(usize, protocol_width) - x);
                const offset = y * row_size + x * 4;
                const byte_count = pixel_count * 4;
                _ = xcb_put_image(
                    connection,
                    z_pixmap,
                    drawable,
                    gc,
                    @intCast(pixel_count),
                    1,
                    @intCast(x),
                    @intCast(y),
                    0,
                    depth,
                    @intCast(byte_count),
                    data[offset..][0..byte_count].ptr,
                );
                x += pixel_count;
            }
        }
    }

    if (xcb_flush(connection) <= 0)
        try checkConnection(connection);
}
