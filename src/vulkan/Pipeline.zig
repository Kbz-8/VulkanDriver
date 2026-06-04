const std = @import("std");
const vk = @import("vulkan");

const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");
const PipelineCache = @import("PipelineCache.zig");
const PipelineLayout = @import("PipelineLayout.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .pipeline;

const DynamicState = struct {
    viewport: bool = false,
    scissor: bool = false,
    line_width: bool = false,
    depth_bias: bool = false,
    blend_constants: bool = false,
    depth_bounds: bool = false,
    stencil_compare_mask: bool = false,
    stencil_write_mask: bool = false,
    stencil_reference: bool = false,
};

owner: *Device,

vtable: *const VTable,
bind_point: vk.PipelineBindPoint,
stages: vk.ShaderStageFlags,
layout: *PipelineLayout,
mode: union(enum) {
    compute: struct {},
    graphics: struct {
        input_assembly: struct {
            binding_description: ?[]vk.VertexInputBindingDescription,
            attribute_description: ?[]vk.VertexInputAttributeDescription,
            topology: vk.PrimitiveTopology,
        },
        viewport_state: struct {
            viewports: ?[]vk.Viewport,
            scissor: ?[]vk.Rect2D,
        },
        rasterization: struct {
            polygon_mode: vk.PolygonMode,
            cull_mode: vk.CullModeFlags,
            front_face: vk.FrontFace,
            line_width: f32,
        },
        color_blend: struct {
            attachments: ?[]vk.PipelineColorBlendAttachmentState,
            constants: [4]f32,
        },
        depth_stencil: ?vk.PipelineDepthStencilStateCreateInfo,
        dynamic_state: DynamicState,
    },
},

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn initCompute(device: *Device, allocator: std.mem.Allocator, cache: ?*PipelineCache, info: *const vk.ComputePipelineCreateInfo) VkError!Self {
    _ = cache;

    const layout = try NonDispatchable(PipelineLayout).fromHandleObject(info.layout);
    layout.ref();
    errdefer layout.unref(allocator);

    return .{
        .owner = device,
        .vtable = undefined,
        .bind_point = .compute,
        .stages = info.stage.stage,
        .layout = layout,
        .mode = .{ .compute = .{} },
    };
}

pub fn initGraphics(device: *Device, allocator: std.mem.Allocator, cache: ?*PipelineCache, info: *const vk.GraphicsPipelineCreateInfo) VkError!Self {
    _ = cache;

    const layout = try NonDispatchable(PipelineLayout).fromHandleObject(info.layout);
    layout.ref();
    errdefer layout.unref(allocator);

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
        .layout = layout,
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
                        break :blk null;
                    },
                    .scissor = blk: {
                        if (info.p_viewport_state) |viewport_state| {
                            if (viewport_state.p_scissors) |scissors| {
                                break :blk allocator.dupe(vk.Rect2D, scissors[0..viewport_state.scissor_count]) catch return VkError.OutOfHostMemory;
                            }
                        }
                        break :blk null;
                    },
                },
                .rasterization = .{
                    .polygon_mode = if (info.p_rasterization_state) |state| state.polygon_mode else return VkError.ValidationFailed,
                    .cull_mode = if (info.p_rasterization_state) |state| state.cull_mode else return VkError.ValidationFailed,
                    .front_face = if (info.p_rasterization_state) |state| state.front_face else return VkError.ValidationFailed,
                    .line_width = if (info.p_rasterization_state) |state| state.line_width else return VkError.ValidationFailed,
                },
                .color_blend = blk: {
                    if (info.p_color_blend_state) |state| {
                        break :blk .{
                            .attachments = if (state.p_attachments) |attachments|
                                allocator.dupe(vk.PipelineColorBlendAttachmentState, attachments[0..state.attachment_count]) catch return VkError.OutOfHostMemory
                            else
                                null,
                            .constants = state.blend_constants,
                        };
                    }

                    break :blk .{
                        .attachments = null,
                        .constants = .{ 0.0, 0.0, 0.0, 0.0 },
                    };
                },
                .depth_stencil = if (info.p_depth_stencil_state) |state| state.* else null,
                .dynamic_state = blk: {
                    var state: DynamicState = .{};

                    if (info.p_dynamic_state) |dynamic_state| {
                        if (dynamic_state.p_dynamic_states) |states| {
                            for (states[0..], 0..dynamic_state.dynamic_state_count) |info_state, _| {
                                switch (info_state) {
                                    .viewport => state.viewport = true,
                                    .scissor => state.scissor = true,
                                    .line_width => state.line_width = true,
                                    .depth_bias => state.depth_bias = true,
                                    .blend_constants => state.blend_constants = true,
                                    .depth_bounds => state.depth_bounds = true,
                                    .stencil_compare_mask => state.stencil_compare_mask = true,
                                    .stencil_write_mask => state.stencil_write_mask = true,
                                    .stencil_reference => state.stencil_reference = true,
                                    else => return VkError.Unknown,
                                }
                            }
                        }
                    }

                    break :blk state;
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
            if (graphics.color_blend.attachments) |attachments| {
                allocator.free(attachments);
            }
        },
    }
    self.layout.unref(allocator);
    self.vtable.destroy(self, allocator);
}
