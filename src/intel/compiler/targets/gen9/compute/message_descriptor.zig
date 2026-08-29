const instruction = @import("../../../ir/instruction.zig");

pub const Descriptor = struct {
    sfid: u8,
    value: u32,
    message_length: u8,
    response_length: u8,
};

const dc1_sfid: u8 = 12;
const simd8_one_channel_control: u8 = 0x2e;

const MessageType = enum(u8) {
    untyped_surface_read = 1,
    untyped_surface_write = 9,
};

pub fn encode(message: instruction.SurfaceMessage) Descriptor {
    const lengths: struct { message: u8, response: u8 } = switch (message.kind) {
        .read => .{ .message = 1, .response = 1 },
        .write => .{ .message = 2, .response = 0 },
    };
    const message_type: MessageType = switch (message.kind) {
        .read => .untyped_surface_read,
        .write => .untyped_surface_write,
    };

    return .{
        .sfid = dc1_sfid,
        .value = makeDescriptor(
            message.binding_table,
            simd8_one_channel_control,
            message_type,
            lengths.message,
            lengths.response,
        ),
        .message_length = lengths.message,
        .response_length = lengths.response,
    };
}

fn makeDescriptor(binding_table: u8, message_control: u8, message_type: MessageType, message_length: u8, response_length: u8) u32 {
    return @as(u32, binding_table) |
        (@as(u32, message_control) << 8) |
        (@as(u32, @intFromEnum(message_type)) << 14) |
        (@as(u32, response_length) << 20) |
        (@as(u32, message_length) << 25);
}

test "[gen9] message descriptor: encode SIMD8 one-channel surface read" {
    const std = @import("std");
    const descriptor = encode(.{
        .kind = .read,
        .binding_table = 3,
        .payload = .{ .base = .{ .physical_grf = .{ .number = 1 } }, .register_count = 1 },
        .response = .{ .base = .{ .physical_grf = .{ .number = 2 } }, .register_count = 1 },
        .data_type = .u32,
    });

    try std.testing.expectEqual(@as(u8, 12), descriptor.sfid);
    try std.testing.expectEqual(@as(u8, 1), descriptor.message_length);
    try std.testing.expectEqual(@as(u8, 1), descriptor.response_length);
    try std.testing.expectEqual(@as(u8, 3), @as(u8, @truncate(descriptor.value)));
    try std.testing.expectEqual(@as(u8, 0x2e), @as(u8, @truncate(descriptor.value >> 8)) & 0x3f);
    try std.testing.expectEqual(@as(u8, 1), @as(u8, @truncate(descriptor.value >> 14)) & 0x1f);
    try std.testing.expectEqual(@as(u8, 1), @as(u8, @truncate(descriptor.value >> 20)) & 0x1f);
    try std.testing.expectEqual(@as(u8, 1), @as(u8, @truncate(descriptor.value >> 25)) & 0x0f);
    try std.testing.expectEqual(@as(u32, 0x02106e03), descriptor.value);
}

test "[gen9] message descriptor: encode SIMD8 one-channel surface write" {
    const std = @import("std");
    const descriptor = encode(.{
        .kind = .write,
        .binding_table = 7,
        .payload = .{ .base = .{ .physical_grf = .{ .number = 1 } }, .register_count = 2 },
        .response = null,
        .data_type = .u32,
    });

    try std.testing.expectEqual(@as(u8, 12), descriptor.sfid);
    try std.testing.expectEqual(@as(u8, 2), descriptor.message_length);
    try std.testing.expectEqual(@as(u8, 0), descriptor.response_length);
    try std.testing.expectEqual(@as(u8, 7), @as(u8, @truncate(descriptor.value)));
    try std.testing.expectEqual(@as(u8, 0x2e), @as(u8, @truncate(descriptor.value >> 8)) & 0x3f);
    try std.testing.expectEqual(@as(u8, 9), @as(u8, @truncate(descriptor.value >> 14)) & 0x1f);
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @truncate(descriptor.value >> 20)) & 0x1f);
    try std.testing.expectEqual(@as(u8, 2), @as(u8, @truncate(descriptor.value >> 25)) & 0x0f);
    try std.testing.expectEqual(@as(u32, 0x04026e07), descriptor.value);
}
