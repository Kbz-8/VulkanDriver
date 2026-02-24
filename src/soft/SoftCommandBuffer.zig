const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("lib.zig");

const InterfaceFactory = @import("interface").Interface;

const VkError = base.VkError;
const Device = base.Device;

const SoftBuffer = @import("SoftBuffer.zig");
const SoftImage = @import("SoftImage.zig");
const SoftPipeline = @import("SoftPipeline.zig");
const SoftDescriptorSet = @import("SoftDescriptorSet.zig");

const ExecutionDevice = @import("device/Device.zig");

const Self = @This();
pub const Interface = base.CommandBuffer;

const Command = InterfaceFactory(.{
    .execute = fn (*ExecutionDevice) VkError!void,
}, null);

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
        .bindDescriptorSets = bindDescriptorSets,
        .bindPipeline = bindPipeline,
        .clearColorImage = clearColorImage,
        .copyBuffer = copyBuffer,
        .copyImage = copyImage,
        .copyImageToBuffer = copyImageToBuffer,
        .dispatch = dispatch,
        .end = end,
        .fillBuffer = fillBuffer,
        .reset = reset,
        .resetEvent = resetEvent,
        .setEvent = setEvent,
        .waitEvents = waitEvents,
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
}

pub fn execute(self: *Self, device: *ExecutionDevice) VkError!void {
    self.interface.submit() catch return;
    for (self.commands.items) |command| {
        try command.vtable.execute(command.ptr, device);
    }
}

pub fn begin(interface: *Interface, _: *const vk.CommandBufferBeginInfo) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.command_allocator.deinit();
}

pub fn end(interface: *Interface) VkError!void {
    // No-op
    _ = interface;
}

pub fn reset(interface: *Interface, _: vk.CommandBufferResetFlags) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();
    self.commands.clearAndFree(allocator);
    if (!self.command_allocator.reset(.{ .retain_with_limit = 16_384 }))
        return VkError.OutOfHostMemory;
}

// Commands ====================================================================================================

pub fn bindDescriptorSets(interface: *Interface, bind_point: vk.PipelineBindPoint, first_set: u32, sets: [base.VULKAN_MAX_DESCRIPTOR_SETS]?*base.DescriptorSet, dynamic_offsets: []const u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        bind_point: vk.PipelineBindPoint,
        first_set: u32,
        sets: [base.VULKAN_MAX_DESCRIPTOR_SETS]?*base.DescriptorSet,
        dynamic_offsets: []const u32,

        pub fn execute(impl: *const Impl, device: *ExecutionDevice) VkError!void {
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
    self.commands.append(allocator, Command.from(cmd)) catch return VkError.OutOfHostMemory;
}

pub fn bindPipeline(interface: *Interface, bind_point: vk.PipelineBindPoint, pipeline: *base.Pipeline) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        bind_point: vk.PipelineBindPoint,
        pipeline: *SoftPipeline,

        pub fn execute(impl: *const Impl, device: *ExecutionDevice) VkError!void {
            device.pipeline_states[@intCast(@intFromEnum(impl.bind_point))].pipeline = impl.pipeline;
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .bind_point = bind_point,
        .pipeline = @alignCast(@fieldParentPtr("interface", pipeline)),
    };
    self.commands.append(allocator, Command.from(cmd)) catch return VkError.OutOfHostMemory;
}

pub fn clearColorImage(interface: *Interface, image: *base.Image, layout: vk.ImageLayout, color: *const vk.ClearColorValue, range: vk.ImageSubresourceRange) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        image: *SoftImage,
        layout: vk.ImageLayout,
        clear_color: vk.ClearColorValue,
        range: vk.ImageSubresourceRange,

        pub fn execute(impl: *const Impl, _: *ExecutionDevice) VkError!void {
            impl.image.clearRange(impl.clear_color, impl.range);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .image = @alignCast(@fieldParentPtr("interface", image)),
        .layout = layout,
        .clear_color = color.*,
        .range = range,
    };
    self.commands.append(allocator, Command.from(cmd)) catch return VkError.OutOfHostMemory;
}

