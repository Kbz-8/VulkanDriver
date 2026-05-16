const std = @import("std");
const vk = @import("vulkan");

const VulkanAllocator = @import("VulkanAllocator.zig");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .render_pass;

const SubpassDescription = struct {
    flags: vk.SubpassDescriptionFlags,
    pipeline_bind_point: vk.PipelineBindPoint,
    input_attachments: ?[]const vk.AttachmentReference,
    color_attachments: ?[]const vk.AttachmentReference,
    resolve_attachments: ?[]const vk.AttachmentReference,
    depth_stencil_attachments: ?vk.AttachmentReference,
    preserve_attachments: ?[]const u32,
};

owner: *Device,
attachments: []vk.AttachmentDescription,
subpasses: []SubpassDescription,

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

    const subpasses = allocator.alloc(SubpassDescription, info.subpass_count) catch return VkError.OutOfHostMemory;
    errdefer allocator.free(subpasses);

    for (subpasses[0..], info.p_subpasses[0..]) |*subpass, subpass_info| {
        subpass.* = .{
            .flags = subpass_info.flags,
            .pipeline_bind_point = subpass_info.pipeline_bind_point,
            .input_attachments = if (subpass_info.p_input_attachments) |subpass_attachments|
                allocator.dupe(vk.AttachmentReference, subpass_attachments[0..subpass_info.input_attachment_count]) catch return VkError.OutOfHostMemory
            else
                null,
            .color_attachments = if (subpass_info.p_color_attachments) |subpass_attachments|
                allocator.dupe(vk.AttachmentReference, subpass_attachments[0..subpass_info.color_attachment_count]) catch return VkError.OutOfHostMemory
            else
                null,
            .resolve_attachments = if (subpass_info.p_resolve_attachments) |subpass_attachments|
                allocator.dupe(vk.AttachmentReference, subpass_attachments[0..subpass_info.color_attachment_count]) catch return VkError.OutOfHostMemory
            else
                null,
            .depth_stencil_attachments = if (subpass_info.p_depth_stencil_attachment) |subpass_attachment|
                if (subpass_attachment.attachment != vk.ATTACHMENT_UNUSED) subpass_attachment.* else null
            else
                null,
            .preserve_attachments = if (subpass_info.p_preserve_attachments) |subpass_attachments|
                allocator.dupe(u32, subpass_attachments[0..subpass_info.preserve_attachment_count]) catch return VkError.OutOfHostMemory
            else
                null,
        };
    }

    return .{
        .owner = device,
        .attachments = attachments,
        .subpasses = subpasses,
        .vtable = undefined,
    };
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.attachments);
    for (self.subpasses[0..]) |subpass| {
        if (subpass.input_attachments) |attachments| allocator.free(attachments);
        if (subpass.color_attachments) |attachments| allocator.free(attachments);
        if (subpass.resolve_attachments) |attachments| allocator.free(attachments);
        if (subpass.preserve_attachments) |attachments| allocator.free(attachments);
    }
    allocator.free(self.subpasses);
    self.vtable.destroy(self, allocator);
}
