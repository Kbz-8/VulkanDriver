const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");

const PipelineState = @import("PipelineState.zig");

const SoftDevice = @import("../SoftDevice.zig");
const SoftPipeline = @import("../SoftPipeline.zig");

const VkError = base.VkError;

const Self = @This();

device: *SoftDevice,
state: *PipelineState,

pub fn init(device: *SoftDevice, state: *PipelineState) Self {
    return .{
        .device = device,
        .state = state,
    };
}

pub fn destroy(self: *Self) void {
    _ = self;
}
