const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("lib.zig");
const proto = lib.proto;

const PhiCommandBuffer = @import("PhiCommandBuffer.zig");
const PhiDevice = @import("PhiDevice.zig");
const PhiTransport = @import("PhiTransport.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Queue;

interface: Interface,

pub fn create(allocator: std.mem.Allocator, device: *base.Device, index: u32, family_index: u32, flags: vk.DeviceQueueCreateFlags) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, device, index, family_index, flags);
    interface.dispatch_table = &.{
        .bindSparse = bindSparse,
        .submit = submit,
        .waitIdle = waitIdle,
    };

    self.* = .{ .interface = interface };
    return &self.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

pub fn bindSparse(interface: *Interface, info: []const vk.BindSparseInfo, fence: ?*base.Fence) VkError!void {
    _ = interface;
    _ = info;
    _ = fence;
    return VkError.FeatureNotPresent;
}

pub fn submit(interface: *Interface, infos: []Interface.SubmitInfo, fence: ?*base.Fence) VkError!void {
    const device: *PhiDevice = @alignCast(@fieldParentPtr("interface", interface.owner));

    for (infos) |info| {
        for (info.wait_semaphores.items) |semaphore| {
            try semaphore.wait();
        }

        for (info.command_buffers.items) |command_buffer| {
            const phi_command_buffer: *PhiCommandBuffer = @alignCast(@fieldParentPtr("interface", command_buffer));

            const work_execution_request: proto.PhiWorkExecutionRequest = .{
                .cmd_count = phi_command_buffer.serialized_cmd_count,
                .command_buffer_size = phi_command_buffer.commands.items.len,
            };
            const payload_size = @sizeOf(proto.PhiWorkExecutionRequest) + phi_command_buffer.commands.items.len;
            const allocator = interface.host_allocator.allocator();
            const payload = allocator.alloc(u8, payload_size) catch return VkError.OutOfHostMemory;
            defer allocator.free(payload);

            @memcpy(payload[0..@sizeOf(proto.PhiWorkExecutionRequest)], std.mem.asBytes(&work_execution_request));
            @memcpy(payload[@sizeOf(proto.PhiWorkExecutionRequest)..], phi_command_buffer.commands.items);

            // Synchronous queues for now
            var reply = std.mem.zeroes(proto.PhiWorkExecutionReply);
            try device.transport.request(proto.PHI_PACKET_WORK_EXECUTION, payload, std.mem.asBytes(&reply));

            if (reply.result.status != proto.PHI_STATUS_OK) {
                return PhiTransport.statusToErr(reply.result.status);
            }
        }

        for (info.signal_semaphores.items) |semaphore| {
            try semaphore.signal();
        }
    }
    if (fence) |value| {
        try value.signal();
    }
}

pub fn waitIdle(interface: *Interface) VkError!void {
    _ = interface;
}
