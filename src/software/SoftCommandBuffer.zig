const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("lib.zig");

const VkError = base.VkError;

const SoftBuffer = @import("SoftBuffer.zig");
const SoftDescriptorSet = @import("SoftDescriptorSet.zig");
const SoftFramebuffer = @import("SoftFramebuffer.zig");
const SoftImage = @import("SoftImage.zig");
const SoftPipeline = @import("SoftPipeline.zig");
const SoftRenderPass = @import("SoftRenderPass.zig");

const ExecutionDevice = @import("device/Device.zig");
const blitter = @import("device/blitter.zig");

const Self = @This();
pub const Interface = base.CommandBuffer;

const Command = struct {
    const VTable = struct {
        execute: *const fn (*anyopaque, *ExecutionDevice) VkError!void,
    };

    ptr: *anyopaque,
    vtable: *const VTable,
};

interface: Interface,

command_allocator: std.heap.ArenaAllocator,
commands: std.ArrayList(Command),

fn attachmentIsReferencedBySubpass(render_pass: *SoftRenderPass, attachment_index: u32) bool {
    for (render_pass.interface.subpasses) |subpass| {
        if (subpass.input_attachments) |attachments| {
            for (attachments) |attachment| {
                if (attachment.attachment == attachment_index)
                    return true;
            }
        }

        if (subpass.color_attachments) |attachments| {
            for (attachments) |attachment| {
                if (attachment.attachment == attachment_index)
                    return true;
            }
        }

        if (subpass.resolve_attachments) |attachments| {
            for (attachments) |attachment| {
                if (attachment.attachment == attachment_index)
                    return true;
            }
        }

        if (subpass.depth_stencil_attachments) |attachment| {
            if (attachment.attachment == attachment_index)
                return true;
        }
    }

    return false;
}

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.CommandBufferAllocateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);

    interface.vtable = &.{
        .destroy = destroy,
    };

    interface.dispatch_table = &.{
        .begin = begin,
        .beginQuery = beginQuery,
        .beginRenderPass = beginRenderPass,
        .bindDescriptorSets = bindDescriptorSets,
        .bindPipeline = bindPipeline,
        .bindIndexBuffer = bindIndexBuffer,
        .bindVertexBuffer = bindVertexBuffer,
        .blitImage = blitImage,
        .clearAttachment = clearAttachment,
        .clearColorImage = clearColorImage,
        .clearDepthStencilImage = clearDepthStencilImage,
        .copyBuffer = copyBuffer,
        .copyBufferToImage = copyBufferToImage,
        .copyImage = copyImage,
        .copyImageToBuffer = copyImageToBuffer,
        .copyQueryPoolResults = copyQueryPoolResults,
        .dispatch = dispatch,
        .dispatchBase = dispatchBase,
        .dispatchIndirect = dispatchIndirect,
        .draw = draw,
        .drawIndexed = drawIndexed,
        .drawIndexedIndirect = drawIndexedIndirect,
        .drawIndirect = drawIndirect,
        .end = end,
        .endQuery = endQuery,
        .endRenderPass = endRenderPass,
        .executeCommands = executeCommands,
        .fillBuffer = fillBuffer,
        .nextSubpass = nextSubpass,
        .pipelineBarrier = pipelineBarrier,
        .pushConstants = pushConstants,
        .reset = reset,
        .resetQueryPool = resetQueryPool,
        .resetEvent = resetEvent,
        .resolveImage = resolveImage,
        .setEvent = setEvent,
        .setBlendConstants = setBlendConstants,
        .setDepthBias = setDepthBias,
        .setDepthBounds = setDepthBounds,
        .setDeviceMask = setDeviceMask,
        .setLineWidth = setLineWidth,
        .setScissor = setScissor,
        .setStencilCompareMask = setStencilCompareMask,
        .setStencilReference = setStencilReference,
        .setStencilWriteMask = setStencilWriteMask,
        .setViewport = setViewport,
        .updateBuffer = updateBuffer,
        .waitEvent = waitEvent,
        .writeTimestamp = writeTimestamp,
    };

    self.* = .{
        .interface = interface,
        .command_allocator = undefined,
        .commands = .empty,
    };
    self.command_allocator = .init(self.interface.host_allocator.allocator());
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    _ = self.command_allocator.reset(.free_all);
    allocator.destroy(self);
}

