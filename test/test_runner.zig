// See https://gist.github.com/karlseguin/c6bea5b35e4e8d26af6f81c22cb5d76b/1f317ebc9cd09bc50fd5591d09c34255e15d1d85

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const BORDER = "=" ** 80;

// use in custom panic handler
var current_test: ?[]const u8 = null;

pub fn main() !void {
    var mem: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);

    const allocator = fba.allocator();

    var slowest = SlowTracker.init(allocator, 5);
    defer slowest.deinit(allocator);

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    Printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

    for (builtin.test_functions) |t| {
        if (isSetup(t)) {
            t.func() catch |err| {
                Printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    for (builtin.test_functions) |t| {
        if (isSetup(t) or isTeardown(t)) {
            continue;
        }

        var status = Status.pass;
        slowest.startTiming();

        const friendly_name = blk: {
            const name = t.name;
            var it = std.mem.splitScalar(u8, name, '.');
            while (it.next()) |value| {
                if (std.mem.eql(u8, value, "test")) {
                    const rest = it.rest();
                    break :blk if (rest.len > 0) rest else name;
                }
            }
            break :blk name;
        };

        current_test = friendly_name;
        std.testing.allocator_instance = .{};
        const result = t.func();
        current_test = null;

        const ns_taken = slowest.endTiming(allocator, friendly_name);

        if (std.testing.allocator_instance.deinit() == .leak) {
            leak += 1;
            Printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
        }

        if (result) |_| {
            pass += 1;
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                status = .skip;
            },
            else => {
                status = .fail;
                fail += 1;
                Printer.status(.fail, "\n{s}\n\"{s}\" - {s}\n{s}\n", .{ BORDER, friendly_name, @errorName(err), BORDER });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
            },
        }

        const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
        Printer.status(status, "\x1b[35m[{d: >10.2} ms]\x1b[0m {s: <120}", .{ ms, friendly_name });
    }

    for (builtin.test_functions) |t| {
        if (isTeardown(t)) {
            t.func() catch |err| {
                Printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    const total_tests = pass + fail;
    const status = if (fail == 0) Status.pass else Status.fail;
    Printer.status(status, "\n{d} of {d} test{s} passed\n", .{ pass, total_tests, if (total_tests != 1) "s" else "" });
    if (skip > 0) {
        Printer.status(.skip, "{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
    }
    if (leak > 0) {
        Printer.status(.fail, "{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
    }
    Printer.fmt("\n", .{});
    try slowest.display();
    Printer.fmt("\n", .{});
    std.process.exit(if (fail == 0) 0 else 1);
}

const Printer = struct {
    fn fmt(comptime format: []const u8, args: anytype) void {
        var buffer: [256]u8 = undefined;
        const stderr = std.Options.debug_io.lockStderr(&buffer, .escape_codes) catch return;
        defer std.Options.debug_io.unlockStderr();
        stderr.file_writer.interface.print(format, args) catch @panic("Caught an error while handling an error");
    }

    fn status(s: Status, comptime format: []const u8, args: anytype) void {
        switch (s) {
            .pass => fmt(format ++ "\x1b[32m✓\x1b[0m\n", args),
            .fail => fmt(format ++ "\x1b[31m✗\x1b[0m\n", args),
            .skip => fmt(format ++ "\x1b[33m \x1b[0m\n", args),
            else => unreachable,
        }
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const SlowTracker = struct {
    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);
    max: usize,
    slowest: SlowestQueue,
    timer: std.Io.Timestamp,

    fn init(allocator: Allocator, count: u32) SlowTracker {
        var slowest = SlowestQueue.empty;
        slowest.ensureTotalCapacity(allocator, count) catch @panic("OOM");
        return .{
            .max = count,
            .timer = std.Io.Timestamp.now(std.testing.io, .real),
            .slowest = slowest,
        };
    }

    const TestInfo = struct {
        ns: i96,
        name: []const u8,
    };

    fn deinit(self: *SlowTracker, allocator: std.mem.Allocator) void {
        self.slowest.deinit(allocator);
    }

    fn startTiming(self: *SlowTracker) void {
        self.timer = std.Io.Timestamp.now(std.testing.io, .real);
    }

    fn endTiming(self: *SlowTracker, allocator: std.mem.Allocator, test_name: []const u8) i96 {
        const duration = self.timer.untilNow(std.testing.io, .real);
        const ns = duration.toNanoseconds();

        var slowest = &self.slowest;

        if (slowest.count() < self.max) {
            // Capacity is fixed to the # of slow tests we want to track
            // If we've tracked fewer tests than this capacity, than always add
            slowest.push(allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
            return ns;
        }

        {
            // Optimization to avoid shifting the dequeue for the common case
            // where the test isn't one of our slowest.
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                // the test was faster than our fastest slow test, don't add
                return ns;
            }
        }

        // the previous fastest of our slow tests, has been pushed off.
        _ = slowest.popMin();
        slowest.push(allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
        return ns;
    }

    fn display(self: *SlowTracker) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        Printer.fmt("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (slowest.popMin()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            Printer.fmt("  {d:.2}ms\t{s}\n", .{ ms, info.name });
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            Printer.fmt("\x1b[31m{s}\npanic running \"{s}\"\n{s}\x1b[0m\n", .{ BORDER, ct, BORDER });
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isTeardown(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}
