const std = @import("std");
const vk = @import("vulkan");
const lib = @import("../lib.zig");

const VkError = @import("../error_set.zig").VkError;

const BinarySemaphore = lib.BinarySemaphore;
const Device = @import("../Device.zig");
const Fence = lib.Fence;
const Image = lib.Image;
const PresentImage = @import("PresentImage.zig");
const SurfaceKHR = lib.SurfaceKHR;

const Self = @This();
pub const ObjectType: vk.ObjectType = .swapchain_khr;

owner: *Device,
surface: ?*SurfaceKHR,
images: []PresentImage,

pub fn create(device: *Device, allocator: std.mem.Allocator, info: *const vk.SwapchainCreateInfoKHR) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    const images = allocator.alloc(PresentImage, info.min_image_count) catch return VkError.OutOfHostMemory;
    errdefer {
        allocator.free(images);
    }

    for (images) |*image| {
        image.* = try .init(device, allocator, &.{
            .format = info.image_format,
            .image_type = .@"2d",
            .extent = .{
                .width = info.image_extent.width,
                .height = info.image_extent.height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = info.image_array_layers,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = info.image_usage,
            .sharing_mode = info.image_sharing_mode,
            .p_queue_family_indices = info.p_queue_family_indices,
            .queue_family_index_count = info.queue_family_index_count,
            .initial_layout = .general,
        });
    }

    self.* = .{
        .owner = device,
        .surface = null,
        .images = images,
    };
    return self;
}

pub fn getNextImage(self: *const Self, timeout: u64, semaphore: *BinarySemaphore, fence: *Fence, index: *u32) VkError!void {
    // TODO: handle timeout correctly

    for (self.images, 0..) |*image, i| {
        if (image.state == .Available) {
            image.state = .Drawing;
            index.* = @intCast(i);
            // TODO: signal semaphore
            _ = semaphore;
            try fence.signal();
            return;
        }
    }

    return if (timeout > 0) VkError.Timeout else VkError.NotReady;
}

pub fn present(self: *Self, index: usize) VkError!void {
    const allocator = self.owner.host_allocator.allocator();

    const image = &self.images[index];
    if (self.surface) |surface| {
        image.state = .Presenting;
        try surface.presentImage(allocator, image);
    }
}

pub fn detachSurface(self: *Self) VkError!void {
    const allocator = self.owner.host_allocator.allocator();

    if (self.surface) |surface| {
        surface.swapchain = null;
        for (self.images) |*image| {
            if (image.state == .Available)
                try surface.detachImage(allocator, image);
        }
    }
    self.surface = null;
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    if (self.surface) |surface| {
        for (self.images) |*image| {
            surface.detachImage(allocator, image) catch {};
            image.deinit(allocator);
        }
    }
    allocator.destroy(self);
}
