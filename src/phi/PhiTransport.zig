const std = @import("std");
const base = @import("base");
const lib = @import("lib.zig");
const scif = @import("scif.zig");

const VkError = base.VkError;
const proto = lib.proto;
const Endpoint = scif.epd_t;

const Self = @This();

epd: Endpoint,
sequence: u64 = 1,
mutex: std.Io.Mutex = .init,
endpoint_mutex: base.SpinMutex = .{},
library_loaded: bool = true,
instance: *base.Instance,
node_id: u16,

pub fn init(instance: *base.Instance, node_id: u16) VkError!Self {
    const epd = blk: {
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
        closeEndpoint(epd);
        scif.unload();
    }

    var self: Self = .{
        .epd = epd,
        .instance = instance,
        .node_id = node_id,
    };
    try self.handshake();

    std.log.scoped(.PhiTransport).info("Successfully connected", .{});
    return self;
}

pub fn connectPeer(self: *const Self) VkError!Self {
    return init(self.instance, self.node_id);
}

pub fn deinit(self: *Self) void {
    var reply: proto.PhiResult = undefined;
    self.request(proto.PHI_PACKET_SHUTDOWN, &.{}, std.mem.asBytes(&reply)) catch |err| {
        std.log.scoped(.PhiTransport).warn("Failed to shut down remote session: {s}", .{@errorName(err)});
    };

    self.close();
    std.log.scoped(.PhiTransport).info("Closed connection", .{});
}

/// Close the endpoint so a thread blocked in SCIF receive wakes up. The SCIF
/// library stays loaded until `close`, because that thread may still be
/// returning through a dynamically loaded function.
pub fn interrupt(self: *Self) void {
    self.endpoint_mutex.lock();
    const endpoint = self.epd;
    self.epd = -1;
    self.endpoint_mutex.unlock();

    if (endpoint >= 0) closeEndpoint(endpoint);
}

/// Close a transport without issuing an RPC shutdown. Queue transports switch
/// to a raw full-duplex doorbell protocol after setup and must use this path.
pub fn close(self: *Self) void {
    self.interrupt();
    if (!self.library_loaded) return;

    self.library_loaded = false;
    scif.unload();
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

pub fn sendQueueDoorbell(self: *Self, sequence: u64) VkError!void {
    const doorbell: proto.PhiQueueDoorbell = .{
        .sequence = sequence,
    };
    try self.writeAll(std.mem.asBytes(&doorbell));
}

pub fn receiveQueueCompletion(self: *Self) VkError!proto.PhiQueueCompletion {
    // SAFETY: readAll initializes the complete structure.
    var completion: proto.PhiQueueCompletion = undefined;
    try self.readAll(std.mem.asBytes(&completion));
    return completion;
}

pub fn statusToErr(status: c_int) VkError {
    return switch (status) {
        proto.PHI_STATUS_OUT_OF_MEMORY => VkError.OutOfDeviceMemory,
        proto.PHI_STATUS_UNSUPPORTED_VERSION => VkError.InitializationFailed,
        proto.PHI_STATUS_INVALID_ARGUMENT => VkError.ValidationFailed,
        else => VkError.Unknown,
    };
}

fn writeAll(self: *Self, bytes: []const u8) VkError!void {
    const endpoint = self.getEndpoint() orelse return VkError.DeviceLost;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = scif.send(endpoint, bytes[offset..].ptr, bytes.len - offset, scif.send_block);
        if (written <= 0) {
            return VkError.DeviceLost;
        }
        offset += @intCast(written);
    }
}

fn readAll(self: *Self, bytes: []u8) VkError!void {
    const endpoint = self.getEndpoint() orelse return VkError.DeviceLost;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const read = scif.recv(endpoint, bytes[offset..].ptr, bytes.len - offset, scif.recv_block);
        if (read <= 0) {
            return VkError.DeviceLost;
        }
        offset += @intCast(read);
    }
}

fn getEndpoint(self: *Self) ?Endpoint {
    self.endpoint_mutex.lock();
    defer self.endpoint_mutex.unlock();
    return if (self.epd >= 0) self.epd else null;
}

fn closeEndpoint(endpoint: Endpoint) void {
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

pub fn registerHostMemory(self: *Self, memory: []u8) VkError!u64 {
    const endpoint = self.getEndpoint() orelse return VkError.DeviceLost;
    const offset = scif.register(
        endpoint,
        memory.ptr,
        memory.len,
        0,
        @intFromEnum(scif.Prot.read) | @intFromEnum(scif.Prot.write),
        0,
    );
    if (offset < 0) {
        return VkError.Unknown;
    }
    return @intCast(offset);
}

pub fn unregisterHostMemory(self: *Self, offset: u64, size: usize) VkError!void {
    const endpoint = self.getEndpoint() orelse return VkError.DeviceLost;
    if (scif.unregister(endpoint, @intCast(offset), size) != 0) {
        return VkError.Unknown;
    }
}
