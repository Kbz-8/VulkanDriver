const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const SoftDescriptorSet = @import("../SoftDescriptorSet.zig");
const SoftDevice = @import("../SoftDevice.zig");
const SoftPipeline = @import("../SoftPipeline.zig");

const ComputeRoutines = @import("ComputeRoutines.zig");
const PipelineState = @import("PipelineState.zig");

const VkError = base.VkError;

const Self = @This();

compute_routines: ComputeRoutines,

/// .graphics = 0
/// .compute = 1
pipeline_states: [2]PipelineState,

pub const init: Self = .{
    .compute_routines = undefined,
    .pipeline_states = undefined,
};

pub fn setup(self: *Self, device: *SoftDevice) void {
    for (self.pipeline_states[0..]) |*state| {
        state.* = .{
            .pipeline = null,
            .sets = [_]?*SoftDescriptorSet{null} ** base.VULKAN_MAX_DESCRIPTOR_SETS,
        };
    }
    self.compute_routines = .init(device, &self.pipeline_states[@intFromEnum(vk.PipelineBindPoint.compute)]);
}

pub fn deinit(self: *Self) void {
    self.compute_routines.destroy();
}
