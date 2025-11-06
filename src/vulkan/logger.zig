const std = @import("std");
const builtin = @import("builtin");
const zdt = @import("zdt");
const root = @import("root");

comptime {
    if (!@hasDecl(root, "DRIVER_NAME")) {
        @compileError("Missing DRIVER_NAME in module root");
    }
    if (!@hasDecl(root, "DRIVER_LOGS_ENV_NAME")) {
        @compileError("Missing DRIVER_LOGS_ENV_NAME in module root");
    }
}

const is_posix = switch (builtin.os.tag) {
    .windows, .uefi, .wasi => false,
    else => true,
};

var indent_level: usize = 0;

pub fn indent() void {
    const new_indent_level, const has_overflown = @addWithOverflow(indent_level, 1);
    if (has_overflown == 0) {
        indent_level = new_indent_level;
    }
}

pub fn unindent() void {
    const new_indent_level, const has_overflown = @subWithOverflow(indent_level, 1);
    if (has_overflown == 0) {
        indent_level = new_indent_level;
    }
}

pub fn log(comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    if (!std.process.hasEnvVarConstant(root.DRIVER_LOGS_ENV_NAME)) {
        return;
    }

    const scope_name = @tagName(scope);
    const scope_prefix = comptime blk: {
        const limit = 30 - 4;
        break :blk if (scope_name.len >= limit)
            std.fmt.comptimePrint("({s}...): ", .{scope_name[0..(limit - 3)]})
        else
            std.fmt.comptimePrint("({s}): ", .{scope_name});
    };

    const prefix = std.fmt.comptimePrint("{s: <8}", .{"[" ++ comptime level.asText() ++ "] "});

    const level_color: std.Io.tty.Color = switch (level) {
        .info => .blue,
        .warn => .yellow,
        .err => .red,
        .debug => .blue,
    };

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    var stderr_buffer: [512]u8 = undefined;
    var stderr_file = std.fs.File.stderr();
    var stderr_writer = stderr_file.writer(&stderr_buffer);
    var writer: *std.Io.Writer = &stderr_writer.interface;
    var out_config = std.Io.tty.Config.detect(stderr_file);

    const timezone = zdt.Timezone.tzLocal(std.heap.page_allocator) catch zdt.Timezone.UTC;
    const now = zdt.Datetime.now(.{ .tz = &timezone }) catch return;

    out_config.setColor(writer, .magenta) catch {};
    writer.print("[" ++ root.DRIVER_NAME ++ " StrollDriver ", .{}) catch return;
    out_config.setColor(writer, .yellow) catch {};
    writer.print("{d:02}:{d:02}:{d:02}.{d:03}", .{ now.hour, now.minute, now.second, @divFloor(now.nanosecond, std.time.ns_per_ms) }) catch return;
    out_config.setColor(writer, .magenta) catch {};
    writer.print("]", .{}) catch return;

    out_config.setColor(writer, level_color) catch {};
    writer.print(prefix, .{}) catch return;

    out_config.setColor(writer, if (level == .err) .red else .green) catch {};
    writer.print("{s: >30}", .{scope_prefix}) catch return;

    out_config.setColor(writer, .reset) catch {};

    for (0..indent_level) |_| {
        writer.print(">   ", .{}) catch return;
    }
    writer.print(format ++ "\n", args) catch return;
    writer.flush() catch return;
}
