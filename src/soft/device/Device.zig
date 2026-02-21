const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const copy_routines = @import("copy_routines.zig");

const SoftDescriptorSet = @import("../SoftDescriptorSet.zig");
const SoftDevice = @import("../SoftDevice.zig");
const SoftPipeline = @import("../SoftPipeline.zig");

const ComputeRoutines = @import("ComputeRoutines.zig");
const PipelineState = @import("PipelineState.zig");

const cmd = base.commands;
const VkError = base.VkError;

const Self = @This();

compute_routine: ComputeRoutines,

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

    self.compute_routine = .init(device, &self.pipeline_states[@intFromEnum(vk.PipelineBindPoint.compute)]);

    return self;
}

pub fn deinit(self: *Self) void {
    self.compute_routine.destroy();
}

pub fn execute(self: *Self, command: *const cmd.Command) VkError!void {
    switch (command.*) {
        .BindDescriptorSets => |data| {
            for (data.first_set.., data.sets[0..]) |i, set| {
                if (set == null) break;
                self.pipeline_states[@intCast(@intFromEnum(data.bind_point))].sets[i] = @alignCast(@fieldParentPtr("interface", set.?));
            }
        },
        .BindPipeline => |data| self.pipeline_states[@intCast(@intFromEnum(data.bind_point))].pipeline = @alignCast(@fieldParentPtr("interface", data.pipeline)),
        .ClearColorImage => |data| try copy_routines.clearColorImage(&data),
        .CopyBuffer => |data| try copy_routines.copyBuffer(&data),
        .CopyImage => |data| try copy_routines.copyImage(&data),
        .CopyImageToBuffer => |data| try copy_routines.copyImageToBuffer(&data),
        .FillBuffer => |data| try copy_routines.fillBuffer(&data),
        else => {},
    }
}
