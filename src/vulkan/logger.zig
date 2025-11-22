//! A driver-global logger that stack in memory all same-indent `debug` logs
//! and only displays them in reverse order if a non-debug log is requested

const std = @import("std");
const builtin = @import("builtin");
const zdt = @import("zdt");
const root = @import("root");
const lib = @import("lib.zig");

comptime {
    if (!builtin.is_test) {
        if (!@hasDecl(root, "DRIVER_NAME")) {
            @compileError("Missing DRIVER_NAME in module root");
        }
    }
}

const DebugStackElement = struct {
    log: [512]u8,
    indent_level: usize,
};

var indent_level: usize = 0;
var debug_stack = std.ArrayList(DebugStackElement).empty;

pub inline fn indent() void {
    const new_indent_level, const has_overflown = @addWithOverflow(indent_level, 1);
    if (has_overflown == 0) {
        indent_level = new_indent_level;
    }
}

pub inline fn unindent() void {
    const new_indent_level, const has_overflown = @subWithOverflow(indent_level, 1);
    if (has_overflown == 0) {
        indent_level = new_indent_level;
    }
    loop: while (debug_stack.getLastOrNull()) |last| {
        if (last.indent_level >= indent_level) {
            _ = debug_stack.pop();
        } else {
            break :loop;
        }
    }
}

pub inline fn freeInnerDebugStack() void {
    debug_stack.deinit(std.heap.c_allocator);
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

    const prefix = std.fmt.comptimePrint("{s: <8}", .{"[" ++ comptime level.asText() ++ "] "});

    const level_color: std.Io.tty.Color = switch (level) {
        .info, .debug => .blue,
        .warn => .yellow,
        .err => .red,
    };

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    var buffer = std.mem.zeroes([512]u8);
    var stderr_file = std.fs.File.stderr();
    var out_config = std.Io.tty.Config.detect(stderr_file);
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

    out_config.setColor(&writer, if (level == .err) .red else .green) catch {};
    writer.print("{s: >30}", .{scope_prefix}) catch {};

    out_config.setColor(&writer, .reset) catch {};

    for (0..indent_level) |_| {
        writer.print(">   ", .{}) catch {};
    }
    writer.print(format ++ "\n", args) catch {};
    writer.flush() catch return;

    if (level == .debug and lib.getLogVerboseLevel() == .Standard) {
        (debug_stack.addOne(std.heap.c_allocator) catch return).* = .{
            .log = buffer,
            .indent_level = indent_level,
        };
    } else {
        while (debug_stack.items.len != 0) {
            const elem_buffer = debug_stack.orderedRemove(0).log;
            _ = stderr_file.write(&elem_buffer) catch return;
        }
        _ = stderr_file.write(&buffer) catch return;
    }
}