pub fn execute(self: *Self, device: *ExecutionDevice) VkError!void {
    try self.interface.submit();
    defer self.interface.finish() catch @panic("Caught an error while handling an error");

    for (self.commands.items) |command| {
        command.vtable.execute(@ptrCast(command.ptr), device) catch |err| {
            base.errors.errorLoggerContext(err, "the software execution device");
            if (comptime base.config.logs == .verbose) {
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
            }
            return VkError.DeviceLost;
        };
    }
}

pub fn begin(interface: *Interface, _: *const vk.CommandBufferBeginInfo) VkError!void {
    // No-op
    _ = interface;
}

pub fn end(interface: *Interface) VkError!void {
    // No-op
    _ = interface;
}

pub fn reset(interface: *Interface, _: vk.CommandBufferResetFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.commands.clearAndFree(self.command_allocator.allocator());
    _ = self.command_allocator.reset(.free_all);
}

// Commands ====================================================================================================

pub fn beginQuery(interface: *Interface, pool: *base.QueryPool, query: u32, _: vk.QueryControlFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        pool: *base.QueryPool,
        query: u32,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            try impl.pool.begin(impl.query);
            if (impl.pool.query_type == .occlusion) {
                for (device.active_occlusion_queries.items) |active| {
                    if (active.pool == impl.pool and active.query == impl.query)
                        return;
                }
                device.active_occlusion_queries.append(device.renderer.device.interface.device_allocator.allocator(), .{
                    .pool = impl.pool,
                    .query = impl.query,
                }) catch return VkError.OutOfDeviceMemory;
            }
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .pool = pool,
        .query = query,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn endQuery(interface: *Interface, pool: *base.QueryPool, query: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        pool: *base.QueryPool,
        query: u32,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            try impl.pool.end(impl.query);

            var i: usize = 0;
            while (i < device.active_occlusion_queries.items.len) {
                const active = device.active_occlusion_queries.items[i];
                if (active.pool == impl.pool and active.query == impl.query) {
                    _ = device.active_occlusion_queries.swapRemove(i);
                    continue;
                }
                i += 1;
            }
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .pool = pool,
        .query = query,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn resetQueryPool(interface: *Interface, pool: *base.QueryPool, first: u32, count: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        pool: *base.QueryPool,
        first: u32,
        count: u32,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            try impl.pool.reset(impl.first, impl.count);

            var i: usize = 0;
            while (i < device.active_occlusion_queries.items.len) {
                const active = device.active_occlusion_queries.items[i];
                if (active.pool == impl.pool and
                    active.query >= impl.first and
                    active.query < impl.first + impl.count)
                {
                    _ = device.active_occlusion_queries.swapRemove(i);
                    continue;
                }
                i += 1;
            }
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .pool = pool,
        .first = first,
        .count = count,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn writeTimestamp(interface: *Interface, stage: vk.PipelineStageFlags, pool: *base.QueryPool, query: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        stage: vk.PipelineStageFlags,
        pool: *base.QueryPool,
        query: u32,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            _ = impl.stage;
            const io = device.renderer.device.interface.io();
            const now = std.Io.Timestamp.now(io, .real).toNanoseconds();
            try impl.pool.writeTimestamp(impl.query, if (now > 0) @intCast(now) else 0);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .stage = stage,
        .pool = pool,
        .query = query,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn beginRenderPass(interface: *Interface, render_pass: *base.RenderPass, framebuffer: *base.Framebuffer, render_area: vk.Rect2D, clear_values: ?[]const vk.ClearValue) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        render_pass: *SoftRenderPass,
        framebuffer: *SoftFramebuffer,
        render_area: vk.Rect2D,
        clear_values: ?[]const vk.ClearValue,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            device.renderer.render_pass = impl.render_pass;
            device.renderer.framebuffer = impl.framebuffer;
            device.renderer.render_area = impl.render_area;
            device.renderer.subpass_index = 0;
            device.renderer.resetInputAttachmentSnapshots();

            for (impl.render_pass.interface.attachments, impl.framebuffer.interface.attachments, 0..) |desc, attachment, index| {
                if (!attachmentIsReferencedBySubpass(impl.render_pass, @intCast(index)))
                    continue;

                const image: *SoftImage = @alignCast(@fieldParentPtr("interface", attachment.image));
                var clear_mask: vk.ImageAspectFlags = .{};

                switch (desc.load_op) {
                    .clear => clear_mask = .{ .color_bit = true, .depth_bit = true },
                    else => {},
                }

                switch (desc.stencil_load_op) {
                    .clear => clear_mask.stencil_bit = true,
                    else => {},
                }

                clear_mask = clear_mask.intersect(base.format.toAspect(attachment.format));

                if (clear_mask.toInt() != 0) {
                    if (clear_mask.color_bit) {
                        try blitter.clear(
                            (impl.clear_values orelse return VkError.Unknown)[index],
                            try SoftImage.getClearFormatFor(attachment.format),
                            image,
                            attachment.format,
                            attachment.subresource_range,
                            impl.render_area,
                        );
                    } else {
                        var subresource_range = attachment.subresource_range;

                        if (clear_mask.depth_bit) {
                            subresource_range.aspect_mask = .{ .depth_bit = true };
                            try blitter.clear(
                                (impl.clear_values orelse return VkError.Unknown)[index],
                                .d32_sfloat,
                                image,
                                attachment.format,
                                subresource_range,
                                impl.render_area,
                            );
                        }

                        if (clear_mask.stencil_bit) {
                            subresource_range.aspect_mask = .{ .stencil_bit = true };
                            try blitter.clear(
                                (impl.clear_values orelse return VkError.Unknown)[index],
                                .s8_uint,
                                image,
                                attachment.format,
                                subresource_range,
                                impl.render_area,
                            );
                        }
                    }
                }
            }
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .render_pass = @alignCast(@fieldParentPtr("interface", render_pass)),
        .framebuffer = @alignCast(@fieldParentPtr("interface", framebuffer)),
        .render_area = render_area,
        .clear_values = if (clear_values) |values| allocator.dupe(vk.ClearValue, values) catch return VkError.OutOfHostMemory else null, // Will be freed on cmdbuf reset or destroy
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn bindDescriptorSets(interface: *Interface, bind_point: vk.PipelineBindPoint, first_set: u32, sets: [base.vulkan_max_descriptor_sets]?*base.DescriptorSet, dynamic_offsets: []const u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        bind_point: vk.PipelineBindPoint,
        first_set: u32,
        sets: [base.vulkan_max_descriptor_sets]?*base.DescriptorSet,
        dynamic_offsets: []const u32,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            var dynamic_offset_index: usize = 0;
            for (impl.first_set.., impl.sets[0..]) |i, set| {
                if (set == null)
                    break;
                const state = &device.pipeline_states[@intCast(@intFromEnum(impl.bind_point))];
                const soft_set: *SoftDescriptorSet = @alignCast(@fieldParentPtr("interface", set.?));
                state.sets[i] = soft_set;

                const dynamic_count = soft_set.interface.layout.dynamic_descriptor_count;
                if (dynamic_count > ExecutionDevice.max_dynamic_descriptors_per_set or
                    dynamic_offset_index + dynamic_count > impl.dynamic_offsets.len)
                {
                    return VkError.ValidationFailed;
                }
                @memcpy(
                    state.dynamic_offsets[i][0..dynamic_count],
                    impl.dynamic_offsets[dynamic_offset_index .. dynamic_offset_index + dynamic_count],
                );
                dynamic_offset_index += dynamic_count;
            }
        }
    };

    const dynamic_offsets_copy = allocator.dupe(u32, dynamic_offsets) catch return VkError.OutOfHostMemory;
    errdefer allocator.free(dynamic_offsets_copy);

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .bind_point = bind_point,
        .first_set = first_set,
        .sets = sets,
        .dynamic_offsets = dynamic_offsets_copy,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn bindPipeline(interface: *Interface, bind_point: vk.PipelineBindPoint, pipeline: *base.Pipeline) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        bind_point: vk.PipelineBindPoint,
        pipeline: *SoftPipeline,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            device.pipeline_states[@intCast(@intFromEnum(impl.bind_point))].pipeline = impl.pipeline;
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .bind_point = bind_point,
        .pipeline = @alignCast(@fieldParentPtr("interface", pipeline)),
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn bindIndexBuffer(interface: *Interface, buffer: *base.Buffer, offset: usize, index_type: vk.IndexType) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        buffer: *const SoftBuffer,
        offset: usize,
        index_type: vk.IndexType,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            device.pipeline_states[ExecutionDevice.graphics_pipeline_state].data.graphics.index_buffer = .{
                .buffer = impl.buffer,
                .offset = impl.offset,
                .index_type = impl.index_type,
            };
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .buffer = @alignCast(@fieldParentPtr("interface", buffer)),
        .offset = offset,
        .index_type = index_type,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn bindVertexBuffer(interface: *Interface, index: usize, buffer: *base.Buffer, offset: usize) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        buffer: *const SoftBuffer,
        offset: usize,
        index: usize,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            device.pipeline_states[ExecutionDevice.graphics_pipeline_state].data.graphics.vertex_buffers[impl.index] = .{
                .buffer = impl.buffer,
                .offset = impl.offset,
                .size = 0,
            };
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .buffer = @alignCast(@fieldParentPtr("interface", buffer)),
        .offset = offset,
        .index = index,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn blitImage(interface: *Interface, src: *base.Image, _: vk.ImageLayout, dst: *base.Image, _: vk.ImageLayout, regions: []const vk.ImageBlit, filter: vk.Filter) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        src: *const SoftImage,
        dst: *SoftImage,
        regions: []const vk.ImageBlit,
        filter: vk.Filter,

        pub fn execute(context: *anyopaque, _: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            for (impl.regions[0..]) |region| {
                try blitter.blitRegion(impl.src, impl.dst, region, impl.filter);
            }
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .src = @alignCast(@fieldParentPtr("interface", src)),
        .dst = @alignCast(@fieldParentPtr("interface", dst)),
        .regions = allocator.dupe(vk.ImageBlit, regions) catch return VkError.OutOfHostMemory, // Will be freed on cmdbuf reset or destroy
        .filter = filter,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn clearAttachment(interface: *Interface, attachment: vk.ClearAttachment, rect: vk.ClearRect) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        attachment: vk.ClearAttachment,
        rect: vk.ClearRect,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));

            const framebuffer = device.renderer.framebuffer orelse return;
            const render_pass = device.renderer.render_pass orelse return;
            const subpass = render_pass.interface.subpasses[device.renderer.subpass_index];

            const image_view = blk: {
                if (impl.attachment.aspect_mask.toInt() == (vk.ImageAspectFlags{ .color_bit = true }).toInt()) {
                    const fb_attachment_index = (subpass.color_attachments orelse return)[impl.attachment.color_attachment].attachment;

                    if (fb_attachment_index != vk.ATTACHMENT_UNUSED)
                        break :blk framebuffer.interface.attachments[fb_attachment_index];
                } else if (impl.attachment.aspect_mask.depth_bit or impl.attachment.aspect_mask.stencil_bit) {
                    if (render_pass.interface.subpasses[device.renderer.subpass_index].depth_stencil_attachments) |desc| {
                        if (desc.attachment != vk.ATTACHMENT_UNUSED)
                            break :blk framebuffer.interface.attachments[desc.attachment];
                    }
                }
                return;
            };

            const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.image));
            const clear_format = try SoftImage.getClearFormatFor(image_view.format);

            const range: vk.ImageSubresourceRange = .{
                .aspect_mask = impl.attachment.aspect_mask,
                .base_mip_level = image_view.subresource_range.base_mip_level,
                .level_count = image_view.subresource_range.level_count,
                .base_array_layer = impl.rect.base_array_layer + image_view.subresource_range.base_array_layer,
                .layer_count = impl.rect.layer_count,
            };

            try blitter.clear(
                impl.attachment.clear_value,
                clear_format,
                image,
                image_view.format,
                range,
                impl.rect.rect,
            );
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .attachment = attachment,
        .rect = rect,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn clearColorImage(interface: *Interface, image: *base.Image, _: vk.ImageLayout, color: *const vk.ClearColorValue, range: vk.ImageSubresourceRange) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        image: *SoftImage,
        clear_color: vk.ClearColorValue,
        range: vk.ImageSubresourceRange,

        pub fn execute(context: *anyopaque, _: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            const clear_format = try impl.image.getClearFormat();
            try blitter.clear(.{ .color = impl.clear_color }, clear_format, impl.image, impl.image.interface.format, impl.range, null);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .image = @alignCast(@fieldParentPtr("interface", image)),
        .clear_color = color.*,
        .range = range,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn clearDepthStencilImage(interface: *Interface, image: *base.Image, _: vk.ImageLayout, value: *const vk.ClearDepthStencilValue, range: vk.ImageSubresourceRange) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        image: *SoftImage,
        value: vk.ClearDepthStencilValue,
        range: vk.ImageSubresourceRange,

        pub fn execute(context: *anyopaque, _: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            const clear_format = try impl.image.getClearFormat();
            try blitter.clear(.{ .depth_stencil = impl.value }, clear_format, impl.image, impl.image.interface.format, impl.range, null);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .image = @alignCast(@fieldParentPtr("interface", image)),
        .value = value.*,
        .range = range,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn copyBuffer(interface: *Interface, src: *base.Buffer, dst: *base.Buffer, regions: []const vk.BufferCopy) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        src: *const SoftBuffer,
        dst: *SoftBuffer,
        regions: []const vk.BufferCopy,

        pub fn execute(context: *anyopaque, _: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            try impl.src.copyBuffer(impl.dst, impl.regions);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .src = @alignCast(@fieldParentPtr("interface", src)),
        .dst = @alignCast(@fieldParentPtr("interface", dst)),
        .regions = allocator.dupe(vk.BufferCopy, regions) catch return VkError.OutOfHostMemory, // Will be freed on cmdbuf reset or destroy
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn copyBufferToImage(interface: *Interface, src: *base.Buffer, dst: *base.Image, dst_layout: vk.ImageLayout, regions: []const vk.BufferImageCopy) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        src: *const SoftBuffer,
        dst: *SoftImage,
        dst_layout: vk.ImageLayout,
        regions: []const vk.BufferImageCopy,

        pub fn execute(context: *anyopaque, _: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            for (impl.regions[0..]) |region| {
                try impl.dst.copyFromBuffer(impl.src, region);
            }
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .src = @alignCast(@fieldParentPtr("interface", src)),
        .dst_layout = dst_layout,
        .dst = @alignCast(@fieldParentPtr("interface", dst)),
        .regions = allocator.dupe(vk.BufferImageCopy, regions) catch return VkError.OutOfHostMemory, // Will be freed on cmdbuf reset or destroy
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn copyImage(interface: *Interface, src: *base.Image, _: vk.ImageLayout, dst: *base.Image, _: vk.ImageLayout, regions: []const vk.ImageCopy) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        src: *const SoftImage,
        dst: *SoftImage,
        regions: []const vk.ImageCopy,

        pub fn execute(context: *anyopaque, _: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            for (impl.regions[0..]) |region| {
                try impl.src.copyToImage(impl.dst, region);
            }
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .src = @alignCast(@fieldParentPtr("interface", src)),
        .dst = @alignCast(@fieldParentPtr("interface", dst)),
        .regions = allocator.dupe(vk.ImageCopy, regions) catch return VkError.OutOfHostMemory, // Will be freed on cmdbuf reset or destroy
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn copyImageToBuffer(interface: *Interface, src: *base.Image, src_layout: vk.ImageLayout, dst: *base.Buffer, regions: []const vk.BufferImageCopy) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        src: *const SoftImage,
        src_layout: vk.ImageLayout,
        dst: *SoftBuffer,
        regions: []const vk.BufferImageCopy,

        pub fn execute(context: *anyopaque, _: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            for (impl.regions[0..]) |region| {
                try impl.src.copyToBuffer(impl.dst, region);
            }
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .src = @alignCast(@fieldParentPtr("interface", src)),
        .src_layout = src_layout,
        .dst = @alignCast(@fieldParentPtr("interface", dst)),
        .regions = allocator.dupe(vk.BufferImageCopy, regions) catch return VkError.OutOfHostMemory, // Will be freed on cmdbuf reset or destroy
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn copyQueryPoolResults(interface: *Interface, pool: *base.QueryPool, first: u32, count: u32, dst: *base.Buffer, offset: vk.DeviceSize, stride: vk.DeviceSize, flags: vk.QueryResultFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        pool: *base.QueryPool,
        dst: *SoftBuffer,
        first: u32,
        count: u32,
        offset: vk.DeviceSize,
        stride: vk.DeviceSize,
        flags: vk.QueryResultFlags,

        pub fn execute(context: *anyopaque, _: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            const value_size: vk.DeviceSize = if (impl.flags.@"64_bit") 8 else 4;
            const item_size = value_size * (1 + @as(vk.DeviceSize, @intFromBool(impl.flags.with_availability_bit)));
            const byte_size = if (impl.count == 0) 0 else (impl.count - 1) * impl.stride + item_size;
            const map = try impl.dst.mapAsSliceWithAddedOffset(u8, impl.offset, byte_size);
            try impl.pool.copyResults(impl.first, impl.count, map, impl.stride, impl.flags);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .pool = pool,
        .dst = @alignCast(@fieldParentPtr("interface", dst)),
        .first = first,
        .count = count,
        .offset = offset,
        .stride = stride,
        .flags = flags,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn dispatch(interface: *Interface, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    try dispatchBase(interface, 0, 0, 0, group_count_x, group_count_y, group_count_z);
}

pub fn dispatchBase(interface: *Interface, base_group_x: u32, base_group_y: u32, base_group_z: u32, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        base_group_x: u32,
        base_group_y: u32,
        base_group_z: u32,
        group_count_x: u32,
        group_count_y: u32,
        group_count_z: u32,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            try device.compute.dispatchBase(impl.base_group_x, impl.base_group_y, impl.base_group_z, impl.group_count_x, impl.group_count_y, impl.group_count_z);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .base_group_x = base_group_x,
        .base_group_y = base_group_y,
        .base_group_z = base_group_z,
        .group_count_x = group_count_x,
        .group_count_y = group_count_y,
        .group_count_z = group_count_z,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn setDeviceMask(_: *Interface, device_mask: u32) VkError!void {
    if (device_mask != 1) return VkError.ValidationFailed;
}

pub fn dispatchIndirect(interface: *Interface, buffer: *base.Buffer, offset: vk.DeviceSize) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        buffer: *SoftBuffer,
        offset: vk.DeviceSize,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            const command = try impl.buffer.mapToWithAddedOffset(vk.DispatchIndirectCommand, impl.offset);
            try device.compute.dispatch(command.x, command.y, command.z);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .buffer = @alignCast(@fieldParentPtr("interface", buffer)),
        .offset = offset,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn draw(interface: *Interface, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        vertex_count: usize,
        first_vertex: usize,
        instance_count: usize,
        first_instance: usize,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            try device.renderer.draw(impl.vertex_count, impl.instance_count, impl.first_vertex, impl.first_instance);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .vertex_count = vertex_count,
        .first_vertex = first_vertex,
        .instance_count = instance_count,
        .first_instance = first_instance,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn drawIndexed(interface: *Interface, index_count: usize, instance_count: usize, first_index: usize, vertex_offset: i32, first_instance: usize) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        index_count: usize,
        first_index: usize,
        instance_count: usize,
        first_instance: usize,
        vertex_offset: i32,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            try device.renderer.drawIndexed(impl.index_count, impl.instance_count, impl.first_index, impl.first_instance, impl.vertex_offset);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .index_count = index_count,
        .first_index = first_index,
        .instance_count = instance_count,
        .first_instance = first_instance,
        .vertex_offset = vertex_offset,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn drawIndexedIndirect(interface: *Interface, buffer: *base.Buffer, offset: usize, count: usize, stride: usize) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        buffer: *SoftBuffer,
        offset: usize,
        count: usize,
        stride: usize,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            for (0..impl.count) |index| {
                const command = try impl.buffer.mapToWithAddedOffset(vk.DrawIndexedIndirectCommand, impl.offset + index * impl.stride);
                try device.renderer.drawIndexed(command.index_count, command.instance_count, command.first_index, command.first_instance, command.vertex_offset);
            }
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .buffer = @alignCast(@fieldParentPtr("interface", buffer)),
        .offset = offset,
        .count = count,
        .stride = stride,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn drawIndirect(interface: *Interface, buffer: *base.Buffer, offset: usize, count: usize, stride: usize) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        buffer: *SoftBuffer,
        offset: usize,
        count: usize,
        stride: usize,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            for (0..impl.count) |index| {
                const command = try impl.buffer.mapToWithAddedOffset(vk.DrawIndirectCommand, impl.offset + index * impl.stride);
                try device.renderer.draw(command.vertex_count, command.instance_count, command.first_vertex, command.first_instance);
            }
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .buffer = @alignCast(@fieldParentPtr("interface", buffer)),
        .offset = offset,
        .count = count,
        .stride = stride,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn endRenderPass(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        pub fn execute(_: *anyopaque, device: *ExecutionDevice) VkError!void {
            const framebuffer = device.renderer.framebuffer orelse return;
            const render_pass = device.renderer.render_pass orelse return;

            try framebuffer.resolveAttachments(render_pass, device.renderer.subpass_index);

            device.renderer.resetInputAttachmentSnapshots();
            device.renderer.render_pass = null;
            device.renderer.framebuffer = null;
            device.renderer.render_area = null;
        }
    };

    self.commands.append(allocator, .{
        // SAFETY: this command's execute callback does not inspect its context pointer.
        .ptr = undefined,
        .vtable = &.{ .execute = CommandImpl.execute },
    }) catch return VkError.OutOfHostMemory;
}

pub fn executeCommands(interface: *Interface, commands: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        cmd: *Self,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            try impl.cmd.execute(device);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .cmd = @alignCast(@fieldParentPtr("interface", commands)),
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn fillBuffer(interface: *Interface, buffer: *base.Buffer, offset: vk.DeviceSize, size: vk.DeviceSize, data: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        buffer: *SoftBuffer,
        offset: vk.DeviceSize,
        size: vk.DeviceSize,
        data: u32,

        pub fn execute(context: *anyopaque, _: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            try impl.buffer.fillBuffer(impl.offset, impl.size, impl.data);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .buffer = @alignCast(@fieldParentPtr("interface", buffer)),
        .offset = offset,
        .size = size,
        .data = data,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn updateBuffer(interface: *Interface, buffer: *base.Buffer, offset: vk.DeviceSize, data: []const u8) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        buffer: *SoftBuffer,
        offset: vk.DeviceSize,
        data: []const u8,

        pub fn execute(context: *anyopaque, _: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            const map = try impl.buffer.mapAsSliceWithAddedOffset(u8, impl.offset, impl.data.len);
            @memcpy(map, impl.data);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);

    const data_copy = allocator.dupe(u8, data) catch return VkError.OutOfHostMemory;
    cmd.* = .{
        .buffer = @alignCast(@fieldParentPtr("interface", buffer)),
        .offset = offset,
        .data = data_copy,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn nextSubpass(interface: *Interface, _: vk.SubpassContents) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        pub fn execute(_: *anyopaque, device: *ExecutionDevice) VkError!void {
            const framebuffer = device.renderer.framebuffer orelse return;
            const render_pass = device.renderer.render_pass orelse return;

            try framebuffer.resolveAttachments(render_pass, device.renderer.subpass_index);

            device.renderer.resetInputAttachmentSnapshots();
            device.renderer.subpass_index += 1;
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{};
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn pipelineBarrier(_: *Interface, _: vk.PipelineStageFlags, _: vk.PipelineStageFlags, _: vk.DependencyFlags, _: []const vk.MemoryBarrier, _: []const vk.BufferMemoryBarrier, _: []const vk.ImageMemoryBarrier) VkError!void {
    // No-op
}

pub fn pushConstants(interface: *Interface, stages: vk.ShaderStageFlags, offset: u32, blob: []const u8) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        stages: vk.ShaderStageFlags,
        offset: u32,
        blob: []const u8,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            const size = @min(lib.push_constant_size - impl.offset, impl.blob.len);

            if (impl.stages.vertex_bit or
                impl.stages.tessellation_control_bit or
                impl.stages.tessellation_evaluation_bit or
                impl.stages.geometry_bit or
                impl.stages.fragment_bit)
            {
                const state = &device.pipeline_states[ExecutionDevice.graphics_pipeline_state];
                @memcpy(state.push_constant_blob[impl.offset .. impl.offset + size], impl.blob[0..size]);
            }

            if (impl.stages.compute_bit) {
                const state = &device.pipeline_states[ExecutionDevice.compute_pipeline_state];
                @memcpy(state.push_constant_blob[impl.offset .. impl.offset + size], impl.blob[0..size]);
            }
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .stages = stages,
        .offset = offset,
        .blob = allocator.dupe(u8, blob) catch return VkError.OutOfHostMemory, // Will be freed on cmdbuf reset or destroy
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn resetEvent(interface: *Interface, event: *base.Event, _: vk.PipelineStageFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        event: *base.Event,

        pub fn execute(context: *anyopaque, _: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            try impl.event.reset();
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .event = event,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn resolveImage(interface: *Interface, src: *base.Image, _: vk.ImageLayout, dst: *base.Image, _: vk.ImageLayout, region: vk.ImageResolve) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        src: *const SoftImage,
        dst: *SoftImage,
        region: vk.ImageResolve,

        pub fn execute(context: *anyopaque, _: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            try blitter.resolve(impl.src, impl.dst, impl.region);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .src = @alignCast(@fieldParentPtr("interface", src)),
        .dst = @alignCast(@fieldParentPtr("interface", dst)),
        .region = region,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn setEvent(interface: *Interface, event: *base.Event, stage: vk.PipelineStageFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    _ = stage;

    const CommandImpl = struct {
        const Impl = @This();

        event: *base.Event,

        pub fn execute(context: *anyopaque, _: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            try impl.event.signal();
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .event = event,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn setScissor(interface: *Interface, first: u32, scissor: []const vk.Rect2D) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        first: u32,
        scissor: []const vk.Rect2D,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            device.renderer.dynamic_state.scissor = impl.scissor; // Unsafe
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .first = first,
        .scissor = allocator.dupe(vk.Rect2D, scissor) catch return VkError.OutOfHostMemory, // Will be freed on cmdbuf reset or destroy
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn setViewport(interface: *Interface, first: u32, viewports: []const vk.Viewport) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        first: u32,
        viewports: []const vk.Viewport,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            device.renderer.dynamic_state.viewports = impl.viewports; // Unsafe
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .first = first,
        .viewports = allocator.dupe(vk.Viewport, viewports) catch return VkError.OutOfHostMemory, // Will be freed on cmdbuf reset or destroy
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn setBlendConstants(interface: *Interface, constants: [4]f32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        constants: [4]f32,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            device.renderer.dynamic_state.blend_constants = impl.constants;
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{ .constants = constants };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn setDepthBias(interface: *Interface, constant_factor: f32, clamp: f32, slope_factor: f32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        depth_bias: @import("device/Renderer.zig").DepthBias,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            device.renderer.dynamic_state.depth_bias = impl.depth_bias;
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .depth_bias = .{
            .constant_factor = constant_factor,
            .clamp = clamp,
            .slope_factor = slope_factor,
        },
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn setDepthBounds(interface: *Interface, min: f32, max: f32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        depth_bounds: @import("device/Renderer.zig").DepthBounds,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            device.renderer.dynamic_state.depth_bounds = impl.depth_bounds;
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{ .depth_bounds = .{ .min = min, .max = max } };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn setLineWidth(interface: *Interface, width: f32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        width: f32,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            device.renderer.dynamic_state.line_width = impl.width;
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{ .width = width };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn setStencilCompareMask(interface: *Interface, face_mask: vk.StencilFaceFlags, compare_mask: u32) VkError!void {
    try setStencilDynamicState(interface, face_mask, compare_mask, .compare_mask);
}

pub fn setStencilReference(interface: *Interface, face_mask: vk.StencilFaceFlags, reference: u32) VkError!void {
    try setStencilDynamicState(interface, face_mask, reference, .reference);
}

pub fn setStencilWriteMask(interface: *Interface, face_mask: vk.StencilFaceFlags, write_mask: u32) VkError!void {
    try setStencilDynamicState(interface, face_mask, write_mask, .write_mask);
}

fn setStencilDynamicState(interface: *Interface, face_mask: vk.StencilFaceFlags, value: u32, comptime kind: enum { compare_mask, reference, write_mask }) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        face_mask: vk.StencilFaceFlags,
        value: u32,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            if (!impl.face_mask.front_bit and !impl.face_mask.back_bit)
                return;
            switch (kind) {
                .compare_mask => {
                    if (impl.face_mask.front_bit)
                        device.renderer.dynamic_state.stencil_front_compare_mask = impl.value;
                    if (impl.face_mask.back_bit)
                        device.renderer.dynamic_state.stencil_back_compare_mask = impl.value;
                },
                .reference => {
                    if (impl.face_mask.front_bit)
                        device.renderer.dynamic_state.stencil_front_reference = impl.value;
                    if (impl.face_mask.back_bit)
                        device.renderer.dynamic_state.stencil_back_reference = impl.value;
                },
                .write_mask => {
                    if (impl.face_mask.front_bit)
                        device.renderer.dynamic_state.stencil_front_write_mask = impl.value;
                    if (impl.face_mask.back_bit)
                        device.renderer.dynamic_state.stencil_back_write_mask = impl.value;
                },
            }
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .face_mask = face_mask,
        .value = value,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn waitEvent(interface: *Interface, event: *base.Event, src_stage: vk.PipelineStageFlags, dst_stage: vk.PipelineStageFlags, memory_barriers: []const vk.MemoryBarrier, buffer_barriers: []const vk.BufferMemoryBarrier, image_barriers: []const vk.ImageMemoryBarrier) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    _ = src_stage;
    _ = dst_stage;
    _ = memory_barriers;
    _ = buffer_barriers;
    _ = image_barriers;

    const CommandImpl = struct {
        const Impl = @This();

        event: *base.Event,

        pub fn execute(context: *anyopaque, _: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            try impl.event.wait();
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .event = event,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}
