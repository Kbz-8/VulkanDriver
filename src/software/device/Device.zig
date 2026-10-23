const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("../lib.zig");

const VkError = base.VkError;

const SoftBufferView = @import("../SoftBufferView.zig");
const SoftDescriptorSet = @import("../SoftDescriptorSet.zig");
const SoftDevice = @import("../SoftDevice.zig");
const SoftImageView = @import("../SoftImageView.zig");
const SoftPipeline = @import("../SoftPipeline.zig");
const SoftSampler = @import("../SoftSampler.zig");

const ComputeDispatcher = @import("compute/Dispatcher.zig");
const Renderer = @import("Renderer.zig");

const Self = @This();

pub const graphics_pipeline_state = 0;
pub const compute_pipeline_state = 1;
pub const max_dynamic_descriptors_per_set = 64;

pub const ActiveOcclusionQuery = struct {
    pool: *base.QueryPool,
    query: u32,
};

pub const PipelineState = struct {
    pipeline: ?*SoftPipeline,
    sets: [base.vulkan_max_descriptor_sets]?*SoftDescriptorSet,
    dynamic_offsets: [base.vulkan_max_descriptor_sets][max_dynamic_descriptors_per_set]u32,
    push_constant_blob: [lib.push_constant_size]u8,
    data: union {
        compute: struct {},
        graphics: struct {
            index_buffer: Renderer.IndexBuffer,
            vertex_buffers: [lib.max_vertex_input_bindings]Renderer.VertexBuffer,
        },
    },
};

compute: ComputeDispatcher,
renderer: Renderer,

pipeline_states: [2]PipelineState,
active_occlusion_queries: std.ArrayList(ActiveOcclusionQuery),

/// Initializating an execution device and
/// not creating one to avoid dangling pointers
pub fn setup(self: *Self, device: *SoftDevice) void {
    for (self.pipeline_states[0..], 0..) |*state, i| {
        state.* = .{
            .pipeline = null,
            .sets = @as([base.vulkan_max_descriptor_sets]?*SoftDescriptorSet, @splat(null)),
            .dynamic_offsets = @as(
                [base.vulkan_max_descriptor_sets][max_dynamic_descriptors_per_set]u32,
                @splat(@as([max_dynamic_descriptors_per_set]u32, @splat(0))),
            ),
            .push_constant_blob = @splat(0),
            .data = switch (i) {
                graphics_pipeline_state => .{
                    .graphics = .{
                        // SAFETY: indexed draws bind the index buffer before the renderer reads it.
                        .index_buffer = undefined,
                        // SAFETY: each vertex binding is populated before an attribute reads it.
                        .vertex_buffers = undefined,
                    },
                },
                compute_pipeline_state => .{ .compute = .{} },
                else => unreachable,
            },
        };
    }
    self.active_occlusion_queries = .empty;
    self.compute = .init(device, &self.pipeline_states[@backingInt(vk.PipelineBindPoint.compute)]);
    self.renderer = .init(device, &self.pipeline_states[@backingInt(vk.PipelineBindPoint.graphics)], &self.active_occlusion_queries);
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.active_occlusion_queries.deinit(allocator);
}

pub fn mapBuffer(state: *const PipelineState, set: u32, binding: u32, array_element: u32) VkError!?[]u8 {
    const set_index: usize = set;
    if (set_index >= state.sets.len)
        return null;

    const descriptor_set = state.sets[set_index] orelse return null;

    const binding_index: usize = binding;
    if (binding_index >= descriptor_set.descriptors.len or binding_index >= descriptor_set.interface.layout.bindings.len)
        return null;

    const binding_layout = descriptor_set.interface.layout.bindings[binding_index];
    const dynamic_offset: vk.DeviceSize = switch (binding_layout.descriptor_type) {
        .uniform_buffer_dynamic, .storage_buffer_dynamic => blk: {
            const dynamic_index = std.math.add(usize, binding_layout.dynamic_index, array_element) catch return VkError.ValidationFailed;
            if (dynamic_index >= state.dynamic_offsets[set_index].len)
                return VkError.ValidationFailed;

            break :blk state.dynamic_offsets[set_index][dynamic_index];
        },
        .uniform_buffer, .storage_buffer => 0,
        else => return null,
    };

    const descriptors = switch (descriptor_set.descriptors[binding_index]) {
        .buffer => |descriptors| descriptors,
        else => return null,
    };

    const descriptor_index: usize = array_element;
    if (descriptor_index >= descriptors.len)
        return null;

    const descriptor = descriptors[descriptor_index];
    const buffer = descriptor.object orelse return null;
    const effective_offset = std.math.add(vk.DeviceSize, descriptor.offset, dynamic_offset) catch return VkError.ValidationFailed;
    if (effective_offset > buffer.interface.size)
        return VkError.ValidationFailed;

    const logical_remaining = buffer.interface.size - effective_offset;
    if (descriptor.size > logical_remaining)
        return VkError.ValidationFailed;

    return try buffer.mapAsSliceWithAddedOffset(u8, effective_offset, descriptor.size);
}

