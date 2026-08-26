const std = @import("std");
const vk = @import("vulkan");

const lib = @import("../lib.zig");
const gbm = @import("clients/gbm.zig");
const wayland = @import("clients/wayland.zig");
const PresentImage = @import("PresentImage.zig");

const VkError = @import("../error_set.zig").VkError;
const Instance = lib.Instance;

const Self = @This();
pub const Interface = @import("SurfaceKHR.zig");

const WaylandImage = struct {
    buffer: *wayland.wl_buffer,
    dma_buf: gbm.Buffer,
    staging: []u8,
    image: *PresentImage,
    width: u32,
    height: u32,
    row_size: usize,
};

fn wlRegistryHandleGlobal(data: ?*anyopaque, registry: ?*wayland.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data orelse return));
    if (!std.mem.eql(u8, std.mem.span(interface), "zwp_linux_dmabuf_v1") or version < 2 or self.dmabuf != null)
        return;

    const bind_version = @min(version, @as(u32, wayland.zwp_linux_dmabuf_v1_interface.version));
    const proxy = wayland.wlRegistryBind(registry orelse return, name, &wayland.zwp_linux_dmabuf_v1_interface, bind_version) orelse {
        self.protocol_failed = true;
        return;
    };

    const dmabuf: *wayland.zwp_linux_dmabuf_v1 = @ptrCast(@alignCast(proxy));
    wayland.wlProxyAssignQueue(dmabuf, self.event_queue);
    self.dmabuf = dmabuf;
    self.dmabuf_version = bind_version;
    if (wayland.zwpLinuxDmabufV1AddListener(dmabuf, &linux_dmabuf_listener, self) != 0)
        self.protocol_failed = true;
}

fn wlRegistryHandleGlobalRemove(_: ?*anyopaque, _: ?*wayland.wl_registry, _: u32) callconv(.c) void {}

const wl_registry_listener: wayland.wl_registry_listener = .{
    .global = wlRegistryHandleGlobal,
    .global_remove = wlRegistryHandleGlobalRemove,
};

fn linuxDmabufHandleFormat(data: ?*anyopaque, _: ?*wayland.zwp_linux_dmabuf_v1, format: u32) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data orelse return));
    if (format != gbm.drm_format_argb8888)
        return;

    self.supports_argb8888 = true;
    if (self.dmabuf_version < 3)
        self.supports_implicit_modifier = true;
}

fn linuxDmabufHandleModifier(data: ?*anyopaque, _: ?*wayland.zwp_linux_dmabuf_v1, format: u32, modifier_hi: u32, modifier_lo: u32) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data orelse return));
    if (format != gbm.drm_format_argb8888)
        return;

    const modifier = (@as(u64, modifier_hi) << 32) | modifier_lo;
    switch (modifier) {
        gbm.drm_format_modifier_linear => self.supports_linear_modifier = true,
        gbm.drm_format_modifier_invalid => self.supports_implicit_modifier = true,
        else => {},
    }
}

const linux_dmabuf_listener: wayland.zwp_linux_dmabuf_v1_listener = .{
    .format = linuxDmabufHandleFormat,
    .modifier = linuxDmabufHandleModifier,
};

const BufferCreationResult = struct {
    buffer: ?*wayland.wl_buffer = null,
    failed: bool = false,
};

fn linuxBufferParamsHandleCreated(data: ?*anyopaque, _: ?*wayland.zwp_linux_buffer_params_v1, buffer: ?*wayland.wl_buffer) callconv(.c) void {
    const result: *BufferCreationResult = @ptrCast(@alignCast(data orelse return));
    result.buffer = buffer;
    result.failed = buffer == null;
}

fn linuxBufferParamsHandleFailed(data: ?*anyopaque, _: ?*wayland.zwp_linux_buffer_params_v1) callconv(.c) void {
    const result: *BufferCreationResult = @ptrCast(@alignCast(data orelse return));
    result.failed = true;
}

const linux_buffer_params_listener: wayland.zwp_linux_buffer_params_v1_listener = .{
    .created = linuxBufferParamsHandleCreated,
    .failed = linuxBufferParamsHandleFailed,
};

fn wlBufferHandleRelease(data: ?*anyopaque, _: ?*wayland.wl_buffer) callconv(.c) void {
    const wl_image: *WaylandImage = @ptrCast(@alignCast(data orelse return));
    wl_image.image.state = .available;
}

const wl_buffer_listener: wayland.wl_buffer_listener = .{
    .release = wlBufferHandleRelease,
};

interface: Interface,
display: *wayland.wl_display,
surface: *wayland.wl_surface,
event_queue: *wayland.wl_event_queue,
dmabuf: ?*wayland.zwp_linux_dmabuf_v1,
dmabuf_version: u32,
supports_argb8888: bool,
supports_linear_modifier: bool,
supports_implicit_modifier: bool,
protocol_failed: bool,
gbm_device: ?gbm.Device,
image_map: std.AutoHashMapUnmanaged(*PresentImage, *WaylandImage),

