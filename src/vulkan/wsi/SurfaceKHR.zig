const std = @import("std");
const vk = @import("vulkan");
const lib = @import("../lib.zig");

const VkError = @import("../error_set.zig").VkError;

const Device = @import("../Device.zig");
const PresentImage = @import("PresentImage.zig");
const SwapchainKHR = @import("SwapchainKHR.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .surface_khr;

const formats = [_]vk.SurfaceFormatKHR{
    .{ .format = .b8g8r8a8_unorm, .color_space = .srgb_nonlinear_khr },
    .{ .format = .b8g8r8a8_srgb, .color_space = .srgb_nonlinear_khr },
};

const present_modes = [_]vk.PresentModeKHR{
    .immediate_khr,
};

owner: *Device,
swapchain: ?*SwapchainKHR,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
    getCapabilities: *const fn (*const Self, *vk.SurfaceCapabilitiesKHR) VkError!void,
    attachImage: *const fn (*Self, std.mem.Allocator, *PresentImage) VkError!void,
    detachImage: *const fn (*Self, std.mem.Allocator, *PresentImage) VkError!void,
    presentImage: *const fn (*Self, std.mem.Allocator, *PresentImage) VkError!void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator) VkError!Self {
    _ = allocator;
    return .{
        .owner = device,
        .swapchain = null,
        .vtable = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}

pub fn getCapabilities(self: *const Self) VkError!vk.SurfaceCapabilitiesKHR {
    var capabilities: vk.SurfaceCapabilitiesKHR = .{
        .min_image_count = 1,
        .max_image_count = 0,
        .current_extent = .{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) },
        .min_image_extent = .{ .width = 1, .height = 1 },
        .max_image_extent = .{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) },
        .max_image_array_layers = 1,
        .supported_transforms = .{ .identity_bit_khr = true },
        .current_transform = .{ .identity_bit_khr = true },
        .supported_composite_alpha = .{ .opaque_bit_khr = true },
        .supported_usage_flags = .{
            .color_attachment_bit = true,
            .input_attachment_bit = true,
            .transfer_src_bit = true,
            .transfer_dst_bit = true,
            .sampled_bit = true,
            .storage_bit = true,
        },
    };

    try self.vtable.getCapabilities(self, &capabilities);
    return capabilities;
}

pub inline fn attachImage(self: *Self, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    try self.vtable.attachImage(self, allocator, image);
}

pub inline fn detachImage(self: *Self, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    try self.vtable.detachImage(self, allocator, image);
}

pub inline fn presentImage(self: *Self, allocator: std.mem.Allocator, image: *PresentImage) VkError!void {
    try self.vtable.presentImage(self, allocator, image);
}

pub inline fn getFormats() []vk.SurfaceFormatKHR {
    return formats;
}

pub inline fn getPresentModes() []vk.PresentModeKHR {
    return present_modes;
}
