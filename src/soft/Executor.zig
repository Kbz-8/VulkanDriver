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
    _ = command;
}
