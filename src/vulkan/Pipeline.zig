const std = @import("std");
const vk = @import("vulkan");

const NonDispatchable = @import("NonDispatchable.zig");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");
const PipelineCache = @import("PipelineCache.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .pipeline;

owner: *Device,

vtable: *const VTable,
bind_point: vk.PipelineBindPoint,
stages: vk.ShaderStageFlags,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn initCompute(device: *Device, allocator: std.mem.Allocator, cache: ?*PipelineCache, info: *const vk.ComputePipelineCreateInfo) VkError!Self {
    _ = allocator;
    _ = cache;

    return .{
        .owner = device,
        .vtable = undefined,
        .bind_point = .compute,
        .stages = info.stage.stage,
    };
}

pub fn initGraphics(device: *Device, allocator: std.mem.Allocator, cache: ?*PipelineCache, info: *const vk.GraphicsPipelineCreateInfo) VkError!Self {
    _ = allocator;
    _ = cache;

    var stages: vk.ShaderStageFlags = .{};
    if (info.p_stages) |p_stages| {
        for (p_stages[0..info.stage_count]) |stage| {
            stages = stages.merge(stage.stage);
        }
    }

    return .{
        .owner = device,
        .vtable = undefined,
        .bind_point = .graphics,
        .stages = stages,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}
