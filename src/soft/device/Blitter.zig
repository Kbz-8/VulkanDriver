const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

pub const SoftImage = @import("../SoftImage.zig");
pub const SoftImageView = @import("../SoftImageView.zig");

const Self = @This();

blit_mutex: std.Thread.Mutex,

pub const init: Self = .{
    .blit_mutex = .{},
};

pub fn clear(self: *Self, pixel: *const anyopaque, format: vk.Format, dest: *SoftImage, view_format: vk.Format, range: vk.ImageSubresourceRange, area: ?vk.Rect2D) void {
    const dst_format = base.Image.formatFromAspect(view_format, range.aspect_mask);
    if (dst_format == .undefined) {
        return;
    }

    _ = self;
    _ = pixel;
    _ = format;
    _ = dest;
    _ = area;
}
