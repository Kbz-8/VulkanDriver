const std = @import("std");
const vk = @import("vulkan");

const Dispatchable = @import("Dispatchable.zig").Dispatchable;
const VkError = @import("error_set.zig").VkError;
const VulkanAllocator = @import("VulkanAllocator.zig");

const CommandBuffer = @import("CommandBuffer.zig");
const Device = @import("Device.zig");

const Fence = @import("Fence.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .queue;

owner: *Device,
family_index: u32,
index: u32,
flags: vk.DeviceQueueCreateFlags,
host_allocator: VulkanAllocator,

dispatch_table: *const DispatchTable,

pub const DispatchTable = struct {
    bindSparse: *const fn (*Self, []const vk.BindSparseInfo, ?*Fence) VkError!void,
    submit: *const fn (*Self, []SubmitInfo, ?*Fence) VkError!void,
    waitIdle: *const fn (*Self) VkError!void,
};

pub const SubmitInfo = struct {
    command_buffers: std.ArrayList(*CommandBuffer),
    // TODO: complete

    fn initBlob(allocator: std.mem.Allocator, infos: []const vk.SubmitInfo) VkError!std.ArrayList(SubmitInfo) {
        var self = std.ArrayList(SubmitInfo).initCapacity(allocator, infos.len) catch return VkError.OutOfHostMemory;
        errdefer self.deinit(allocator);

        loop: for (infos) |info| {
            if (info.command_buffer_count == 0) continue :loop;
            if (info.p_command_buffers == null) continue :loop;

            var submit_info: SubmitInfo = .{
                .command_buffers = std.ArrayList(*CommandBuffer).initCapacity(allocator, info.command_buffer_count) catch return VkError.OutOfHostMemory,
            };

            for (info.p_command_buffers.?[0..info.command_buffer_count]) |vk_command_buffer| {
                submit_info.command_buffers.append(allocator, try Dispatchable(CommandBuffer).fromHandleObject(vk_command_buffer)) catch return VkError.OutOfHostMemory;
            }

            self.append(allocator, submit_info) catch return VkError.OutOfHostMemory;
        }
        return self;
    }

    fn deinitBlob(allocator: std.mem.Allocator, self: *std.ArrayList(SubmitInfo)) void {
        for (self.items) |submit_info| {
            const command_buffers = &submit_info.command_buffers;
            @constCast(command_buffers).deinit(allocator);
        }
        self.deinit(allocator);
    }
};

pub fn init(allocator: std.mem.Allocator, device: *Device, index: u32, family_index: u32, flags: vk.DeviceQueueCreateFlags) VkError!Self {
    std.log.scoped(.vkCreateDevice).debug("Creating device queue with family index {d} and index {d}", .{ family_index, index });
    return .{
        .owner = device,
        .family_index = family_index,
        .index = index,
        .flags = flags,
        .host_allocator = VulkanAllocator.from(allocator).clone(),
        .dispatch_table = undefined,
    };
}

pub inline fn bindSparse(self: *Self, info: []const vk.BindSparseInfo, fence: ?*Fence) VkError!void {
    try self.dispatch_table.bindSparse(self, info, fence);
}

pub inline fn submit(self: *Self, infos: []const vk.SubmitInfo, p_fence: ?*Fence) VkError!void {
    const allocator = self.host_allocator.cloneWithScope(.command).allocator();

    var submit_infos = try SubmitInfo.initBlob(allocator, infos);
    defer SubmitInfo.deinitBlob(allocator, &submit_infos);

    try self.dispatch_table.submit(self, submit_infos.items, p_fence);
}

pub inline fn waitIdle(self: *Self) VkError!void {
    try self.dispatch_table.waitIdle(self);
}
