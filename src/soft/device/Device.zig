const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("../lib.zig");

const SoftDescriptorSet = @import("../SoftDescriptorSet.zig");
const SoftDevice = @import("../SoftDevice.zig");
const SoftFramebuffer = @import("../SoftFramebuffer.zig");
const SoftPipeline = @import("../SoftPipeline.zig");
const SoftRenderPass = @import("../SoftRenderPass.zig");

const ComputeDispatcher = @import("ComputeDispatcher.zig");
const Renderer = @import("Renderer.zig");

const VkError = base.VkError;

const Self = @This();

pub const GRAPHICS_PIPELINE_STATE = 0;
pub const COMPUTE_PIPELINE_STATE = 1;

pub const PipelineState = struct {
    pipeline: ?*SoftPipeline,
    sets: [base.VULKAN_MAX_DESCRIPTOR_SETS]?*SoftDescriptorSet,
    data: union {
        compute: struct {},
        graphics: struct {
            vertex_buffers: [lib.MAX_VERTEX_INPUT_BINDINGS]Renderer.VertexBuffer,
        },
    },
};

compute: ComputeDispatcher,
renderer: Renderer,

pipeline_states: [2]PipelineState,

/// Initializating an execution device and
/// not creating one to avoid dangling pointers
pub fn init(self: *Self, device: *SoftDevice) void {
    for (self.pipeline_states[0..], 0..) |*state, i| {
        state.* = .{
            .pipeline = null,
            .sets = [_]?*SoftDescriptorSet{null} ** base.VULKAN_MAX_DESCRIPTOR_SETS,
            .data = switch (i) {
                GRAPHICS_PIPELINE_STATE => .{
                    .graphics = .{
                        .vertex_buffers = undefined,
                    },
                },
                COMPUTE_PIPELINE_STATE => .{ .compute = .{} },
                else => unreachable,
            },
        };
    }
    self.compute = .init(device, &self.pipeline_states[@intFromEnum(vk.PipelineBindPoint.compute)]);
    self.renderer = .init(device, &self.pipeline_states[@intFromEnum(vk.PipelineBindPoint.graphics)]);
}

pub fn deinit(self: *Self) void {
    self.compute.deinit();
    self.renderer.deinit();
}
