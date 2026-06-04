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
pub const MAX_DYNAMIC_DESCRIPTORS_PER_SET = 64;

pub const PipelineState = struct {
    pipeline: ?*SoftPipeline,
    sets: [base.VULKAN_MAX_DESCRIPTOR_SETS]?*SoftDescriptorSet,
    dynamic_offsets: [base.VULKAN_MAX_DESCRIPTOR_SETS][MAX_DYNAMIC_DESCRIPTORS_PER_SET]u32,
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
            .dynamic_offsets = [_][MAX_DYNAMIC_DESCRIPTORS_PER_SET]u32{[_]u32{0} ** MAX_DYNAMIC_DESCRIPTORS_PER_SET} ** base.VULKAN_MAX_DESCRIPTOR_SETS,
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
                        const binding_layout = set.?.interface.layout.bindings[binding_index];
                        const dynamic_offset: vk.DeviceSize = switch (binding_layout.descriptor_type) {
                            .uniform_buffer_dynamic, .storage_buffer_dynamic => state.dynamic_offsets[set_index][binding_layout.dynamic_index + descriptor_index],
                            else => 0,
                        };
                        const map = buffer.mapAsSliceWithAddedOffset(u8, buffer_data.offset + dynamic_offset, buffer_data.size) catch continue :bindings;
                        rt.writeDescriptorSet(
                            map,
                            @as(u32, @intCast(set_index)),
                            @as(u32, @intCast(binding_index)),
                            @as(u32, @intCast(descriptor_index)),
                        ) catch |err| switch (err) {
                            error.NotFound => {},
                            else => return err,
                        };
                    }
                },

                .image => |image_data_array| for (image_data_array, 0..) |image_data, descriptor_index| {
                    if (image_data.object) |image_view| {
                        const addr: usize = @intFromPtr(image_view);
                        rt.writeDescriptorSet(
                            std.mem.asBytes(&addr),
                            @as(u32, @intCast(set_index)),
                            @as(u32, @intCast(binding_index)),
                            @as(u32, @intCast(descriptor_index)),
                        ) catch |err| switch (err) {
                            error.NotFound => {},
                            else => return err,
                        };
                    }
                },

                .sampler => |sampler_data_array| for (sampler_data_array, 0..) |sampler_data, descriptor_index| {
                    if (sampler_data.object) |sampler| {
                        const addr: usize = @intFromPtr(sampler);
                        rt.writeDescriptorSet(
                            std.mem.asBytes(&addr),
                            @as(u32, @intCast(set_index)),
                            @as(u32, @intCast(binding_index)),
                            @as(u32, @intCast(descriptor_index)),
                        ) catch |err| switch (err) {
                            error.NotFound => {},
                            else => return err,
                        };
                    }
                },

                .texel_buffer => |texel_data_array| for (texel_data_array, 0..) |texel_data, descriptor_index| {
                    if (texel_data.object) |buffer_view| {
                        const addr: usize = @intFromPtr(buffer_view);
                        rt.writeDescriptorSet(
                            std.mem.asBytes(&addr),
                            @as(u32, @intCast(set_index)),
                            @as(u32, @intCast(binding_index)),
                            @as(u32, @intCast(descriptor_index)),
                        ) catch |err| switch (err) {
                            error.NotFound => {},
                            else => return err,
                        };
                    }
                },

                .texture => |texture_data_array| for (texture_data_array, 0..) |texture_data, descriptor_index| {
                    const SampledImage = packed struct {
                        image: usize,
                        sampler: usize,
                    };

                    var data: SampledImage = .{
                        .image = 0,
                        .sampler = 0,
                    };

                    if (texture_data.view) |image_view| {
                        const addr: usize = @intFromPtr(image_view);
                        data.image = addr;
                    }
                    if (texture_data.sampler) |sampler| {
                        const addr: usize = @intFromPtr(sampler);
                        data.sampler = addr;
                    }

                    rt.writeDescriptorSet(
                        std.mem.asBytes(&data),
                        @as(u32, @intCast(set_index)),
                        @as(u32, @intCast(binding_index)),
                        @as(u32, @intCast(descriptor_index)),
                    ) catch |err| switch (err) {
                        error.NotFound => {},
                        else => return err,
                    };
                },

                else => {},
            }
        }
    }
}
