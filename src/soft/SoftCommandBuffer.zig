const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("lib.zig");

const Device = base.Device;
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

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.CommandBufferAllocateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);

    interface.vtable = &.{
        .destroy = destroy,
    };

    interface.dispatch_table = &.{
        .begin = begin,
        .beginRenderPass = beginRenderPass,
        .bindDescriptorSets = bindDescriptorSets,
        .bindPipeline = bindPipeline,
        .bindVertexBuffer = bindVertexBuffer,
        .blitImage = blitImage,
        .clearAttachment = clearAttachment,
        .clearColorImage = clearColorImage,
        .copyBuffer = copyBuffer,
        .copyBufferToImage = copyBufferToImage,
        .copyImage = copyImage,
        .copyImageToBuffer = copyImageToBuffer,
        .dispatch = dispatch,
        .dispatchIndirect = dispatchIndirect,
        .draw = draw,
        .end = end,
        .endRenderPass = endRenderPass,
        .executeCommands = executeCommands,
        .fillBuffer = fillBuffer,
        .pipelineBarrier = pipelineBarrier,
        .reset = reset,
        .resetEvent = resetEvent,
        .setEvent = setEvent,
        .setViewport = setViewport,
        .waitEvent = waitEvent,
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
    allocator.destroy(self);
    _ = self.command_allocator.reset(.free_all);
}

pub fn execute(self: *Self, device: *ExecutionDevice) void {
    self.interface.submit() catch return;
    defer self.interface.finish() catch {};

    for (self.commands.items) |command| {
        command.vtable.execute(@ptrCast(command.ptr), device) catch |err| {
            base.errors.errorLoggerContext(err, "the software execution device");
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
            return; // Should we return or continue ? Maybe device lost ?
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

            for (impl.render_pass.interface.attachments, impl.framebuffer.interface.attachments, 0..) |desc, attachment, index| {
                const image: *SoftImage = @alignCast(@fieldParentPtr("interface", attachment.image));
                const clear_format = try image.getClearFormat();

                switch (desc.load_op) {
                    .clear => {
                        try blitter.clear(
                            (impl.clear_values orelse return VkError.Unknown)[index],
                            clear_format,
                            image,
                            attachment.format,
                            attachment.subresource_range,
                            null,
                        );
                    },
                    else => {},
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

pub fn bindDescriptorSets(interface: *Interface, bind_point: vk.PipelineBindPoint, first_set: u32, sets: [base.VULKAN_MAX_DESCRIPTOR_SETS]?*base.DescriptorSet, dynamic_offsets: []const u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        bind_point: vk.PipelineBindPoint,
        first_set: u32,
        sets: [base.VULKAN_MAX_DESCRIPTOR_SETS]?*base.DescriptorSet,
        dynamic_offsets: []const u32,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            for (impl.first_set.., impl.sets[0..]) |i, set| {
                if (set == null)
                    break;
                device.pipeline_states[@intCast(@intFromEnum(impl.bind_point))].sets[i] = @alignCast(@fieldParentPtr("interface", set.?));
            }
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .bind_point = bind_point,
        .first_set = first_set,
        .sets = sets,
        .dynamic_offsets = dynamic_offsets,
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
            device.pipeline_states[ExecutionDevice.GRAPHICS_PIPELINE_STATE].data.graphics.vertex_buffers[impl.index] = .{
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

            if (device.renderer.framebuffer) |framebuffer| {
                const image_view = framebuffer.interface.attachments[impl.attachment.color_attachment];
                const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.image));
                const clear_format = try image.getClearFormat();

                try blitter.clear(
                    impl.attachment.clear_value,
                    clear_format,
                    image,
                    image_view.format,
                    image_view.subresource_range,
                    null,
                );
            }
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

pub fn dispatch(interface: *Interface, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        group_count_x: u32,
        group_count_y: u32,
        group_count_z: u32,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            try device.compute.dispatch(impl.group_count_x, impl.group_count_y, impl.group_count_z);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .group_count_x = group_count_x,
        .group_count_y = group_count_y,
        .group_count_z = group_count_z,
    };
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
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
            const size = 3 * @sizeOf(u32);
            const memory = if (impl.buffer.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
            const map: []u32 = @as([*]u32, @ptrCast(@alignCast(try memory.map(impl.offset, size))))[0..3];
            try device.compute.dispatch(map[0], map[1], map[2]);
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

pub fn endRenderPass(interface: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        pub fn execute(_: *anyopaque, device: *ExecutionDevice) VkError!void {
            device.renderer.render_pass = null;
            device.renderer.framebuffer = null;
        }
    };

    self.commands.append(allocator, .{ .ptr = undefined, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;
}

pub fn executeCommands(interface: *Interface, commands: *Interface) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        cmd: *Self,

        pub fn execute(context: *anyopaque, device: *ExecutionDevice) VkError!void {
            const impl: *Impl = @ptrCast(@alignCast(context));
            impl.cmd.execute(device);
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

pub fn pipelineBarrier(interface: *Interface, src_stage: vk.PipelineStageFlags, dst_stage: vk.PipelineStageFlags, dependency: vk.DependencyFlags, memory_barriers: []const vk.MemoryBarrier, buffer_barriers: []const vk.BufferMemoryBarrier, image_barriers: []const vk.ImageMemoryBarrier) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        pub fn execute(_: *anyopaque, _: *ExecutionDevice) VkError!void {
            // TODO: implement synchronization for rasterization stages
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{};
    self.commands.append(allocator, .{ .ptr = cmd, .vtable = &.{ .execute = CommandImpl.execute } }) catch return VkError.OutOfHostMemory;

    _ = src_stage;
    _ = dst_stage;
    _ = dependency;
    _ = memory_barriers;
    _ = buffer_barriers;
    _ = image_barriers;
}

pub fn resetEvent(interface: *Interface, event: *base.Event, stage: vk.PipelineStageFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    _ = stage;

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
