const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;

const blitter = @import("device/blitter.zig");

const SoftImage = @import("SoftImage.zig");
const SoftRenderPass = @import("SoftRenderPass.zig");

const Self = @This();
pub const Interface = base.Framebuffer;

interface: Interface,

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.FramebufferCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);

    interface.vtable = &.{
        .destroy = destroy,
    };

    self.* = .{
        .interface = interface,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn resolveAttachments(self: *Self, render_pass: *SoftRenderPass, subpass_index: usize) VkError!void {
    const subpass = render_pass.interface.subpasses[subpass_index];

    if (subpass.resolve_attachments) |resolve_attachments| {
        if (subpass.color_attachments) |color_attachments| {
            for (color_attachments[0..], resolve_attachments[0..]) |color, resolve| {
                if (resolve.attachment != vk.ATTACHMENT_UNUSED) {
                    const src_image_view = self.interface.attachments[color.attachment];
                    const src_image: *SoftImage = @alignCast(@fieldParentPtr("interface", src_image_view.image));

                    const dst_image_view = self.interface.attachments[resolve.attachment];
                    const dst_image: *SoftImage = @alignCast(@fieldParentPtr("interface", dst_image_view.image));

                    try blitter.resolveWithFormats(
                        src_image,
                        dst_image,
                        .{
                            .src_subresource = .{
                                .aspect_mask = src_image_view.subresource_range.aspect_mask,
                                .base_array_layer = src_image_view.subresource_range.base_array_layer,
                                .layer_count = src_image_view.layerCount(),
                                .mip_level = src_image_view.subresource_range.base_mip_level,
                            },
                            .src_offset = .{ .x = 0, .y = 0, .z = 0 },
                            .dst_subresource = .{
                                .aspect_mask = dst_image_view.subresource_range.aspect_mask,
                                .base_array_layer = dst_image_view.subresource_range.base_array_layer,
                                .layer_count = dst_image_view.layerCount(),
                                .mip_level = dst_image_view.subresource_range.base_mip_level,
                            },
                            .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
                            .extent = src_image.getMipLevelExtent(src_image_view.subresource_range.base_mip_level),
                        },
                        src_image_view.format,
                        dst_image_view.format,
                    );
                }
            }
        }
    }
}
