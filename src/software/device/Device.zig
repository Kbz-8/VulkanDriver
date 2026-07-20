const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("../lib.zig");
const spv = @import("spv");

const SoftDescriptorSet = @import("../SoftDescriptorSet.zig");
const SoftDevice = @import("../SoftDevice.zig");
const SoftPipeline = @import("../SoftPipeline.zig");

const ComputeDispatcher = @import("ComputeDispatcher.zig");
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
            .sets = [_]?*SoftDescriptorSet{null} ** base.vulkan_max_descriptor_sets,
            .dynamic_offsets = [_][max_dynamic_descriptors_per_set]u32{[_]u32{0} ** max_dynamic_descriptors_per_set} ** base.vulkan_max_descriptor_sets,
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
    self.compute = .init(device, &self.pipeline_states[@intFromEnum(vk.PipelineBindPoint.compute)]);
    self.renderer = .init(device, &self.pipeline_states[@intFromEnum(vk.PipelineBindPoint.graphics)], &self.active_occlusion_queries);
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.active_occlusion_queries.deinit(allocator);
}

const SampledImageDescriptor = struct {
    image: usize,
    sampler: usize,
};

const DescriptorPayload = union(enum) {
    raw: []const u8,
    sampled_image: SampledImageDescriptor,
};

fn writeDescriptorValue(value: anytype, payload: DescriptorPayload, descriptor_index: u32) spv.Runtime.RuntimeError!void {
    const dst = switch (value.*) {
        .Array => |arr| blk: {
            if (descriptor_index >= arr.values.len)
                return spv.Runtime.RuntimeError.NotFound;
            break :blk &arr.values[descriptor_index];
        },
        else => blk: {
            if (descriptor_index != 0)
                return spv.Runtime.RuntimeError.NotFound;
            break :blk value;
        },
    };

    switch (payload) {
        .raw => |data| {
            _ = try dst.write(data);
        },
        .sampled_image => |data| switch (dst.*) {
            .Image => _ = try dst.write(std.mem.asBytes(&data.image)),
            .Sampler => _ = try dst.write(std.mem.asBytes(&data.sampler)),
            .SampledImage => _ = try dst.write(std.mem.asBytes(&data)),
            else => return spv.Runtime.RuntimeError.InvalidValueType,
        },
    }
}

fn writeDescriptorSet(rt: *spv.Runtime, payload: DescriptorPayload, set: u32, binding: u32, descriptor_index: u32) spv.Runtime.RuntimeError!void {
    var found = false;
    for (rt.mod.bindings.items) |entry| {
        if (entry.set != set or entry.binding != binding)
            continue;
        const variable = if (rt.results[entry.result].variant) |*variant| switch (variant.*) {
            .Variable => |*variable| variable,
            else => continue,
        } else continue;

        writeDescriptorValue(&variable.value, payload, descriptor_index) catch |err| switch (err) {
            spv.Runtime.RuntimeError.InvalidValueType,
            spv.Runtime.RuntimeError.OutOfBounds,
            => continue,
            else => return err,
        };
        found = true;
    }

    if (!found)
        return spv.Runtime.RuntimeError.NotFound;
}

pub fn writeDescriptorSets(state: *PipelineState, rt: *spv.Runtime) !void {
    sets: for (state.sets[0..], 0..) |set, set_index| {
        if (set == null)
            continue :sets;

        bindings: for (set.?.descriptors[0..], 0..) |binding, binding_index| {
            switch (binding) {
                .buffer => |buffer_data_array| for (buffer_data_array, 0..) |buffer_data, descriptor_index| {
                    if (buffer_data.object) |buffer| {
                        const memory = buffer.interface.memory orelse continue;
                        if (@intFromPtr(memory.vtable) == 0)
                            continue;

                        const binding_layout = set.?.interface.layout.bindings[binding_index];
                        const dynamic_offset: vk.DeviceSize = switch (binding_layout.descriptor_type) {
                            .uniform_buffer_dynamic,
                            .storage_buffer_dynamic,
                            => state.dynamic_offsets[set_index][binding_layout.dynamic_index + descriptor_index],

                            else => 0,
                        };

                        const map = buffer.mapAsSliceWithAddedOffset(u8, buffer_data.offset + dynamic_offset, buffer_data.size) catch continue :bindings;
                        writeDescriptorSet(
                            rt,
                            .{ .raw = map },
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
                        writeDescriptorSet(
                            rt,
                            .{ .raw = std.mem.asBytes(&addr) },
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
                        writeDescriptorSet(
                            rt,
                            .{ .raw = std.mem.asBytes(&addr) },
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
                        writeDescriptorSet(
                            rt,
                            .{ .sampled_image = .{ .image = addr, .sampler = addr } },
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
                    var data: SampledImageDescriptor = .{
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

                    writeDescriptorSet(
                        rt,
                        .{ .sampled_image = data },
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
