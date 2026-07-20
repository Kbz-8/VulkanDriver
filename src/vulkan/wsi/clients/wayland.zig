//! Minimal wayland client protocol declarations and loader

const std = @import("std");
const vk = @import("vulkan");
const lib = @import("../../lib.zig");

const VkError = lib.VkError;

pub const wl_registry_listener = extern struct {
    global: ?*const fn (data: ?*anyopaque, wl_registry: ?*wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void = null,
    global_remove: ?*const fn (data: ?*anyopaque, wl_registry: ?*wl_registry, name: u32) callconv(.c) void = null,
};

pub const wl_buffer_destroy_opcode: c_int = 0;
pub const wl_display_get_registry_opcode: c_int = 1;
pub const wl_registry_bind_opcode: c_int = 0;
pub const wl_shm_create_pool_opcode: c_int = 0;
pub const wl_shm_format_argb8888: c_int = 0;
pub const wl_shm_pool_create_buffer_opcode: c_int = 0;
pub const wl_shm_pool_destroy_opcode: c_int = 1;
pub const wl_surface_attach_opcode: c_int = 1;
pub const wl_surface_commit_opcode: c_int = 6;
pub const wl_surface_damage_opcode: c_int = 2;

pub const wl_buffer = opaque {};
pub const wl_callback = opaque {};
pub const wl_registry = opaque {};
pub const wl_shm = opaque {};
pub const wl_shm_pool = opaque {};
pub const wl_proxy = opaque {};
pub const wl_display = vk.wl_display;
pub const wl_surface = vk.wl_surface;

pub const wl_message = extern struct {
    name: ?[*:0]const u8 = null,
    signature: [*c]const u8 = null,
    types: [*c]*const wl_interface = null,
};

pub const wl_interface = extern struct {
    name: ?[*:0]const u8 = null,
    version: c_int = 0,
    method_count: c_int = 0,
    methods: ?[*]const wl_message = null,
    event_count: c_int = 0,
    events: ?[*]const wl_message = null,
};

// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_display_dispatch: *const fn (*wl_display) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_proxy_marshal_flags: *const fn (*wl_proxy, u32, ?*const wl_interface, u32, u32, ...) callconv(.c) ?*wl_proxy = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_proxy_get_version: *const fn (*wl_proxy) callconv(.c) u32 = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_proxy_add_listener: *const fn (*wl_proxy, **const fn (void) void, ?*anyopaque) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_display_flush: *const fn (*wl_display) callconv(.c) c_int = undefined;

// SAFETY: load resolves every interface pointer before a surface can be created.
pub var wl_buffer_interface: *wl_interface = undefined;
// SAFETY: load resolves every interface pointer before a surface can be created.
pub var wl_registry_interface: *wl_interface = undefined;
// SAFETY: load resolves every interface pointer before a surface can be created.
pub var wl_shm_interface: *wl_interface = undefined;
// SAFETY: load resolves every interface pointer before a surface can be created.
pub var wl_shm_pool_interface: *wl_interface = undefined;

// SAFETY: load initializes the module before it can be closed or queried.
pub var module: std.DynLib = undefined;

pub var ref_count = std.atomic.Value(usize).init(0);

pub fn load() VkError!void {
    if (ref_count.load(.monotonic) != 0)
        return;

    module = std.DynLib.open("libwayland-client.so.0") catch return VkError.Unknown;
    errdefer module.close();
    errdefer std.log.scoped(.WaylandClient).err("Could not open 'libwayland-client.so.0': {s}", .{std.c.dlerror() orelse "unknown error"});

    wl_display_dispatch = module.lookup(@TypeOf(wl_display_dispatch), "wl_display_dispatch") orelse return VkError.Unknown;
    wl_proxy_marshal_flags = module.lookup(@TypeOf(wl_proxy_marshal_flags), "wl_proxy_marshal_flags") orelse return VkError.Unknown;
    wl_proxy_get_version = module.lookup(@TypeOf(wl_proxy_get_version), "wl_proxy_get_version") orelse return VkError.Unknown;
    wl_proxy_add_listener = module.lookup(@TypeOf(wl_proxy_add_listener), "wl_proxy_add_listener") orelse return VkError.Unknown;
    wl_display_flush = module.lookup(@TypeOf(wl_display_flush), "wl_display_flush") orelse return VkError.Unknown;

    wl_buffer_interface = module.lookup(*wl_interface, "wl_buffer_interface") orelse return VkError.Unknown;
    wl_registry_interface = module.lookup(*wl_interface, "wl_registry_interface") orelse return VkError.Unknown;
    wl_shm_interface = module.lookup(*wl_interface, "wl_shm_interface") orelse return VkError.Unknown;
    wl_shm_pool_interface = module.lookup(*wl_interface, "wl_shm_pool_interface") orelse return VkError.Unknown;

    _ = ref_count.fetchAdd(1, .monotonic);
    std.log.scoped(.WaylandClient).debug("Loaded wayland client lib", .{});
}

pub fn unload() void {
    if (ref_count.fetchSub(1, .release) == 1) {
        module.close();
        std.log.scoped(.WaylandClient).debug("Unloaded wayland client lib", .{});
    }
}

pub fn wl_registry_bind(registry: *wl_registry, name: u32, interface: *const wl_interface, version: u32) ?*wl_proxy {
    return wl_proxy_marshal_flags(
        @ptrCast(@alignCast(registry)),
        wl_registry_bind_opcode,
        interface,
        version,
        0,
        name,
        interface.name,
        version,
        @as(?*anyopaque, null),
    );
}

pub fn wl_display_get_registry(display: *wl_display) ?*wl_registry {
    return @ptrCast(@alignCast(wl_proxy_marshal_flags(
        @ptrCast(@alignCast(display)),
        wl_display_get_registry_opcode,
        wl_registry_interface,
        wl_proxy_get_version(@ptrCast(@alignCast(display))),
        0,
        @as(?*anyopaque, null),
    )));
}

pub fn wl_registry_add_listener(registry: *wl_registry, listener: *const wl_registry_listener, data: ?*anyopaque) c_int {
    return wl_proxy_add_listener(@ptrCast(@alignCast(registry)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn wl_shm_create_pool(shm: *wl_shm, fd: i32, size: i32) callconv(.c) ?*wl_shm_pool {
    return @ptrCast(@alignCast(wl_proxy_marshal_flags(
        @ptrCast(@alignCast(shm)),
        wl_shm_create_pool_opcode,
        wl_shm_pool_interface,
        wl_proxy_get_version(@ptrCast(@alignCast(shm))),
        0,
        @as(?*anyopaque, null),
        fd,
        size,
    )));
}

pub fn wl_shm_pool_destroy(shm_pool: *wl_shm_pool) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(@alignCast(shm_pool)),
        wl_shm_pool_destroy_opcode,
        null,
        wl_proxy_get_version(@ptrCast(@alignCast(shm_pool))),
        @bitCast(@as(c_int, @as(c_int, 1) << @intCast(@as(c_int, 0)))),
    );
}

pub fn wl_shm_pool_create_buffer(shm_pool: *wl_shm_pool, offset: i32, width: i32, height: i32, stride: i32, format: u32) ?*wl_buffer {
    return @ptrCast(@alignCast(wl_proxy_marshal_flags(
        @ptrCast(@alignCast(shm_pool)),
        wl_shm_pool_create_buffer_opcode,
        wl_buffer_interface,
        wl_proxy_get_version(@ptrCast(@alignCast(shm_pool))),
        0,
        @as(?*anyopaque, null),
        offset,
        width,
        height,
        stride,
        format,
    )));
}

pub fn wl_buffer_destroy(buffer: *wl_buffer) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(@alignCast(buffer)),
        wl_buffer_destroy_opcode,
        null,
        wl_proxy_get_version(@ptrCast(@alignCast(buffer))),
        @bitCast(@as(c_int, @as(c_int, 1) << @intCast(@as(c_int, 0)))),
    );
}

pub fn wl_surface_attach(surface: *wl_surface, buffer: *wl_buffer, x: i32, y: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(@alignCast(surface)),
        wl_surface_attach_opcode,
        null,
        wl_proxy_get_version(@ptrCast(@alignCast(surface))),
        0,
        buffer,
        x,
        y,
    );
}

pub fn wl_surface_damage(surface: *wl_surface, x: i32, y: i32, width: i32, height: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(@alignCast(surface)),
        wl_surface_damage_opcode,
        null,
        wl_proxy_get_version(@ptrCast(@alignCast(surface))),
        0,
        x,
        y,
        width,
        height,
    );
}

pub fn wl_surface_commit(surface: *wl_surface) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(@alignCast(surface)),
        wl_surface_commit_opcode,
        null,
        wl_proxy_get_version(@ptrCast(@alignCast(surface))),
        0,
    );
}
