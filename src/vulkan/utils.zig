const std = @import("std");
const vk = @import("vulkan");

pub fn boundedName(name: [*:0]const u8, max_len: usize) ?[]const u8 {
    const bytes = name[0..max_len];
    const len = std.mem.indexOfScalar(u8, bytes, 0) orelse return null;
    return bytes[0..len];
}

pub inline fn propertyName(comptime max_len: usize, name: *const [max_len]u8) []const u8 {
    return std.mem.sliceTo(name[0..], 0);
}

pub inline fn extensionName(name: *const [vk.MAX_EXTENSION_NAME_SIZE]u8) []const u8 {
    return propertyName(vk.MAX_EXTENSION_NAME_SIZE, name);
}

pub fn isSupportedExtension(name: []const u8, extensions: []const vk.ExtensionProperties) bool {
    for (extensions) |extension| {
        if (std.mem.eql(u8, name, extensionName(&extension.extension_name))) {
            return true;
        }
    }
    return false;
}

pub fn writePacked(comptime T: type, bytes: []u8, value: T) void {
    const raw: [@sizeOf(T)]u8 = @bitCast(value);
    @memcpy(bytes[0..@sizeOf(T)], raw[0..]);
}

pub fn ioctl(file: std.Io.File, io: std.Io, request: u32, arg: ?*anyopaque) (std.Io.Cancelable || std.posix.UnexpectedError)!void {
    const result = try io.operate(.{ .device_io_control = .{
        .file = file,
        .code = request,
        .arg = arg,
    } });

    const rc = if (@import("builtin").link_libc)
        @as(c_int, @intCast(result.device_io_control))
    else
        @as(usize, @bitCast(@as(isize, @intCast(result.device_io_control))));

    return switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |e| std.posix.unexpectedErrno(e),
    };
}
