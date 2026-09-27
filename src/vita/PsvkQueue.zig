const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Queue;

interface: Interface,

pub fn create(allocator: std.mem.Allocator, device: *base.Device, index: u32, family_index: u32, flags: vk.DeviceQueueCreateFlags) VkError!*Interface {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(allocator, device, index, family_index, flags);

    interface.dispatch_table = &.{ .bindSparse = bindSparse, .submit = submit, .waitIdle = waitIdle };
    self.* = .{
        .interface = interface,
    };
    return &self.interface;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) VkError!void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    allocator.destroy(self);
}

pub fn bindSparse(_: *Interface, _: []const vk.BindSparseInfo, _: ?*base.Fence) VkError!void {
    return;
}

pub fn submit(_: *Interface, _: []Interface.SubmitInfo, _: ?*base.Fence) VkError!void {
    return;
}

pub fn waitIdle(_: *Interface) VkError!void {
    return;
}