pub fn create(instance: *Instance, allocator: std.mem.Allocator, info: *const vk.WaylandSurfaceCreateInfoKHR) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    try wayland.load();
    errdefer wayland.unload();
    try gbm.load();
    errdefer gbm.unload();

    var interface = try Interface.init(instance, allocator);
    interface.vtable = &.{
        .destroy = destroy,
        .getCapabilities = getCapabilities,
        .attachImage = attachImage,
        .detachImage = detachImage,
        .waitForImage = waitForImage,
        .presentImage = presentImage,
    };

    const event_queue = wayland.wl_display_create_queue(info.display) orelse return VkError.OutOfHostMemory;
    errdefer wayland.wl_event_queue_destroy(event_queue);

    self.* = .{
        .interface = interface,
        .display = info.display,
        .surface = info.surface,
        .event_queue = event_queue,
        .dmabuf = null,
        .dmabuf_version = 0,
        .supports_argb8888 = false,
        .supports_linear_modifier = false,
        .supports_implicit_modifier = false,
        .protocol_failed = false,
        .gbm_device = null,
        .image_map = .empty,
    };
    errdefer if (self.dmabuf) |dmabuf| wayland.zwpLinuxDmabufV1Destroy(dmabuf);

    const registry = wayland.wlDisplayGetRegistry(self.display) orelse return VkError.InitializationFailed;
    defer wayland.wlRegistryDestroy(registry);
    wayland.wlProxyAssignQueue(registry, self.event_queue);

    if (wayland.wlRegistryAddListener(registry, &wl_registry_listener, self) != 0)
        return VkError.InitializationFailed;

    // The first roundtrip receives registry globals. The second receives the
    // format and modifier events emitted in response to binding linux-dmabuf.
    if (wayland.wl_display_roundtrip_queue(self.display, self.event_queue) < 0 or self.dmabuf == null or self.protocol_failed)
        return VkError.InitializationFailed;
    if (wayland.wl_display_roundtrip_queue(self.display, self.event_queue) < 0 or self.protocol_failed)
        return VkError.InitializationFailed;

    if (!self.supports_argb8888 or (!self.supports_linear_modifier and !self.supports_implicit_modifier)) {
        std.log.scoped(.WaylandSurface).err("The compositor does not advertise a usable DMA-BUF ARGB8888 format", .{});
        return VkError.FormatNotSupported;
    }

    return &self.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    if (interface.swapchain) |swapchain|
        swapchain.surface = null;

    var image_iterator = self.image_map.valueIterator();
    while (image_iterator.next()) |wl_image|
        destroyWaylandImage(allocator, wl_image.*);
    self.image_map.deinit(allocator);

    if (self.gbm_device) |*device|
        device.deinit();
    if (self.dmabuf) |dmabuf|
        wayland.zwpLinuxDmabufV1Destroy(dmabuf);
    wayland.wl_event_queue_destroy(self.event_queue);

    allocator.destroy(self);
    gbm.unload();
    wayland.unload();
}

pub fn getCapabilities(interface: *const Interface, capabilities: *vk.SurfaceCapabilitiesKHR) VkError!void {
    _ = interface;
    capabilities.min_image_count = 2;
    capabilities.max_image_extent = .{
        .width = std.math.maxInt(i32),
        .height = std.math.maxInt(i32),
    };
}

pub fn attachImage(interface: *Interface, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    if (self.image_map.contains(image))
        return;

    const width = image.image.extent.width;
    const height = image.image.extent.height;
    if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32))
        return VkError.OutOfDeviceMemory;

    const row_size = std.math.mul(usize, width, 4) catch return VkError.OutOfHostMemory;
    const staging_size = std.math.mul(usize, row_size, height) catch return VkError.OutOfHostMemory;

    const wl_image = allocator.create(WaylandImage) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(wl_image);

    const staging = allocator.alloc(u8, staging_size) catch return VkError.OutOfHostMemory;
    errdefer allocator.free(staging);

    if (self.gbm_device == null)
        self.gbm_device = try gbm.Device.open();
    const device = &(self.gbm_device orelse unreachable);

    var dma_buf = try device.createBuffer(width, height);
    errdefer dma_buf.deinit();

    const protocol_modifier: u64 = if (dma_buf.modifier == gbm.drm_format_modifier_linear and self.supports_linear_modifier)
        gbm.drm_format_modifier_linear
    else if (self.supports_implicit_modifier)
        gbm.drm_format_modifier_invalid
    else
        return VkError.FormatNotSupported;

    const fd = try dma_buf.exportFd();
    defer _ = std.c.close(fd);

    const dmabuf = self.dmabuf orelse return VkError.InitializationFailed;
    const params = wayland.zwpLinuxDmabufV1CreateParams(dmabuf) orelse return VkError.OutOfHostMemory;
    defer wayland.zwpLinuxBufferParamsV1Destroy(params);

    var creation_result: BufferCreationResult = .{};
    if (wayland.zwpLinuxBufferParamsV1AddListener(params, &linux_buffer_params_listener, &creation_result) != 0)
        return VkError.InitializationFailed;

    wayland.zwpLinuxBufferParamsV1Add(params, fd, 0, 0, dma_buf.stride, protocol_modifier);
    wayland.zwpLinuxBufferParamsV1Create(params, @intCast(width), @intCast(height), gbm.drm_format_argb8888, 0);
    if (wayland.wl_display_roundtrip_queue(self.display, self.event_queue) < 0)
        return VkError.SurfaceLostKhr;
    if (creation_result.failed)
        return VkError.FormatNotSupported;

    const buffer = creation_result.buffer orelse return VkError.Unknown;
    errdefer wayland.wlBufferDestroy(buffer);
    wayland.wlProxyAssignQueue(buffer, self.event_queue);

    wl_image.* = .{
        .buffer = buffer,
        .dma_buf = dma_buf,
        .staging = staging,
        .image = image,
        .width = width,
        .height = height,
        .row_size = row_size,
    };

    if (wayland.wlBufferAddListener(buffer, &wl_buffer_listener, wl_image) != 0)
        return VkError.InitializationFailed;

    self.image_map.put(allocator, image, wl_image) catch return VkError.OutOfHostMemory;
}

