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

/// Initializating an execution device and
/// not creating one to avoid dangling pointers
pub fn init(self: *Self, device: *SoftDevice) void {
    for (self.pipeline_states[0..]) |*state| {
        state.* = .{
            .pipeline = null,
            .sets = [_]?*SoftDescriptorSet{null} ** base.VULKAN_MAX_DESCRIPTOR_SETS,
        };
    }
    self.compute = .init(device, &self.pipeline_states[@intFromEnum(vk.PipelineBindPoint.compute)]);
    self.renderer = .init();
}

pub fn deinit(self: *Self) void {
    self.compute.deinit();
    self.renderer.deinit();
}
