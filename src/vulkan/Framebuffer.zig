const std = @import("std");
const vk = @import("vulkan");

const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;
const VulkanAllocator = @import("VulkanAllocator.zig");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");
const ImageView = @import("ImageView.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .framebuffer;

owner: *Device,
width: usize,
height: usize,
layers: usize,
attachments: []*ImageView,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.FramebufferCreateInfo) VkError!Self {
    const object_allocator = VulkanAllocator.from(allocator).cloneWithScope(.object);

    const attachments = object_allocator.allocator().alloc(*ImageView, info.attachment_count) catch return VkError.OutOfHostMemory;
    errdefer object_allocator.allocator().free(attachments);

    if (info.p_attachments) |base_attachements| {
        for (base_attachements, attachments, 0..info.attachment_count) |base_attachment, *attachment, _| {
            attachment.* = try NonDispatchable(ImageView).fromHandleObject(base_attachment);
        }
    } else {
        return VkError.ValidationFailed;
    }

    return .{
        .owner = device,
        .width = @intCast(info.width),
        .height = @intCast(info.height),
        .layers = @intCast(info.layers),
        .attachments = attachments,
        .vtable = undefined,
    };
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.attachments);
    self.vtable.destroy(self, allocator);
}
