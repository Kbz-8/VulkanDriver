const std = @import("std");
const vk = @import("vulkan");
const lib = @import("../../lib.zig");

pub const c = lib.c;

const VkError = lib.VkError;

pub const wl_registry_listener = c.wl_registry_listener;

pub const WL_SHM_FORMAT_ARGB8888 = c.WL_SHM_FORMAT_ARGB8888;

pub const wl_buffer = c.wl_buffer;
pub const wl_callback = c.wl_buffer;
pub const wl_interface = c.wl_interface;
pub const wl_registry = c.wl_registry;
pub const wl_shm = c.wl_shm;
pub const wl_shm_pool = c.wl_shm_pool;
pub const wl_proxy = c.wl_proxy;

// vk.wl_XXX instead of c.wl_XXX to avoid casts with Zig Vulkan bindings functions
pub const wl_display = vk.wl_display;
pub const wl_surface = vk.wl_surface;

pub var wl_display_dispatch: *const fn (*wl_display) callconv(.c) c_int = undefined;
pub var wl_proxy_marshal_flags: *const fn (*wl_proxy, u32, *const wl_interface, u32, u32, ...) callconv(.c) ?*wl_proxy = undefined;
pub var wl_display_flush: *const fn (*wl_display) callconv(.c) c_int = undefined;

pub var wl_shm_interface: *wl_interface = undefined;

pub var module: std.DynLib = undefined;

pub var ref_count = std.atomic.Value(usize).init(0);

pub fn load() VkError!void {
    if (ref_count.load(.monotonic) != 0)
        return;

    module = std.DynLib.open("libwayland-client.so.0") catch {
        _ = ref_count.fetchSub(1, .monotonic);
        return VkError.Unknown;
    };
    errdefer module.close();
    errdefer std.log.scoped(.WaylandClient).err("Could not open 'libwayland-client.so.0': {s}", .{std.c.dlerror() orelse "unknown error"});

    wl_display_dispatch = module.lookup(@TypeOf(wl_display_dispatch), "wl_display_dispatch") orelse return VkError.Unknown;
    wl_proxy_marshal_flags = module.lookup(@TypeOf(wl_proxy_marshal_flags), "wl_proxy_marshal_flags") orelse return VkError.Unknown;
    wl_display_flush = module.lookup(@TypeOf(wl_display_flush), "wl_display_flush") orelse return VkError.Unknown;

    wl_shm_interface = module.lookup(*wl_interface, "wl_shm_interface") orelse return VkError.Unknown;

    _ = ref_count.fetchAdd(1, .monotonic);
}

pub fn unload() void {
    if (ref_count.fetchSub(1, .release) == 1) {
        module.close();
    }
}
