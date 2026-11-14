const std = @import("std");
const vk = @import("vulkan");
const lib = @import("../lib.zig");
const metal = @import("clients/metal.zig");
const PresentImage = @import("PresentImage.zig");

const VkError = lib.VkError;
const Instance = lib.Instance;

const Self = @This();
pub const Interface = @import("SurfaceKHR.zig");

const MetalImage = struct {
    buffer: metal.id,
    row_size: usize,
    height: u32,
};

interface: Interface,
layer: metal.id,
device: metal.id,
queue: metal.id,
image_map: std.AutoHashMapUnmanaged(*PresentImage, *MetalImage),

pub fn create(instance: *Instance, allocator: std.mem.Allocator, info: *const vk.MetalSurfaceCreateInfoEXT) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    try metal.load();
    errdefer metal.unload();

    const layer: metal.id = @constCast(info.p_layer);

    const device = metal.systemDefaultDevice() orelse {
        std.log.scoped(.MetalSurface).err("Could not get the default Metal device", .{});
        return VkError.InitializationFailed;
    };

    // The app may hand us a layer with no device bound, nextDrawable returns null for it
    metal.setDevice(layer, device);
    metal.setFramebufferOnly(layer, false);

    const queue = metal.newCommandQueue(device) orelse {
        std.log.scoped(.MetalSurface).err("Could not create a Metal command queue", .{});
        return VkError.InitializationFailed;
    };
    errdefer metal.release(queue);

    var iface = try Interface.init(instance, allocator);
    iface.vtable = &.{
        .destroy = destroy,
        .getCapabilities = getCapabilities,
        .attachImage = attachImage,
        .detachImage = detachImage,
        .waitForImage = waitForImage,
        .presentImage = presentImage,
    };

    self.* = .{
        .interface = iface,
        .layer = layer,
        .device = device,
        .queue = queue,
        .image_map = .empty,
    };

    return &self.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    if (interface.swapchain) |swapchain|
        swapchain.surface = null;

    var image_iterator = self.image_map.valueIterator();
    while (image_iterator.next()) |metal_image|
        destroyMetalImage(allocator, metal_image.*);
    self.image_map.deinit(allocator);

    metal.release(self.queue);
    allocator.destroy(self);
    metal.unload();
}

pub fn getCapabilities(interface: *const Interface, capabilities: *vk.SurfaceCapabilitiesKHR) VkError!void {
    const self: *const Self = @alignCast(@fieldParentPtr("interface", interface));
    capabilities.current_extent = metal.naturalExtent(self.layer);
}

pub fn attachImage(interface: *Interface, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    if (self.image_map.contains(image))
        return;

    const width = image.image.extent.width;
    const height = image.image.extent.height;

    metal.setDrawableSize(self.layer, @floatFromInt(width), @floatFromInt(height));

    const row_size = std.math.mul(usize, width, 4) catch return VkError.OutOfHostMemory;
    const size = std.math.mul(usize, row_size, height) catch return VkError.OutOfHostMemory;

    const metal_image = allocator.create(MetalImage) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(metal_image);

    const buffer = metal.newBuffer(self.device, size, metal.storage_mode_shared) orelse return VkError.OutOfDeviceMemory;
    errdefer metal.release(buffer);

    metal_image.* = .{
        .buffer = buffer,
        .row_size = row_size,
        .height = height,
    };

    self.image_map.put(allocator, image, metal_image) catch return VkError.OutOfHostMemory;
}

pub fn detachImage(interface: *Interface, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const entry = self.image_map.fetchRemove(image) orelse return;
    destroyMetalImage(allocator, entry.value);
}

pub fn waitForImage(_: *Interface, _: u64) VkError!void {}

pub fn presentImage(interface: *Interface, _: std.mem.Allocator, image: *PresentImage) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    errdefer image.state = .available;

    const pool = metal.objc_autoreleasePoolPush();
    defer metal.objc_autoreleasePoolPop(pool);

    try validateImageExtent(image, metal.naturalExtent(self.layer));
    const metal_image = self.image_map.get(image) orelse return VkError.Unknown;

    const drawable = metal.nextDrawable(self.layer) orelse {
        std.log.scoped(.MetalSurface).err("nextDrawable returned null (layer has no device or zero drawableSize)", .{});
        return VkError.NotReady;
    };
    defer metal.release(drawable);

    const texture = metal.drawableTexture(drawable) orelse return VkError.Unknown;
    try validateImageExtent(image, metal.textureExtent(texture));

    const mapped = metal.contents(metal_image.buffer) orelse return VkError.MemoryMapFailed;

    const size = std.math.mul(usize, metal_image.row_size, metal_image.height) catch return VkError.OutOfHostMemory;
    const data: [*]u8 = @ptrCast(mapped);
    try image.image.copyToMemory(data[0..size], .{
        .aspect_mask = .{ .color = true },
        .mip_level = 0,
        .base_array_layer = 0,
        .layer_count = 1,
    });

    const command_buffer = metal.newCommandBuffer(self.queue) orelse return VkError.OutOfHostMemory;
    defer metal.release(command_buffer);

    const blit = metal.blitCommandEncoder(command_buffer) orelse return VkError.OutOfHostMemory;

    metal.copyFromBufferToTexture(blit, metal_image.buffer, texture, metal_image.row_size, size, image.image.extent.width, metal_image.height);
    metal.endEncoding(blit);
    metal.presentDrawable(command_buffer, drawable);
    metal.commit(command_buffer);
    metal.waitUntilCompleted(command_buffer);
    image.state = .available;
}

fn validateImageExtent(image: *const PresentImage, extent: vk.Extent2D) VkError!void {
    if (extent.width == 0 or extent.height == 0 or extent.width != image.image.extent.width or extent.height != image.image.extent.height)
        return VkError.OutOfDateKhr;
}

fn destroyMetalImage(allocator: std.mem.Allocator, metal_image: *MetalImage) void {
    metal.release(metal_image.buffer);
    allocator.destroy(metal_image);
}
