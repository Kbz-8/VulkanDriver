const std = @import("std");
const vk = @import("vulkan");
const lib = @import("../../lib.zig");

const VkError = lib.VkError;

pub const wl_registry_listener = extern struct {
    global: *const fn (*anyopaque, *wl_registry, c_uint, [*:0]const u8, c_uint) callconv(.c) void,
    global_remove: *const fn (*anyopaque, *wl_registry, c_uint) callconv(.c) void,
};

pub const wl_buffer = opaque {};
pub const wl_callback = opaque {};
pub const wl_display = vk.wl_display;
pub const wl_interface = opaque {};
pub const wl_registry = opaque {};
pub const wl_shm = opaque {};
pub const wl_shm_pool = opaque {};
pub const wl_surface = vk.wl_surface;

pub var wl_display_dispatch: *const fn (d: *wl_display) callconv(.c) c_int = undefined;
pub var wl_display_get_registry: *const fn (d: *wl_display) callconv(.c) ?*wl_registry = undefined;
pub var wl_display_roundtrip: *const fn (d: *wl_display) callconv(.c) c_int = undefined;
pub var wl_display_sync: *const fn (d: *wl_display) callconv(.c) ?*wl_callback = undefined;
pub var wl_registry_add_listener: *const fn (r: *wl_registry, l: *const wl_registry_listener, data: *anyopaque) callconv(.c) c_int = undefined;
pub var wl_registry_bind: *const fn (r: *wl_registry, name: u32, i: *const wl_interface, version: u32) callconv(.c) ?*anyopaque = undefined;
pub var wl_buffer_destroy: *const fn (b: *wl_buffer) callconv(.c) void = undefined;
pub var wl_shm_create_pool: *const fn (shm: *wl_shm, fd: i32, size: i32) callconv(.c) ?*wl_shm_pool = undefined;
pub var wl_shm_pool_create_buffer: *const fn (p: *wl_shm_pool, offset: i32, width: i32, height: i32, stride: i32, format: u32) callconv(.c) ?*wl_buffer = undefined;
pub var wl_shm_pool_destroy: *const fn (p: *wl_shm_pool) callconv(.c) void = undefined;
pub var wl_surface_attach: *const fn (s: *wl_surface, b: *wl_buffer, x: i32, y: i32) callconv(.c) void = undefined;
pub var wl_surface_damage: *const fn (s: *wl_surface, x: i32, y: i32, width: i32, height: i32) callconv(.c) void = undefined;
pub var wl_surface_commit: *const fn (s: *wl_surface) callconv(.c) void = undefined;

pub var wl_shm_interface: *wl_interface = undefined;

pub var module: std.DynLib = undefined;

pub var ref_count = std.atomic.Value(usize).init(0);

pub fn load() VkError!void {
    if (ref_count.load(.monotonic) != 0)
        return;

    module = std.DynLib.open("libwayland-client.so.0") catch return VkError.Unknown;
    errdefer module.close();

    // zig fmt: off
    wl_display_dispatch       = module.lookup(@TypeOf(wl_display_dispatch),       "wl_display_dispatch"       ) orelse return VkError.Unknown;
    wl_display_get_registry   = module.lookup(@TypeOf(wl_display_get_registry),   "wl_display_get_registry"   ) orelse return VkError.Unknown;
    wl_display_roundtrip      = module.lookup(@TypeOf(wl_display_roundtrip),      "wl_display_roundtrip"      ) orelse return VkError.Unknown;
    wl_display_sync           = module.lookup(@TypeOf(wl_display_sync),           "wl_display_sync"           ) orelse return VkError.Unknown;
    wl_registry_add_listener  = module.lookup(@TypeOf(wl_registry_add_listener),  "wl_registry_add_listener"  ) orelse return VkError.Unknown;
    wl_registry_bind          = module.lookup(@TypeOf(wl_registry_bind),          "wl_registry_bind"          ) orelse return VkError.Unknown;
    wl_buffer_destroy         = module.lookup(@TypeOf(wl_buffer_destroy),         "wl_buffer_destroy"         ) orelse return VkError.Unknown;
    wl_shm_create_pool        = module.lookup(@TypeOf(wl_shm_create_pool),        "wl_shm_create_pool"        ) orelse return VkError.Unknown;
    wl_shm_pool_create_buffer = module.lookup(@TypeOf(wl_shm_pool_create_buffer), "wl_shm_pool_create_buffer" ) orelse return VkError.Unknown;
    wl_shm_pool_destroy       = module.lookup(@TypeOf(wl_shm_pool_destroy),       "wl_shm_pool_destroy"       ) orelse return VkError.Unknown;
    wl_surface_attach         = module.lookup(@TypeOf(wl_surface_attach),         "wl_surface_attach"         ) orelse return VkError.Unknown;
    wl_surface_damage         = module.lookup(@TypeOf(wl_surface_damage),         "wl_surface_damage"         ) orelse return VkError.Unknown;
    wl_surface_commit         = module.lookup(@TypeOf(wl_surface_commit),         "wl_surface_commit"         ) orelse return VkError.Unknown;
    // zig fmt: on

    wl_shm_interface = module.lookup(*wl_interface, "wl_shm_interface") orelse return VkError.Unknown;

    _ = ref_count.fetchAdd(1, .monotonic);
}

pub fn unload() void {
    if (ref_count.fetchSub(1, .release) == 1) {
        module.close();
    }
}
