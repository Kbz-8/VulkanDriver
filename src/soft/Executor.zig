const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const cmd = base.commands;
const VkError = base.VkError;

const Self = @This();

pub fn init() Self {
    return .{};
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn dispatch(self: *Self, command: *const cmd.Command) VkError!void {
    _ = self;
    switch (command.*) {
        .ClearColorImage => |data| try clearColorImage(&data),
        .CopyBuffer => |data| try copyBuffer(&data),
        .CopyImage => |data| try copyImage(&data),
        .FillBuffer => |data| try fillBuffer(&data),
        else => {},
    }
}

fn clearColorImage(data: *const cmd.CommandClearColorImage) VkError!void {
    // TODO: use a blitter

    const image = data.image;
    for (data.ranges) |range| {
        const image_size = image.getTotalSize();

        const memory = if (image.memory) |memory| memory else return VkError.ValidationFailed;
        var memory_map: []u32 = @as([*]u32, @ptrCast(@alignCast(try memory.map(0, image_size))))[0..image_size];

        _ = range;
        _ = &memory_map;

        base.logger.fixme("Implement image clear", .{});

        memory.unmap();
    }
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

fn fillBuffer(data: *const cmd.CommandFillBuffer) VkError!void {
    const memory = if (data.buffer.memory) |memory| memory else return VkError.ValidationFailed;
    var memory_map: []u32 = @as([*]u32, @ptrCast(@alignCast(try memory.map(data.offset, data.size))))[0..data.size];

    for (0..@divExact(data.size, @sizeOf(u32))) |i| {
        memory_map[i] = data.data;
    }

    memory.unmap();
}
