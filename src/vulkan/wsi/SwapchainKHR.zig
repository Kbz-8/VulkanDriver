const std = @import("std");
const vk = @import("vulkan");
const lib = @import("../lib.zig");

const VkError = @import("../error_set.zig").VkError;

const Device = @import("../Device.zig");
const SurfaceKHR = @import("SurfaceKHR.zig");
const PresentImage = @import("PresentImage.zig");
const Image = @import("../Image.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .swapchain_khr;

owner: *Device,
surface: *SurfaceKHR,
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
        .surface = undefined,
        .images = images,
    };
    return self;
}

pub fn getImage(self: *const Self, index: usize) VkError!*Image {
    return if (index < self.images.len) self.images[index].image else VkError.Incomplete;
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    for (self.images) |*image| {
        image.deinit(allocator);
    }
    allocator.destroy(self);
}
