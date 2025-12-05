//! A driver-global logger that stack in memory all same-indent `debug` logs
//! and only displays them in reverse order if a non-debug log is requested

const std = @import("std");
const builtin = @import("builtin");
const zdt = @import("zdt");
const root = @import("root");
const lib = @import("../lib.zig");

const ThreadSafeManager = @import("ThreadSafeManager.zig");

comptime {
    if (!builtin.is_test) {
        if (!@hasDecl(root, "DRIVER_NAME")) {
            @compileError("Missing DRIVER_NAME in module root");
        }
    }
}

pub var manager: ThreadSafeManager = .init;

pub inline fn fixme(comptime format: []const u8, args: anytype) void {
    manager.get().disableIndent();
    defer manager.get().enableIndent();
    nestedFixme(format, args);
}

pub inline fn nestedFixme(comptime format: []const u8, args: anytype) void {
    std.log.scoped(.FIXME).warn("FIXME: " ++ format, args);
}

pub fn log(comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    if (lib.getLogVerboseLevel() == .None) {
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

    const prefix = std.fmt.comptimePrint("{s: <10}", .{"[" ++ comptime level.asText() ++ "] "});

    const level_color: std.Io.tty.Color = switch (level) {
        .info, .debug => .blue,
        .warn => .magenta,
        .err => .red,
    };

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    var stderr_file = std.fs.File.stderr();
    var stdout_file = std.fs.File.stdout();

    const file = switch (level) {
        .info, .debug => stdout_file,
        .warn, .err => stderr_file,
    };

    var buffer = std.mem.zeroes([512]u8);
    var out_config = std.Io.tty.Config.detect(file);
    var writer = std.Io.Writer.fixed(&buffer);

    var timezone = zdt.Timezone.tzLocal(std.heap.page_allocator) catch zdt.Timezone.UTC;
    defer timezone.deinit();
    const now = zdt.Datetime.now(.{ .tz = &timezone }) catch zdt.Datetime{};

    out_config.setColor(&writer, .magenta) catch {};
    writer.print("[StrollDriver ", .{}) catch {};
    if (!builtin.is_test) {
        out_config.setColor(&writer, .cyan) catch {};
        writer.print(root.DRIVER_NAME, .{}) catch {};
    }
    out_config.setColor(&writer, .yellow) catch {};
    writer.print(" {d:02}:{d:02}:{d:02}.{d:03}", .{ now.hour, now.minute, now.second, @divFloor(now.nanosecond, std.time.ns_per_ms) }) catch {};
    out_config.setColor(&writer, .magenta) catch {};
    writer.print("]", .{}) catch {};

    out_config.setColor(&writer, level_color) catch {};
    writer.print(prefix, .{}) catch {};

    out_config.setColor(&writer, switch (level) {
        .err => .red,
        .warn => .magenta,
        else => .green,
    }) catch {};
    writer.print("{s: >30}", .{scope_prefix}) catch {};

    out_config.setColor(&writer, .reset) catch {};

    if (manager.get().indent_enabled) {
        for (0..manager.get().indent_level) |_| {
            writer.print(">   ", .{}) catch {};
        }
    }
    writer.print(format ++ "\n", args) catch {};
    writer.flush() catch return;

    if (level == .debug and lib.getLogVerboseLevel() == .Standard) {
        manager.get().debug_stack.pushBack(.{
            .log = buffer,
            .indent_level = manager.get().indent_level,
            .log_level = level,
        }) catch return;
        return;
    }

    if (manager.get().indent_enabled) {
        while (manager.get().debug_stack.len() != 0) {
            const elem = manager.get().debug_stack.popFront();
            switch (elem.log_level) {
                .info, .debug => _ = stdout_file.write(&elem.log) catch {},
                .warn, .err => _ = stderr_file.write(&elem.log) catch {},
            }
        }
    }
    switch (level) {
        .info, .debug => _ = stdout_file.write(&buffer) catch {},
        .warn, .err => _ = stderr_file.write(&buffer) catch {},
    }
}
