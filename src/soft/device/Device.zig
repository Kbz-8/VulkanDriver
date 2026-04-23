const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const SoftDescriptorSet = @import("../SoftDescriptorSet.zig");
const SoftDevice = @import("../SoftDevice.zig");
const SoftFramebuffer = @import("../SoftFramebuffer.zig");
const SoftPipeline = @import("../SoftPipeline.zig");
const SoftRenderPass = @import("../SoftRenderPass.zig");

const ComputeDispatcher = @import("ComputeDispatcher.zig");
const Renderer = @import("Renderer.zig");

const VkError = base.VkError;

const Self = @This();

pub const PipelineState = struct {
    pipeline: ?*SoftPipeline,
    sets: [base.VULKAN_MAX_DESCRIPTOR_SETS]?*SoftDescriptorSet,
};

compute: ComputeDispatcher,
renderer: Renderer,

/// .graphics = 0
/// .compute = 1
pipeline_states: [2]PipelineState,

pub fn init(device: *SoftDevice) Self {
    var self: Self = undefined;

    for (self.pipeline_states[0..]) |*state| {
        state.* = .{
            .pipeline = null,
            .sets = [_]?*SoftDescriptorSet{null} ** base.VULKAN_MAX_DESCRIPTOR_SETS,
        };
    }
    self.compute = .init(device, &self.pipeline_states[@intFromEnum(vk.PipelineBindPoint.compute)]);
    self.renderer = .init();

    return self;
}

pub fn deinit(self: *Self) void {
    self.compute.deinit();
    self.renderer.deinit();
}
