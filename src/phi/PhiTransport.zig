const std = @import("std");
const base = @import("base");
const lib = @import("lib.zig");
const scif = @import("scif.zig");

const VkError = base.VkError;
const proto = lib.proto;

const Self = @This();

epd: scif.epd_t,
sequence: u64 = 1,
mutex: std.Io.Mutex = .init,
instance: *base.Instance,

pub fn init(instance: *base.Instance, node_id: u16) VkError!Self {
    try scif.load();
    errdefer scif.unload();

    const epd = scif.open();
    if (epd < 0) {
        std.log.scoped(.PhiTransport).err("SCIF open failed", .{});
        return VkError.InitializationFailed;
    }
    errdefer _ = scif.close(epd);

    var dst: scif.PortId = .{
        .node = node_id,
        .port = @intCast(proto.PHI_SCIF_PORT),
    };

    if (scif.connect(epd, &dst) < 0) {
        std.log.scoped(.PhiTransport).err("SCIF connection to node {d} port {d} failed", .{ dst.node, dst.port });
        return VkError.InitializationFailed;
    }

    var self: Self = .{
        .epd = epd,
        .instance = instance,
    };
    try self.handshake();

    std.log.scoped(.PhiTransport).info("Successfully connected", .{});
    return self;
}

pub fn deinit(self: *Self) void {
    _ = scif.close(self.epd);
    scif.unload();
    std.log.scoped(.PhiTransport).info("Closed connection", .{});
}

pub fn request(self: *Self, command: c_uint, payload: []const u8, reply_payload: []u8) VkError!void {
    self.mutex.lock(self.instance.io()) catch return VkError.DeviceLost;
    defer self.mutex.unlock(self.instance.io());

    const sequence = self.sequence;
    self.sequence += 1;

    const header: proto.PhiMessageHeader = .{
        .magic = proto.PHI_PROTOCOL_MAGIC,
        .version = proto.PHI_PROTOCOL_VERSION,
        .type = @intCast(command),
        .sequence = sequence,
        .payload_size = payload.len,
    };

    try self.writeAll(std.mem.asBytes(&header));
    try self.writeAll(payload);

    var reply_header: proto.PhiMessageHeader = undefined;
    try self.readAll(std.mem.asBytes(&reply_header));

    if (reply_header.magic != proto.PHI_PROTOCOL_MAGIC or
        reply_header.version != proto.PHI_PROTOCOL_VERSION or
        reply_header.type != header.type or
        reply_header.sequence != sequence or
        reply_header.payload_size != reply_payload.len)
    {
        std.log.scoped(.PhiTransport).err("Invalid Phi reply header", .{});
        return VkError.InitializationFailed;
    }

    try self.readAll(reply_payload);
}

pub fn statusToErr(status: c_int) VkError {
    return switch (status) {
        proto.PHI_STATUS_OUT_OF_MEMORY => VkError.OutOfDeviceMemory,
        proto.PHI_STATUS_UNSUPPORTED_VERSION => VkError.InitializationFailed,
        else => VkError.Unknown,
    };
}

fn writeAll(self: *Self, bytes: []const u8) VkError!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = scif.send(self.epd, bytes[offset..].ptr, bytes.len - offset, scif.SEND_BLOCK);
        if (written <= 0) {
            return VkError.InitializationFailed;
        }
        offset += @intCast(written);
    }
}

fn readAll(self: *Self, bytes: []u8) VkError!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const read = scif.recv(self.epd, bytes[offset..].ptr, bytes.len - offset, scif.RECV_BLOCK);
        if (read <= 0) {
            return VkError.InitializationFailed;
        }
        offset += @intCast(read);
    }
}

fn handshake(self: *Self) VkError!void {
    const request_payload: proto.PhiHelloRequest = .{
        .host_protocol_version = proto.PHI_PROTOCOL_VERSION,
        .reserved = 0,
    };
    var reply: proto.PhiHelloReply = undefined;
    try self.request(proto.PHI_PACKET_HELLO, std.mem.asBytes(&request_payload), std.mem.asBytes(&reply));
    if (reply.result.status != proto.PHI_STATUS_OK) {
        return statusToErr(reply.result.status);
    }
    if (reply.device_protocol_version != proto.PHI_PROTOCOL_VERSION) {
        std.log.scoped(.PhiTransport).err("Unsupported Phi protocol version {d}", .{reply.device_protocol_version});
        return VkError.InitializationFailed;
    }
}
