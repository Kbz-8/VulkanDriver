//! Minimal Wayland client and linux-dmabuf protocol declarations and loader.

const std = @import("std");
const vk = @import("vulkan");
const lib = @import("../../lib.zig");

const VkError = lib.VkError;

pub const wl_registry_listener = extern struct {
    global: ?*const fn (data: ?*anyopaque, registry: ?*wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void = null,
    global_remove: ?*const fn (data: ?*anyopaque, registry: ?*wl_registry, name: u32) callconv(.c) void = null,
};

pub const wl_buffer_listener = extern struct {
    release: ?*const fn (data: ?*anyopaque, buffer: ?*wl_buffer) callconv(.c) void = null,
};

pub const zwp_linux_dmabuf_v1_listener = extern struct {
    format: ?*const fn (data: ?*anyopaque, dmabuf: ?*zwp_linux_dmabuf_v1, format: u32) callconv(.c) void = null,
    modifier: ?*const fn (data: ?*anyopaque, dmabuf: ?*zwp_linux_dmabuf_v1, format: u32, modifier_hi: u32, modifier_lo: u32) callconv(.c) void = null,
};

pub const zwp_linux_buffer_params_v1_listener = extern struct {
    created: ?*const fn (data: ?*anyopaque, params: ?*zwp_linux_buffer_params_v1, buffer: ?*wl_buffer) callconv(.c) void = null,
    failed: ?*const fn (data: ?*anyopaque, params: ?*zwp_linux_buffer_params_v1) callconv(.c) void = null,
};

pub const wl_buffer_destroy_opcode: u32 = 0;
pub const wl_display_get_registry_opcode: u32 = 1;
pub const wl_registry_bind_opcode: u32 = 0;
pub const wl_surface_attach_opcode: u32 = 1;
pub const wl_surface_commit_opcode: u32 = 6;
pub const wl_surface_damage_opcode: u32 = 2;

pub const zwp_linux_dmabuf_v1_destroy_opcode: u32 = 0;
pub const zwp_linux_dmabuf_v1_create_params_opcode: u32 = 1;
pub const zwp_linux_buffer_params_v1_destroy_opcode: u32 = 0;
pub const zwp_linux_buffer_params_v1_add_opcode: u32 = 1;
pub const zwp_linux_buffer_params_v1_create_opcode: u32 = 2;

const wl_marshal_flag_destroy: u32 = 1;

pub const wl_buffer = opaque {};
pub const wl_event_queue = opaque {};
pub const wl_registry = opaque {};
pub const wl_proxy = opaque {};
pub const zwp_linux_dmabuf_v1 = opaque {};
pub const zwp_linux_buffer_params_v1 = opaque {};
pub const wl_display = vk.wl_display;
pub const wl_surface = vk.wl_surface;

pub const wl_message = extern struct {
    name: ?[*:0]const u8 = null,
    signature: [*c]const u8 = null,
    types: [*c]const ?*const wl_interface = null,
};

pub const wl_interface = extern struct {
    name: ?[*:0]const u8 = null,
    version: c_int = 0,
    method_count: c_int = 0,
    methods: ?[*]const wl_message = null,
    event_count: c_int = 0,
    events: ?[*]const wl_message = null,
};

const no_types = [_]?*const wl_interface{null};
const dmabuf_create_params_types = [_]?*const wl_interface{&zwp_linux_buffer_params_v1_interface};
const params_create_immed_types = [_]?*const wl_interface{ &wl_buffer_interface_storage, null, null, null, null };
const params_created_types = [_]?*const wl_interface{&wl_buffer_interface_storage};

const dmabuf_requests = [_]wl_message{
    .{ .name = "destroy", .signature = "", .types = no_types[0..].ptr },
    .{ .name = "create_params", .signature = "n", .types = dmabuf_create_params_types[0..].ptr },
};

const dmabuf_events = [_]wl_message{
    .{ .name = "format", .signature = "u", .types = no_types[0..].ptr },
    .{ .name = "modifier", .signature = "3uuu", .types = no_types[0..].ptr },
};

pub const zwp_linux_dmabuf_v1_interface: wl_interface = .{
    .name = "zwp_linux_dmabuf_v1",
    .version = 3,
    .method_count = dmabuf_requests.len,
    .methods = &dmabuf_requests,
    .event_count = dmabuf_events.len,
    .events = &dmabuf_events,
};

const params_requests = [_]wl_message{
    .{ .name = "destroy", .signature = "", .types = no_types[0..].ptr },
    .{ .name = "add", .signature = "huuuuu", .types = no_types[0..].ptr },
    .{ .name = "create", .signature = "iiuu", .types = no_types[0..].ptr },
    .{ .name = "create_immed", .signature = "2niiuu", .types = params_create_immed_types[0..].ptr },
};

const params_events = [_]wl_message{
    .{ .name = "created", .signature = "n", .types = params_created_types[0..].ptr },
    .{ .name = "failed", .signature = "", .types = no_types[0..].ptr },
};

pub const zwp_linux_buffer_params_v1_interface: wl_interface = .{
    .name = "zwp_linux_buffer_params_v1",
    .version = 3,
    .method_count = params_requests.len,
    .methods = &params_requests,
    .event_count = params_events.len,
    .events = &params_events,
};

// The loaded wl_buffer_interface is copied here before any linux-dmabuf request is made.
// SAFETY: load assigns every global pointer before any protocol wrapper is used.
var wl_buffer_interface_storage: wl_interface = undefined;

// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_display_cancel_read: *const fn (*wl_display) callconv(.c) void = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_display_create_queue: *const fn (*wl_display) callconv(.c) ?*wl_event_queue = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_display_dispatch_queue: *const fn (*wl_display, *wl_event_queue) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_display_dispatch_queue_pending: *const fn (*wl_display, *wl_event_queue) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_display_get_fd: *const fn (*wl_display) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_display_prepare_read_queue: *const fn (*wl_display, *wl_event_queue) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_display_read_events: *const fn (*wl_display) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_display_roundtrip_queue: *const fn (*wl_display, *wl_event_queue) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_event_queue_destroy: *const fn (*wl_event_queue) callconv(.c) void = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_proxy_marshal_flags: *const fn (*wl_proxy, u32, ?*const wl_interface, u32, u32, ...) callconv(.c) ?*wl_proxy = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_proxy_get_version: *const fn (*wl_proxy) callconv(.c) u32 = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_proxy_add_listener: *const fn (*wl_proxy, **const fn (void) void, ?*anyopaque) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_proxy_destroy: *const fn (*wl_proxy) callconv(.c) void = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_proxy_set_queue: *const fn (*wl_proxy, ?*wl_event_queue) callconv(.c) void = undefined;
// SAFETY: load assigns every function pointer before any protocol wrapper is used.
pub var wl_display_flush: *const fn (*wl_display) callconv(.c) c_int = undefined;

// SAFETY: load resolves every interface pointer before a surface can be created.
pub var wl_buffer_interface: *wl_interface = undefined;
// SAFETY: load resolves every interface pointer before a surface can be created.
pub var wl_registry_interface: *wl_interface = undefined;

// SAFETY: load initializes the module before it can be closed or queried.
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

    module = std.DynLib.open("libwayland-client.so.0") catch {
        std.log.scoped(.WaylandClient).err("Could not open 'libwayland-client.so.0'", .{});
        return VkError.InitializationFailed;
    };
    errdefer module.close();

    wl_display_cancel_read = module.lookup(@TypeOf(wl_display_cancel_read), "wl_display_cancel_read") orelse return VkError.InitializationFailed;
    wl_display_create_queue = module.lookup(@TypeOf(wl_display_create_queue), "wl_display_create_queue") orelse return VkError.InitializationFailed;
    wl_display_dispatch_queue = module.lookup(@TypeOf(wl_display_dispatch_queue), "wl_display_dispatch_queue") orelse return VkError.InitializationFailed;
    wl_display_dispatch_queue_pending = module.lookup(@TypeOf(wl_display_dispatch_queue_pending), "wl_display_dispatch_queue_pending") orelse return VkError.InitializationFailed;
    wl_display_get_fd = module.lookup(@TypeOf(wl_display_get_fd), "wl_display_get_fd") orelse return VkError.InitializationFailed;
    wl_display_prepare_read_queue = module.lookup(@TypeOf(wl_display_prepare_read_queue), "wl_display_prepare_read_queue") orelse return VkError.InitializationFailed;
    wl_display_read_events = module.lookup(@TypeOf(wl_display_read_events), "wl_display_read_events") orelse return VkError.InitializationFailed;
    wl_display_roundtrip_queue = module.lookup(@TypeOf(wl_display_roundtrip_queue), "wl_display_roundtrip_queue") orelse return VkError.InitializationFailed;
    wl_event_queue_destroy = module.lookup(@TypeOf(wl_event_queue_destroy), "wl_event_queue_destroy") orelse return VkError.InitializationFailed;
    wl_proxy_marshal_flags = module.lookup(@TypeOf(wl_proxy_marshal_flags), "wl_proxy_marshal_flags") orelse return VkError.InitializationFailed;
    wl_proxy_get_version = module.lookup(@TypeOf(wl_proxy_get_version), "wl_proxy_get_version") orelse return VkError.InitializationFailed;
    wl_proxy_add_listener = module.lookup(@TypeOf(wl_proxy_add_listener), "wl_proxy_add_listener") orelse return VkError.InitializationFailed;
    wl_proxy_destroy = module.lookup(@TypeOf(wl_proxy_destroy), "wl_proxy_destroy") orelse return VkError.InitializationFailed;
    wl_proxy_set_queue = module.lookup(@TypeOf(wl_proxy_set_queue), "wl_proxy_set_queue") orelse return VkError.InitializationFailed;
    wl_display_flush = module.lookup(@TypeOf(wl_display_flush), "wl_display_flush") orelse return VkError.InitializationFailed;

    wl_buffer_interface = module.lookup(*wl_interface, "wl_buffer_interface") orelse return VkError.InitializationFailed;
    wl_registry_interface = module.lookup(*wl_interface, "wl_registry_interface") orelse return VkError.InitializationFailed;
    wl_buffer_interface_storage = wl_buffer_interface.*;

    _ = ref_count.fetchAdd(1, .monotonic);
    std.log.scoped(.WaylandClient).debug("Loaded Wayland client", .{});
}

