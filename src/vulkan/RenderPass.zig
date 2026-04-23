const std = @import("std");
const vk = @import("vulkan");

const VulkanAllocator = @import("VulkanAllocator.zig");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .render_pass;

owner: *Device,
attachments: []vk.AttachmentDescription,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.RenderPassCreateInfo) VkError!Self {
    const object_allocator = VulkanAllocator.from(allocator).cloneWithScope(.object);

    const attachments = object_allocator.allocator().alloc(vk.AttachmentDescription, info.attachment_count) catch return VkError.OutOfHostMemory;
    errdefer object_allocator.allocator().free(attachments);

    if (info.p_attachments) |base_attachements| {
        for (base_attachements, attachments, 0..info.attachment_count) |base_attachment, *attachment, _| {
            attachment.* = base_attachment;
        }
    } else {
        return VkError.ValidationFailed;
    }

    return .{
        .owner = device,
        .attachments = attachments,
        .vtable = undefined,
    };
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.attachments);
    self.vtable.destroy(self, allocator);
}