pub fn detachImage(interface: *Interface, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const entry = self.image_map.fetchRemove(image) orelse return;
    destroyWaylandImage(allocator, entry.value);
}

pub fn waitForImage(interface: *Interface, timeout: u64) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    if (wayland.wl_display_dispatch_queue_pending(self.display, self.event_queue) < 0)
        return VkError.SurfaceLostKhr;
    if (hasAvailableImage(self) or timeout == 0)
        return;

    if (timeout == std.math.maxInt(u64)) {
        while (!hasAvailableImage(self)) {
            if (wayland.wl_display_dispatch_queue(self.display, self.event_queue) < 0)
                return VkError.SurfaceLostKhr;
        }
        return;
    }

    const io = interface.owner.io();
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromNanoseconds(@intCast(@min(timeout, std.math.maxInt(i64)))),
        .clock = .awake,
    });

    while (!hasAvailableImage(self)) {
        while (wayland.wl_display_prepare_read_queue(self.display, self.event_queue) != 0) {
            if (wayland.wl_display_dispatch_queue_pending(self.display, self.event_queue) < 0)
                return VkError.SurfaceLostKhr;
            if (hasAvailableImage(self))
                return;
        }

        const remaining_ns = deadline.durationFromNow(io).raw.nanoseconds;
        if (remaining_ns <= 0) {
            wayland.wl_display_cancel_read(self.display);
            return;
        }

        _ = wayland.wl_display_flush(self.display);
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = wayland.wl_display_get_fd(self.display),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const rounded_ms = @divTrunc(@as(u64, @intCast(remaining_ns)) + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        const timeout_ms: i32 = @intCast(@min(rounded_ms, std.math.maxInt(i32)));
        const ready_count = std.posix.poll(&poll_fds, timeout_ms) catch {
            wayland.wl_display_cancel_read(self.display);
            return VkError.SurfaceLostKhr;
        };
        if (ready_count == 0) {
            wayland.wl_display_cancel_read(self.display);
            return;
        }

        if (wayland.wl_display_read_events(self.display) < 0)
            return VkError.SurfaceLostKhr;
        if (wayland.wl_display_dispatch_queue_pending(self.display, self.event_queue) < 0)
            return VkError.SurfaceLostKhr;
    }
}

pub fn presentImage(interface: *Interface, _: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    errdefer image.state = .available;

    const wl_image = self.image_map.get(image) orelse return VkError.Unknown;

    try image.image.copyToMemory(wl_image.staging, .{
        .aspect_mask = .{ .color_bit = true },
        .mip_level = 0,
        .base_array_layer = 0,
        .layer_count = 1,
    });

    {
        const mapping = try wl_image.dma_buf.mapWrite();
        defer wl_image.dma_buf.unmap(mapping);

        for (0..wl_image.height) |row| {
            const source_offset = row * wl_image.row_size;
            const destination_offset = row * mapping.stride;
            @memcpy(
                mapping.data[destination_offset..][0..wl_image.row_size],
                wl_image.staging[source_offset..][0..wl_image.row_size],
            );
        }
    }

    wayland.wlSurfaceAttach(self.surface, wl_image.buffer, 0, 0);
    wayland.wlSurfaceDamage(self.surface, 0, 0, @intCast(wl_image.width), @intCast(wl_image.height));
    wayland.wlSurfaceCommit(self.surface);
    _ = wayland.wl_display_flush(self.display);
}

fn hasAvailableImage(self: *const Self) bool {
    var image_iterator = self.image_map.keyIterator();
    while (image_iterator.next()) |image| {
        if (image.*.state == .available)
            return true;
    }
    return false;
}

fn destroyWaylandImage(allocator: std.mem.Allocator, wl_image: *WaylandImage) void {
    wayland.wlBufferDestroy(wl_image.buffer);
    wl_image.dma_buf.deinit();
    allocator.free(wl_image.staging);
    allocator.destroy(wl_image);
}
