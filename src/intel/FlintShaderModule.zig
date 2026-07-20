const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.ShaderModule;

interface: Interface,
code: []u32,
ref_count: std.atomic.Value(usize),

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.ShaderModuleCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);
    interface.vtable = &.{ .destroy = destroy };
    if (info.code_size % @sizeOf(u32) != 0) return VkError.ValidationFailed;
    const code = allocator.dupe(u32, info.p_code[0 .. info.code_size / @sizeOf(u32)]) catch return VkError.OutOfHostMemory;
    errdefer allocator.free(code);

    self.* = .{
        .interface = interface,
        .code = code,
        .ref_count = std.atomic.Value(usize).init(1),
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.unref(allocator);
}

pub fn drop(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.code);
    allocator.destroy(self);
}

pub fn ref(self: *Self) void {
    _ = self.ref_count.fetchAdd(1, .monotonic);
}

pub fn unref(self: *Self, allocator: std.mem.Allocator) void {
    if (self.ref_count.fetchSub(1, .release) == 1) {
        self.drop(allocator);
    }
}
