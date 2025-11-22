const std = @import("std");
const vk = @import("vulkan");

const cmd = @import("base").commands;

const Self = @This();

pub fn init() Self {
    return .{};
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn dispatch(self: *Self, command: *const cmd.Command) void {
    _ = self;
    switch (command.*) {
        .FillBuffer => |data| fillBuffer(&data),
        else => {},
    }
}

fn fillBuffer(data: *const cmd.CommandFillBuffer) void {
    const memory = if (data.buffer.memory) |memory| memory else unreachable;
    const raw_memory_map: [*]u32 = @ptrCast(@alignCast(memory.map(data.offset, data.size) catch unreachable));
    var memory_map: []u32 = raw_memory_map[0..data.size];

    for (0..@divExact(data.size, @sizeOf(u32))) |i| {
        memory_map[i] = data.data;
    }

    memory.unmap();
}
