const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");

const SoftDevice = @import("../SoftDevice.zig");
const SoftPipeline = @import("../SoftPipeline.zig");

const VkError = base.VkError;

const Self = @This();

device: *SoftDevice,
pipeline: ?*SoftPipeline,

pub fn init(device: *SoftDevice) Self {
    return .{
        .device = device,
        .pipeline = null,
    };
}

pub fn destroy(self: *Self) void {
    _ = self;
}

pub fn bindPipeline(self: *Self, pipeline: *SoftPipeline) void {
    self.pipeline = pipeline;
}
