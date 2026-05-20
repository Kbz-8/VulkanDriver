const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("../lib.zig");
const spv = @import("spv");

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
    push_constant_blob: [lib.PUSH_CONSTANT_SIZE]u8,
    data: union {
        compute: struct {},
        graphics: struct {
            index_buffer: Renderer.IndexBuffer,
            vertex_buffers: [lib.MAX_VERTEX_INPUT_BINDINGS]Renderer.VertexBuffer,
        },
    },
};

compute: ComputeDispatcher,
renderer: Renderer,

pipeline_states: [2]PipelineState,

/// Initializating an execution device and
/// not creating one to avoid dangling pointers
pub fn setup(self: *Self, device: *SoftDevice) void {
    for (self.pipeline_states[0..], 0..) |*state, i| {
        state.* = .{
            .pipeline = null,
            .sets = [_]?*SoftDescriptorSet{null} ** base.VULKAN_MAX_DESCRIPTOR_SETS,
            .push_constant_blob = @splat(0),
            .data = switch (i) {
                GRAPHICS_PIPELINE_STATE => .{
                    .graphics = .{
                        .index_buffer = undefined,
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

pub fn writeDescriptorSets(state: *PipelineState, rt: *spv.Runtime) !void {
    sets: for (state.sets[0..], 0..) |set, set_index| {
        if (set == null)
            continue :sets;

        bindings: for (set.?.descriptors[0..], 0..) |binding, binding_index| {
            switch (binding) {
                .buffer => |buffer_data_array| for (buffer_data_array, 0..) |buffer_data, descriptor_index| {
                    if (buffer_data.object) |buffer| {
                        const map = buffer.mapAsSliceWithOffset(u8, buffer_data.offset, buffer_data.size) catch continue :bindings;
                        try rt.writeDescriptorSet(
                            map,
                            @as(u32, @intCast(set_index)),
                            @as(u32, @intCast(binding_index)),
                            @as(u32, @intCast(descriptor_index)),
                        );
                    }
                },

                .image => |image_data_array| for (image_data_array, 0..) |image_data, descriptor_index| {
                    if (image_data.object) |image_view| {
                        const addr: usize = @intFromPtr(image_view);
                        try rt.writeDescriptorSet(
                            std.mem.asBytes(&addr),
                            @as(u32, @intCast(set_index)),
                            @as(u32, @intCast(binding_index)),
                            @as(u32, @intCast(descriptor_index)),
                        );
                    }
                },

                .texel_buffer => |texel_data_array| for (texel_data_array, 0..) |texel_data, descriptor_index| {
                    if (texel_data.object) |buffer_view| {
                        const addr: usize = @intFromPtr(buffer_view);
                        try rt.writeDescriptorSet(
                            std.mem.asBytes(&addr),
                            @as(u32, @intCast(set_index)),
                            @as(u32, @intCast(binding_index)),
                            @as(u32, @intCast(descriptor_index)),
                        );
                    }
                },

                .texture => |texture_data_array| for (texture_data_array, 0..) |texture_data, descriptor_index| {
                    const SampledImage = packed struct {
                        image: usize,
                        sampler: usize,
                    };

                    var data: SampledImage = undefined;

                    if (texture_data.view) |image_view| {
                        const addr: usize = @intFromPtr(image_view);
                        data.image = addr;
                    }
                    if (texture_data.sampler) |sampler| {
                        const addr: usize = @intFromPtr(sampler);
                        data.sampler = addr;
                    }

                    try rt.writeDescriptorSet(
                        std.mem.asBytes(&data),
                        @as(u32, @intCast(set_index)),
                        @as(u32, @intCast(binding_index)),
                        @as(u32, @intCast(descriptor_index)),
                    );
                },

                else => {},
            }
        }
    }
}
