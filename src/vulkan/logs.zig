const std = @import("std");
const builtin = @import("builtin");
const root = @import("lib.zig");

const is_posix = switch (builtin.os.tag) {
    .windows, .uefi, .wasi => false,
    else => true,
};

pub fn logger(comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    if (!std.process.hasEnvVarConstant(root.DRIVER_LOGS_ENV_NAME)) {
        return;
    }
    const scope_prefix = "(" ++ @tagName(scope) ++ "): ";
    const prefix = "[" ++ comptime level.asText() ++ "] ";

    const level_color: std.Io.tty.Color = switch (level) {
        .info => .blue,
        .warn => .yellow,
        .err => .red,
        .debug => .blue,
    };

    const instant = std.time.Instant.now() catch return;
    const now = if (is_posix) instant.timestamp.nsec else instant.timestamp;

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    var stderr_buffer: [512]u8 = undefined;
    var stderr_file = std.fs.File.stderr();
    var stderr_writer = stderr_file.writer(&stderr_buffer);
    var writer: *std.Io.Writer = &stderr_writer.interface;

    var out_config = std.Io.tty.Config.detect(stderr_file);
    nosuspend {
        out_config.setColor(writer, .magenta) catch {};
        writer.print("[Driver log {}:{}:{}]", .{ @divFloor(now, std.time.ns_per_min), @divFloor(now, std.time.ns_per_s), @divFloor(now, std.time.ns_per_ms) }) catch return;
        out_config.setColor(writer, level_color) catch {};
        writer.print(prefix, .{}) catch return;
        out_config.setColor(writer, .green) catch {};
        writer.print(scope_prefix, .{}) catch return;
        out_config.setColor(writer, .reset) catch {};

        writer.print(format ++ "\n", args) catch return;
        writer.flush() catch return;
    }
}