pub fn mapTexelBuffer(state: *const PipelineState, set: u32, binding: u32, array_element: u32) VkError!?*SoftBufferView {
    const set_index: usize = set;
    if (set_index >= state.sets.len)
        return null;

    const descriptor_set = state.sets[set_index] orelse return null;

    const binding_index: usize = binding;
    if (binding_index >= descriptor_set.descriptors.len or binding_index >= descriptor_set.interface.layout.bindings.len)
        return null;

    switch (descriptor_set.interface.layout.bindings[binding_index].descriptor_type) {
        .uniform_texel_buffer, .storage_texel_buffer => {},
        else => return null,
    }

    const descriptors = switch (descriptor_set.descriptors[binding_index]) {
        .texel_buffer => |descriptors| descriptors,
        else => return null,
    };

    const descriptor_index: usize = array_element;
    if (descriptor_index >= descriptors.len)
        return null;

    return descriptors[descriptor_index].object;
}

pub fn mapSampledImage(state: *const PipelineState, set: u32, binding: u32, array_element: u32) VkError!?*SoftImageView {
    const set_index: usize = set;
    if (set_index >= state.sets.len)
        return null;

    const descriptor_set = state.sets[set_index] orelse return null;

    const binding_index: usize = binding;
    if (binding_index >= descriptor_set.descriptors.len or binding_index >= descriptor_set.interface.layout.bindings.len)
        return null;

    const descriptor_index: usize = array_element;
    return switch (descriptor_set.interface.layout.bindings[binding_index].descriptor_type) {
        .sampled_image => switch (descriptor_set.descriptors[binding_index]) {
            .image => |descriptors| if (descriptor_index < descriptors.len) descriptors[descriptor_index].object else null,
            else => null,
        },
        .combined_image_sampler => switch (descriptor_set.descriptors[binding_index]) {
            .texture => |descriptors| if (descriptor_index < descriptors.len) descriptors[descriptor_index].view else null,
            else => null,
        },
        else => null,
    };
}

pub fn mapSampler(state: *const PipelineState, set: u32, binding: u32, array_element: u32) VkError!?*SoftSampler {
    const set_index: usize = set;
    if (set_index >= state.sets.len)
        return null;

    const descriptor_set = state.sets[set_index] orelse return null;

    const binding_index: usize = binding;
    if (binding_index >= descriptor_set.descriptors.len or binding_index >= descriptor_set.interface.layout.bindings.len)
        return null;

    const descriptor_index: usize = array_element;
    return switch (descriptor_set.interface.layout.bindings[binding_index].descriptor_type) {
        .sampler => switch (descriptor_set.descriptors[binding_index]) {
            .sampler => |descriptors| if (descriptor_index < descriptors.len) descriptors[descriptor_index].object else null,
            else => null,
        },
        .combined_image_sampler => switch (descriptor_set.descriptors[binding_index]) {
            .texture => |descriptors| if (descriptor_index < descriptors.len) descriptors[descriptor_index].sampler else null,
            else => null,
        },
        else => null,
    };
}

pub fn mapStorageImage(state: *const PipelineState, set: u32, binding: u32, array_element: u32) VkError!?*SoftImageView {
    const set_index: usize = set;
    if (set_index >= state.sets.len)
        return null;

    const descriptor_set = state.sets[set_index] orelse return null;

    const binding_index: usize = binding;
    if (binding_index >= descriptor_set.descriptors.len or binding_index >= descriptor_set.interface.layout.bindings.len)
        return null;

    if (descriptor_set.interface.layout.bindings[binding_index].descriptor_type != .storage_image)
        return null;

    const descriptors = switch (descriptor_set.descriptors[binding_index]) {
        .image => |descriptors| descriptors,
        else => return null,
    };

    const descriptor_index: usize = array_element;
    if (descriptor_index >= descriptors.len)
        return null;

    return descriptors[descriptor_index].object;
}