pub fn unload() void {
    load_mutex.lock();
    defer load_mutex.unlock();

    if (ref_count.fetchSub(1, .release) == 1) {
        module.close();
        std.log.scoped(.WaylandClient).debug("Unloaded Wayland client", .{});
    }
}

pub fn wlRegistryBind(registry: *wl_registry, name: u32, interface: *const wl_interface, version: u32) ?*wl_proxy {
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

pub fn wlDisplayGetRegistry(display: *wl_display) ?*wl_registry {
    return @ptrCast(@alignCast(wl_proxy_marshal_flags(
        @ptrCast(@alignCast(display)),
        wl_display_get_registry_opcode,
        wl_registry_interface,
        wl_proxy_get_version(@ptrCast(@alignCast(display))),
        0,
        @as(?*anyopaque, null),
    )));
}

pub fn wlRegistryAddListener(registry: *wl_registry, listener: *const wl_registry_listener, data: ?*anyopaque) c_int {
    return wl_proxy_add_listener(@ptrCast(@alignCast(registry)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn wlProxyAssignQueue(proxy: *anyopaque, queue: *wl_event_queue) void {
    wl_proxy_set_queue(@ptrCast(@alignCast(proxy)), queue);
}

pub fn wlRegistryDestroy(registry: *wl_registry) void {
    wl_proxy_destroy(@ptrCast(@alignCast(registry)));
}

pub fn wlBufferAddListener(buffer: *wl_buffer, listener: *const wl_buffer_listener, data: ?*anyopaque) c_int {
    return wl_proxy_add_listener(@ptrCast(@alignCast(buffer)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn zwpLinuxDmabufV1AddListener(dmabuf: *zwp_linux_dmabuf_v1, listener: *const zwp_linux_dmabuf_v1_listener, data: ?*anyopaque) c_int {
    return wl_proxy_add_listener(@ptrCast(@alignCast(dmabuf)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn zwpLinuxBufferParamsV1AddListener(params: *zwp_linux_buffer_params_v1, listener: *const zwp_linux_buffer_params_v1_listener, data: ?*anyopaque) c_int {
    return wl_proxy_add_listener(@ptrCast(@alignCast(params)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn zwpLinuxDmabufV1Destroy(dmabuf: *zwp_linux_dmabuf_v1) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(@alignCast(dmabuf)),
        zwp_linux_dmabuf_v1_destroy_opcode,
        null,
        wl_proxy_get_version(@ptrCast(@alignCast(dmabuf))),
        wl_marshal_flag_destroy,
    );
}

pub fn zwpLinuxDmabufV1CreateParams(dmabuf: *zwp_linux_dmabuf_v1) ?*zwp_linux_buffer_params_v1 {
    return @ptrCast(@alignCast(wl_proxy_marshal_flags(
        @ptrCast(@alignCast(dmabuf)),
        zwp_linux_dmabuf_v1_create_params_opcode,
        &zwp_linux_buffer_params_v1_interface,
        wl_proxy_get_version(@ptrCast(@alignCast(dmabuf))),
        0,
        @as(?*anyopaque, null),
    )));
}

pub fn zwpLinuxBufferParamsV1Destroy(params: *zwp_linux_buffer_params_v1) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(@alignCast(params)),
        zwp_linux_buffer_params_v1_destroy_opcode,
        null,
        wl_proxy_get_version(@ptrCast(@alignCast(params))),
        wl_marshal_flag_destroy,
    );
}

pub fn zwpLinuxBufferParamsV1Add(params: *zwp_linux_buffer_params_v1, fd: i32, plane_index: u32, offset: u32, stride: u32, modifier: u64) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(@alignCast(params)),
        zwp_linux_buffer_params_v1_add_opcode,
        null,
        wl_proxy_get_version(@ptrCast(@alignCast(params))),
        0,
        fd,
        plane_index,
        offset,
        stride,
        @as(u32, @truncate(modifier >> 32)),
        @as(u32, @truncate(modifier)),
    );
}

pub fn zwpLinuxBufferParamsV1Create(params: *zwp_linux_buffer_params_v1, width: i32, height: i32, format: u32, flags: u32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(@alignCast(params)),
        zwp_linux_buffer_params_v1_create_opcode,
        null,
        wl_proxy_get_version(@ptrCast(@alignCast(params))),
        0,
        width,
        height,
        format,
        flags,
    );
}

pub fn wlBufferDestroy(buffer: *wl_buffer) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(@alignCast(buffer)),
        wl_buffer_destroy_opcode,
        null,
        wl_proxy_get_version(@ptrCast(@alignCast(buffer))),
        wl_marshal_flag_destroy,
    );
}

pub fn wlSurfaceAttach(surface: *wl_surface, buffer: *wl_buffer, x: i32, y: i32) void {
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

pub fn wlSurfaceDamage(surface: *wl_surface, x: i32, y: i32, width: i32, height: i32) void {
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

pub fn wlSurfaceCommit(surface: *wl_surface) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(@alignCast(surface)),
        wl_surface_commit_opcode,
        null,
        wl_proxy_get_version(@ptrCast(@alignCast(surface))),
        0,
    );
}