pub fn copyBuffer(interface: *Interface, src: *base.Buffer, dst: *base.Buffer, regions: []const vk.BufferCopy) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        src: *const SoftBuffer,
        dst: *SoftBuffer,
        regions: []const vk.BufferCopy,

        pub fn execute(impl: *const Impl, _: *ExecutionDevice) VkError!void {
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
    self.commands.append(allocator, Command.from(cmd)) catch return VkError.OutOfHostMemory;
}

pub fn copyImage(interface: *Interface, src: *base.Image, src_layout: vk.ImageLayout, dst: *base.Image, dst_layout: vk.ImageLayout, regions: []const vk.ImageCopy) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        src: *const SoftImage,
        src_layout: vk.ImageLayout,
        dst: *SoftImage,
        dst_layout: vk.ImageLayout,
        regions: []const vk.ImageCopy,

        pub fn execute(impl: *const Impl, _: *ExecutionDevice) VkError!void {
            try impl.src.copyImage(impl.src_layout, impl.dst, impl.dst_layout, impl.regions);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .src = @alignCast(@fieldParentPtr("interface", src)),
        .src_layout = src_layout,
        .dst = @alignCast(@fieldParentPtr("interface", dst)),
        .dst_layout = dst_layout,
        .regions = allocator.dupe(vk.ImageCopy, regions) catch return VkError.OutOfHostMemory, // Will be freed on cmdbuf reset or destroy
    };
    self.commands.append(allocator, Command.from(cmd)) catch return VkError.OutOfHostMemory;
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

        pub fn execute(impl: *const Impl, _: *ExecutionDevice) VkError!void {
            try impl.src.copyImageToBuffer(impl.src_layout, impl.dst, impl.regions);
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
    self.commands.append(allocator, Command.from(cmd)) catch return VkError.OutOfHostMemory;
}

pub fn dispatch(interface: *Interface, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const allocator = self.command_allocator.allocator();

    const CommandImpl = struct {
        const Impl = @This();

        group_count_x: u32,
        group_count_y: u32,
        group_count_z: u32,

        pub fn execute(impl: *const Impl, device: *ExecutionDevice) VkError!void {
            try device.compute_routines.dispatch(impl.group_count_x, impl.group_count_y, impl.group_count_z);
        }
    };

    const cmd = allocator.create(CommandImpl) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(cmd);
    cmd.* = .{
        .group_count_x = group_count_x,
        .group_count_y = group_count_y,
        .group_count_z = group_count_z,
    };
    self.commands.append(allocator, Command.from(cmd)) catch return VkError.OutOfHostMemory;
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

        pub fn execute(impl: *const Impl, _: *ExecutionDevice) VkError!void {
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
    self.commands.append(allocator, Command.from(cmd)) catch return VkError.OutOfHostMemory;
}

pub fn resetEvent(interface: *Interface, event: *base.Event, stage: vk.PipelineStageFlags) VkError!void {
    // No-op
    _ = interface;
    _ = event;
    _ = stage;
}

pub fn setEvent(interface: *Interface, event: *base.Event, stage: vk.PipelineStageFlags) VkError!void {
    // No-op
    _ = interface;
    _ = event;
    _ = stage;
}

pub fn waitEvents(interface: *Interface, events: []*const base.Event, src_stage: vk.PipelineStageFlags, dst_stage: vk.PipelineStageFlags, memory_barriers: []const vk.MemoryBarrier, buffer_barriers: []const vk.BufferMemoryBarrier, image_barriers: []const vk.ImageMemoryBarrier) VkError!void {
    // No-op
    _ = interface;
    _ = events;
    _ = src_stage;
    _ = dst_stage;
    _ = memory_barriers;
    _ = buffer_barriers;
    _ = image_barriers;
}
