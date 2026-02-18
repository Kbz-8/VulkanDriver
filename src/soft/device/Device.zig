const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const SoftDevice = @import("../SoftDevice.zig");
const SoftImage = @import("../SoftImage.zig");
const SoftPipeline = @import("../SoftPipeline.zig");

const ComputeRoutines = @import("ComputeRoutines.zig");

const cmd = base.commands;
const VkError = base.VkError;

const Self = @This();

compute_routine: ComputeRoutines,

pub fn init(device: *SoftDevice) Self {
    return .{
        .compute_routine = .init(device),
    };
}

pub fn deinit(self: *Self) void {
    self.compute_routine.destroy();
}

pub fn dispatch(self: *Self, command: *const cmd.Command) VkError!void {
    switch (command.*) {
        .BindPipeline => |data| {
            if (data.bind_point == .compute) {
                self.compute_routine.bindPipeline(@alignCast(@fieldParentPtr("interface", data.pipeline)));
            } else {
                // TODO
            }
        },
        .ClearColorImage => |data| try clearColorImage(&data),
        .CopyBuffer => |data| try copyBuffer(&data),
        .CopyImage => |data| try copyImage(&data),
        .CopyImageToBuffer => |data| try copyImageToBuffer(&data),
        .FillBuffer => |data| try fillBuffer(&data),
        else => {},
    }
}

fn clearColorImage(data: *const cmd.CommandClearColorImage) VkError!void {
    const soft_image: *SoftImage = @alignCast(@fieldParentPtr("interface", data.image));
    soft_image.clearRange(data.clear_color, data.range);
}

fn copyBuffer(data: *const cmd.CommandCopyBuffer) VkError!void {
    for (data.regions) |region| {
        const src_memory = if (data.src.memory) |memory| memory else return VkError.ValidationFailed;
        const dst_memory = if (data.dst.memory) |memory| memory else return VkError.ValidationFailed;

        const src_map: []u8 = @as([*]u8, @ptrCast(try src_memory.map(region.src_offset, region.size)))[0..region.size];
        const dst_map: []u8 = @as([*]u8, @ptrCast(try dst_memory.map(region.dst_offset, region.size)))[0..region.size];

        @memcpy(dst_map, src_map);

        src_memory.unmap();
        dst_memory.unmap();
    }
}

fn copyImage(data: *const cmd.CommandCopyImage) VkError!void {
    _ = data;
    std.log.scoped(.commandExecutor).warn("FIXME: implement image to image copy", .{});
}

fn copyImageToBuffer(data: *const cmd.CommandCopyImageToBuffer) VkError!void {
    for (data.regions) |region| {
        const src_memory = if (data.src.memory) |memory| memory else return VkError.ValidationFailed;
        const dst_memory = if (data.dst.memory) |memory| memory else return VkError.ValidationFailed;

        const pixel_size: u32 = @intCast(data.src.getPixelSize());
        const image_row_pitch: u32 = data.src.extent.width * pixel_size;
        const image_size: u32 = @intCast(data.src.getTotalSize());

        const buffer_row_length: u32 = if (region.buffer_row_length != 0) region.buffer_row_length else region.image_extent.width;
        const buffer_row_pitch: u32 = buffer_row_length * pixel_size;
        const buffer_size: u32 = buffer_row_pitch * region.image_extent.height * region.image_extent.depth;

        const src_map: []u8 = @as([*]u8, @ptrCast(try src_memory.map(0, image_size)))[0..image_size];
        const dst_map: []u8 = @as([*]u8, @ptrCast(try dst_memory.map(region.buffer_offset, buffer_size)))[0..buffer_size];

        const row_size = region.image_extent.width * pixel_size;
        for (0..data.src.extent.depth) |z| {
            for (0..data.src.extent.height) |y| {
                const z_as_u32: u32 = @intCast(z);
                const y_as_u32: u32 = @intCast(y);

                const src_offset = ((@as(u32, @intCast(region.image_offset.z)) + z_as_u32) * data.src.extent.height + @as(u32, @intCast(region.image_offset.y)) + y_as_u32) * image_row_pitch + @as(u32, @intCast(region.image_offset.x)) * pixel_size;
                const dst_offset = (z_as_u32 * buffer_row_length * region.image_extent.height + y_as_u32 * buffer_row_length) * pixel_size;

                const src_slice = src_map[src_offset..(src_offset + row_size)];
                const dst_slice = dst_map[dst_offset..(dst_offset + row_size)];
                @memcpy(dst_slice, src_slice);
            }
        }

        src_memory.unmap();
        dst_memory.unmap();
    }
}

fn fillBuffer(data: *const cmd.CommandFillBuffer) VkError!void {
    const memory = if (data.buffer.memory) |memory| memory else return VkError.ValidationFailed;
    var memory_map: []u32 = @as([*]u32, @ptrCast(@alignCast(try memory.map(data.offset, data.size))))[0..data.size];

    var bytes = if (data.size == vk.WHOLE_SIZE) memory.size - data.offset else data.size;

    var i: usize = 0;
    while (bytes >= 4) : ({
        bytes -= 4;
        i += 1;
    }) {
        memory_map[i] = data.data;
    }

    memory.unmap();
}
