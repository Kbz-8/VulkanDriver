const std = @import("std");
const vk = @import("vulkan");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");
const VulkanAllocator = @import("VulkanAllocator.zig");

const DescriptorSet = @import("DescriptorSet.zig");
const DescriptorSetLayout = @import("DescriptorSetLayout.zig");
const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;

const Self = @This();
pub const ObjectType: vk.ObjectType = .descriptor_pool;

owner: *Device,
flags: vk.DescriptorPoolCreateFlags,
max_sets: u32,
host_allocator: VulkanAllocator,
sets: std.ArrayList(*NonDispatchable(DescriptorSet)),

vtable: *const VTable,

pub const VTable = struct {
    allocateDescriptorSet: *const fn (*Self, *DescriptorSetLayout) VkError!*DescriptorSet,
    destroy: *const fn (*Self, std.mem.Allocator) void,
    freeDescriptorSet: *const fn (*Self, *DescriptorSet) VkError!void,
    reset: *const fn (*Self, vk.DescriptorPoolResetFlags) VkError!void,
};

pub fn init(device: *Device, alloc: std.mem.Allocator, info: *const vk.DescriptorPoolCreateInfo) VkError!Self {
    return .{
        .owner = device,
        .flags = info.flags,
        .max_sets = info.max_sets,
        .host_allocator = VulkanAllocator.from(alloc).clone(),
        .sets = .empty,
        // SAFETY: the backend assigns the vtable before returning the descriptor pool.
        .vtable = undefined,
    };
}

pub fn allocateDescriptorSet(self: *Self, layout: *DescriptorSetLayout) VkError!*NonDispatchable(DescriptorSet) {
    if (self.sets.items.len >= @as(usize, self.max_sets))
        return VkError.OutOfPoolMemory;

    const set = try self.vtable.allocateDescriptorSet(self, layout);
    errdefer self.vtable.freeDescriptorSet(self, set) catch @panic("Caught an error while handling an error");

    const alloc = self.host_allocator.allocator();
    const handle = try NonDispatchable(DescriptorSet).wrap(alloc, set);
    errdefer handle.destroy(alloc);

    self.sets.append(alloc, handle) catch return VkError.OutOfHostMemory;
    return handle;
}

pub inline fn destroy(self: *Self, alloc: std.mem.Allocator) void {
    const handle_allocator = self.host_allocator.allocator();
    for (self.sets.items) |set| set.destroy(handle_allocator);
    self.sets.deinit(handle_allocator);
    self.vtable.destroy(self, alloc);
}

pub fn freeDescriptorSet(self: *Self, set: *NonDispatchable(DescriptorSet)) VkError!void {
    const index = std.mem.indexOfScalar(*NonDispatchable(DescriptorSet), self.sets.items, set) orelse
        return VkError.ValidationFailed;

    try self.vtable.freeDescriptorSet(self, set.object);
    _ = self.sets.swapRemove(index);
    set.destroy(self.host_allocator.allocator());
}

pub fn reset(self: *Self, flags: vk.DescriptorPoolResetFlags) VkError!void {
    try self.vtable.reset(self, flags);

    const alloc = self.host_allocator.allocator();
    for (self.sets.items) |set|
        set.destroy(alloc);
    self.sets.clearRetainingCapacity();
}

pub inline fn allocator(self: *Self) std.mem.Allocator {
    return self.host_allocator.allocator();
}
