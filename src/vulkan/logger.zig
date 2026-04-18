const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const lib = @import("lib.zig");

comptime {
    if (!builtin.is_test) {
        if (!@hasDecl(root, "DRIVER_NAME")) {
            @compileError("Missing DRIVER_NAME in module root");
        }
    }
}

var mutex: std.Io.Mutex = .init;

pub inline fn fixme(comptime format: []const u8, args: anytype) void {
    if (!lib.env.hasEnvVar("STROLL_DEBUG_LOGS")) {
        return;
    }
    std.log.scoped(.FIXME).warn("FIXME: " ++ format, args);
}

pub fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (!lib.env.hasEnvVar("STROLL_DEBUG_LOGS")) {
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

    const level_color: std.Io.Terminal.Color = switch (level) {
        .info, .debug => .blue,
        .warn => .magenta,
        .err => .red,
    };

    const allocator = std.heap.smp_allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();

    const stderr_file = std.Io.File.stderr();
    const stdout_file = std.Io.File.stdout();

    const file = switch (level) {
        .info, .debug => stdout_file,
        .warn, .err => stderr_file,
    };

    file.lock(io, .exclusive) catch {};
    defer file.unlock(io);

    const now = std.Io.Timestamp.now(io, .cpu_process).toMilliseconds();

    const now_ms = @mod(now, std.time.ms_per_s);
    const now_sec = @mod(@divTrunc(now, std.time.ms_per_s), std.time.s_per_min);
    const now_min = @mod(@divTrunc(now, std.time.ms_per_min), 60);
    const now_hour = @mod(@divTrunc(now, std.time.ms_per_hour), 24);

    var fmt_buffer = std.mem.zeroes([4096]u8);
    var fmt_writer = std.Io.Writer.fixed(&fmt_buffer);
    fmt_writer.print(format ++ "\n", args) catch {};
    fmt_writer.flush() catch return;

    mutex.lock(io) catch return;
    defer mutex.unlock(io);

    var last_pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, &fmt_buffer, last_pos, '\n')) |pos| : (last_pos = pos + 1) {
        var buffer = std.mem.zeroes([512]u8);
        var file_writer = file.writer(io, &buffer);
        var writer = &file_writer.interface;

        const term: std.Io.Terminal = .{
            .writer = writer,
            .mode = std.Io.Terminal.Mode.detect(io, file, false, false) catch return,
        };

        term.setColor(.magenta) catch {};
        writer.print("[StrollDriver ", .{}) catch continue;
        if (!builtin.is_test) {
            term.setColor(.cyan) catch {};
            writer.print(root.DRIVER_NAME, .{}) catch continue;
        }
        term.setColor(.yellow) catch {};
        writer.print(" {d}:{d}:{d}.{d}", .{ now_hour, now_min, now_sec, now_ms }) catch continue;
        term.setColor(.magenta) catch {};
        writer.print("]", .{}) catch continue;

        term.setColor(.cyan) catch {};
        writer.print("[Thread {d: >8}]", .{std.Thread.getCurrentId()}) catch continue;

        term.setColor(level_color) catch {};
        writer.print(prefix, .{}) catch continue;

        term.setColor(switch (level) {
            .err => .red,
            .warn => .magenta,
            else => .green,
        }) catch {};
        writer.print("{s: >30}", .{scope_prefix}) catch continue;

        term.setColor(.reset) catch {};

        writer.print("{s}\n", .{fmt_buffer[last_pos..pos]}) catch continue;
        writer.flush() catch continue;
    }
}
