const std = @import("std");
const vk = @import("vulkan");

const NonDispatchable = @import("NonDispatchable.zig");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");
const PipelineCache = @import("PipelineCache.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .pipeline;

owner: *Device,

vtable: *const VTable,
bind_point: vk.PipelineBindPoint,
stages: vk.ShaderStageFlags,
mode: union(enum) {
    compute: struct {},
    graphics: struct {
        input_assembly: struct {
            binding_description: ?[]vk.VertexInputBindingDescription,
            attribute_description: ?[]vk.VertexInputAttributeDescription,
            topology: vk.PrimitiveTopology,
        },
        viewport_state: struct {
            viewports: []vk.Viewport,
            scissor: []vk.Rect2D,
        },
        rasterization: struct {
            polygon_mode: vk.PolygonMode,
            cull_mode: vk.CullModeFlags,
            front_face: vk.FrontFace,
            line_width: f32,
        },
    },
},

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn initCompute(device: *Device, allocator: std.mem.Allocator, cache: ?*PipelineCache, info: *const vk.ComputePipelineCreateInfo) VkError!Self {
    _ = allocator;
    _ = cache;

    return .{
        .owner = device,
        .vtable = undefined,
        .bind_point = .compute,
        .stages = info.stage.stage,
        .mode = .{ .compute = .{} },
    };
}

pub fn initGraphics(device: *Device, allocator: std.mem.Allocator, cache: ?*PipelineCache, info: *const vk.GraphicsPipelineCreateInfo) VkError!Self {
    _ = cache;

    var stages: vk.ShaderStageFlags = .{};
    if (info.p_stages) |p_stages| {
        for (p_stages[0..info.stage_count]) |stage| {
            stages = stages.merge(stage.stage);
        }
    }

    return .{
        .owner = device,
        .vtable = undefined,
        .bind_point = .graphics,
        .stages = stages,
        .mode = .{
            .graphics = .{
                .input_assembly = .{
                    .binding_description = blk: {
                        if (info.p_vertex_input_state) |vertex_input_state| {
                            if (vertex_input_state.p_vertex_binding_descriptions) |vertex_binding_descriptions| {
                                break :blk allocator.dupe(vk.VertexInputBindingDescription, vertex_binding_descriptions[0..vertex_input_state.vertex_binding_description_count]) catch return VkError.OutOfHostMemory;
                            }
                        } else {
                            return VkError.ValidationFailed;
                        }
                        break :blk null;
                    },
                    .attribute_description = blk: {
                        if (info.p_vertex_input_state) |vertex_input_state| {
                            if (vertex_input_state.p_vertex_attribute_descriptions) |vertex_attribute_descriptions| {
                                break :blk allocator.dupe(vk.VertexInputAttributeDescription, vertex_attribute_descriptions[0..vertex_input_state.vertex_attribute_description_count]) catch return VkError.OutOfHostMemory;
                            }
                        } else {
                            return VkError.ValidationFailed;
                        }
                        break :blk null;
                    },
                    .topology = if (info.p_input_assembly_state) |state| state.topology else return VkError.ValidationFailed,
                },
                .viewport_state = .{
                    .viewports = blk: {
                        if (info.p_viewport_state) |viewport_state| {
                            if (viewport_state.p_viewports) |viewports| {
                                break :blk allocator.dupe(vk.Viewport, viewports[0..viewport_state.viewport_count]) catch return VkError.OutOfHostMemory;
                            }
                        }
                        return VkError.ValidationFailed;
                    },
                    .scissor = blk: {
                        if (info.p_viewport_state) |viewport_state| {
                            if (viewport_state.p_scissors) |scissors| {
                                break :blk allocator.dupe(vk.Rect2D, scissors[0..viewport_state.scissor_count]) catch return VkError.OutOfHostMemory;
                            }
                        }
                        return VkError.ValidationFailed;
                    },
                },
                .rasterization = .{
                    .polygon_mode = if (info.p_rasterization_state) |state| state.polygon_mode else return VkError.ValidationFailed,
                    .cull_mode = if (info.p_rasterization_state) |state| state.cull_mode else return VkError.ValidationFailed,
                    .front_face = if (info.p_rasterization_state) |state| state.front_face else return VkError.ValidationFailed,
                    .line_width = if (info.p_rasterization_state) |state| state.line_width else return VkError.ValidationFailed,
                },
            },
        },
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    switch (self.mode) {
        .compute => {},
        .graphics => |graphics| {
            if (graphics.input_assembly.binding_description) |binding_description| {
                allocator.free(binding_description);
            }
            if (graphics.input_assembly.attribute_description) |attribute_description| {
                allocator.free(attribute_description);
            }
        },
    }
    self.vtable.destroy(self, allocator);
}
