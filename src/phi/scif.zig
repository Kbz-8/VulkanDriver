const std = @import("std");
const base = @import("base");

const VkError = base.VkError;

pub const epd_t = c_int;

pub const PortId = extern struct {
    node: u16,
    port: u16,
};

pub const send_block = 1;
pub const recv_block = 1;

// SAFETY: load assigns every function pointer before the public wrappers can be used.
var scif_open: *const fn () callconv(.c) epd_t = undefined;
// SAFETY: load assigns every function pointer before the public wrappers can be used.
var scif_close: *const fn (epd: epd_t) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before the public wrappers can be used.
var scif_connect: *const fn (epd: epd_t, dst: *const PortId) callconv(.c) c_int = undefined;
// SAFETY: load assigns every function pointer before the public wrappers can be used.
var scif_send: *const fn (epd: epd_t, msg: ?*const anyopaque, len: usize, flags: c_int) callconv(.c) isize = undefined;
// SAFETY: load assigns every function pointer before the public wrappers can be used.
var scif_recv: *const fn (epd: epd_t, msg: ?*anyopaque, len: usize, flags: c_int) callconv(.c) isize = undefined;

// SAFETY: load initializes the module before it can be closed or queried.
var module: std.DynLib = undefined;
var ref_count = std.atomic.Value(usize).init(0);
var load_mutex: base.SpinMutex = .{};

pub fn load() VkError!void {
    load_mutex.lock();
    defer load_mutex.unlock();

    if (ref_count.load(.monotonic) != 0) {
        _ = ref_count.fetchAdd(1, .monotonic);
        return;
    }

    module = std.DynLib.open("libscif.so") catch {
        std.log.scoped(.SCIF).err("Could not open libscif.so", .{});
        return VkError.InitializationFailed;
    };
    errdefer module.close();

    scif_open = module.lookup(@TypeOf(scif_open), "scif_open") orelse return VkError.InitializationFailed;
    scif_close = module.lookup(@TypeOf(scif_close), "scif_close") orelse return VkError.InitializationFailed;
    scif_connect = module.lookup(@TypeOf(scif_connect), "scif_connect") orelse return VkError.InitializationFailed;
    scif_send = module.lookup(@TypeOf(scif_send), "scif_send") orelse return VkError.InitializationFailed;
    scif_recv = module.lookup(@TypeOf(scif_recv), "scif_recv") orelse return VkError.InitializationFailed;

    _ = ref_count.fetchAdd(1, .monotonic);
}

pub fn unload() void {
    load_mutex.lock();
    defer load_mutex.unlock();

    if (ref_count.fetchSub(1, .release) == 1) {
        module.close();
    }
}

pub inline fn open() epd_t {
    return scif_open();
}

pub inline fn close(epd: epd_t) c_int {
    return scif_close(epd);
}

pub inline fn connect(epd: epd_t, dst: *const PortId) c_int {
    return scif_connect(epd, dst);
}

pub inline fn send(epd: epd_t, msg: ?*const anyopaque, len: usize, flags: c_int) isize {
    return scif_send(epd, msg, len, flags);
}

pub inline fn recv(epd: epd_t, msg: ?*anyopaque, len: usize, flags: c_int) isize {
    return scif_recv(epd, msg, len, flags);
}
