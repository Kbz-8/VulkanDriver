const std = @import("std");
const base = @import("base");
const lib = @import("lib.zig");
const scif = @import("scif.zig");

const VkError = base.VkError;
const proto = lib.proto;
const Endpoint = if (lib.config.phi_host_emulation) std.Io.net.Stream else scif.epd_t;

const Self = @This();

epd: Endpoint,
sequence: u64 = 1,
mutex: std.Io.Mutex = .init,
instance: *base.Instance,

pub fn init(instance: *base.Instance, node_id: u16) VkError!Self {
    const epd = if (comptime lib.config.phi_host_emulation) blk: {
        const address: std.Io.net.IpAddress = .{
            .ip4 = .loopback(lib.config.phi_emulation_port),
        };
        const stream = address.connect(instance.io(), .{ .mode = .stream }) catch |err| {
            std.log.scoped(.PhiTransport).err(
                "TCP connection to 127.0.0.1:{d} failed: {s}",
                .{ lib.config.phi_emulation_port, @errorName(err) },
            );
            return VkError.InitializationFailed;
        };
        break :blk stream;
    } else blk: {
        try scif.load();
        errdefer scif.unload();

        const endpoint = scif.open();
        if (endpoint < 0) {
            std.log.scoped(.PhiTransport).err("SCIF open failed", .{});
            return VkError.InitializationFailed;
        }
        errdefer _ = scif.close(endpoint);

        var dst: scif.PortId = .{
            .node = node_id,
            .port = @intCast(proto.PHI_SCIF_PORT),
        };

        if (scif.connect(endpoint, &dst) < 0) {
            std.log.scoped(.PhiTransport).err("SCIF connection to node {d} port {d} failed", .{ dst.node, dst.port });
            return VkError.InitializationFailed;
        }
        break :blk endpoint;
    };
    errdefer {
        closeEndpoint(epd, instance.io());
        if (comptime !lib.config.phi_host_emulation)
            scif.unload();
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
    var reply: proto.PhiResult = undefined;
    self.request(proto.PHI_PACKET_SHUTDOWN, &.{}, std.mem.asBytes(&reply)) catch |err| {
        std.log.scoped(.PhiTransport).warn("Failed to shut down remote session: {s}", .{@errorName(err)});
    };

    closeEndpoint(self.epd, self.instance.io());
    if (comptime !lib.config.phi_host_emulation)
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

    // SAFETY: will be entirely written with the readAll
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
    if (comptime lib.config.phi_host_emulation) {
        var buffer: [0]u8 = .{};
        var writer = self.epd.writer(self.instance.io(), &buffer);
        writer.interface.writeAll(bytes) catch |err| {
            std.log.scoped(.PhiTransport).err("TCP send failed: {s}", .{@errorName(err)});
            return VkError.InitializationFailed;
        };
        return;
    }

    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = scif.send(self.epd, bytes[offset..].ptr, bytes.len - offset, scif.send_block);
        if (written <= 0) {
            return VkError.InitializationFailed;
        }
        offset += @intCast(written);
    }
}

fn readAll(self: *Self, bytes: []u8) VkError!void {
    if (comptime lib.config.phi_host_emulation) {
        var buffer: [0]u8 = .{};
        var reader = self.epd.reader(self.instance.io(), &buffer);
        reader.interface.readSliceAll(bytes) catch |err| {
            std.log.scoped(.PhiTransport).err("TCP receive failed: {s}", .{@errorName(err)});
            return VkError.InitializationFailed;
        };
        return;
    }

    var offset: usize = 0;
    while (offset < bytes.len) {
        const read = scif.recv(self.epd, bytes[offset..].ptr, bytes.len - offset, scif.recv_block);
        if (read <= 0) {
            return VkError.InitializationFailed;
        }
        offset += @intCast(read);
    }
}

fn closeEndpoint(endpoint: Endpoint, io: std.Io) void {
    if (comptime lib.config.phi_host_emulation)
        endpoint.close(io)
    else
        _ = scif.close(endpoint);
}

fn handshake(self: *Self) VkError!void {
    const request_payload: proto.PhiHelloRequest = .{
        .host_protocol_version = proto.PHI_PROTOCOL_VERSION,
        .reserved = 0,
    };

    // SAFETY: will be entirely written by the request
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
