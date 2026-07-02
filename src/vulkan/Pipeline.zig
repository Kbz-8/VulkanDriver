const std = @import("std");
const vk = @import("vulkan");

const NonDispatchable = @import("NonDispatchable.zig").NonDispatchable;

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");
const PipelineCache = @import("PipelineCache.zig");
const PipelineLayout = @import("PipelineLayout.zig");
const RenderPass = @import("RenderPass.zig");

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
            primitive_restart_enable: vk.Bool32,
        },
        viewport_state: struct {
            viewports: ?[]vk.Viewport,
            scissor: ?[]vk.Rect2D,
        },
        rasterization: struct {
            rasterizer_discard_enable: bool,
            polygon_mode: vk.PolygonMode,
            cull_mode: vk.CullModeFlags,
            front_face: vk.FrontFace,
            line_width: f32,
            depth_bias_enable: vk.Bool32,
            depth_bias_constant_factor: f32,
            depth_bias_clamp: f32,
            depth_bias_slope_factor: f32,
        },
        multisample: struct {
            rasterization_samples: vk.SampleCountFlags,
            sample_mask: ?[]vk.SampleMask,
            alpha_to_coverage_enable: vk.Bool32,
            alpha_to_one_enable: vk.Bool32,
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

    var binding_description: ?[]vk.VertexInputBindingDescription = null;
    errdefer if (binding_description) |value| allocator.free(value);

    var attribute_description: ?[]vk.VertexInputAttributeDescription = null;
    errdefer if (attribute_description) |value| allocator.free(value);

    var viewports: ?[]vk.Viewport = null;
    errdefer if (viewports) |value| allocator.free(value);

    var scissors: ?[]vk.Rect2D = null;
    errdefer if (scissors) |value| allocator.free(value);

    var sample_mask: ?[]vk.SampleMask = null;
    errdefer if (sample_mask) |value| allocator.free(value);

    var color_attachments: ?[]vk.PipelineColorBlendAttachmentState = null;
    errdefer if (color_attachments) |value| allocator.free(value);

    const dynamic_state = try parseDynamicState(info.p_dynamic_state);
    const rasterizer_discard_enable = if (info.p_rasterization_state) |state|
        state.rasterizer_discard_enable == .true
    else
        false;
    const has_color_attachments, const has_depth_stencil_attachment = try renderPassAttachmentState(info);

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
                                binding_description = allocator.dupe(vk.VertexInputBindingDescription, vertex_binding_descriptions[0..vertex_input_state.vertex_binding_description_count]) catch return VkError.OutOfHostMemory;
                                break :blk binding_description;
                            }
                        } else {
                            return VkError.ValidationFailed;
                        }
                        break :blk null;
                    },
                    .attribute_description = blk: {
                        if (info.p_vertex_input_state) |vertex_input_state| {
                            if (vertex_input_state.p_vertex_attribute_descriptions) |vertex_attribute_descriptions| {
                                attribute_description = allocator.dupe(vk.VertexInputAttributeDescription, vertex_attribute_descriptions[0..vertex_input_state.vertex_attribute_description_count]) catch return VkError.OutOfHostMemory;
                                break :blk attribute_description;
                            }
                        } else {
                            return VkError.ValidationFailed;
                        }
                        break :blk null;
                    },
                    .topology = if (info.p_input_assembly_state) |state| state.topology else return VkError.ValidationFailed,
                    .primitive_restart_enable = if (info.p_input_assembly_state) |state| state.primitive_restart_enable else return VkError.ValidationFailed,
                },
                .viewport_state = .{
                    .viewports = blk: {
                        if (rasterizer_discard_enable or dynamic_state.viewport) {
                            break :blk null;
                        }
                        if (info.p_viewport_state) |viewport_state| {
                            if (viewport_state.viewport_count != 0) {
                                const p_viewports = viewport_state.p_viewports orelse return VkError.ValidationFailed;
                                const copy = allocator.dupe(vk.Viewport, p_viewports[0..viewport_state.viewport_count]) catch return VkError.OutOfHostMemory;
                                viewports = copy;
                                break :blk viewports;
                            }
                        }
                        break :blk null;
                    },
                    .scissor = blk: {
                        if (rasterizer_discard_enable or dynamic_state.scissor) {
                            break :blk null;
                        }
                        if (info.p_viewport_state) |viewport_state| {
                            if (viewport_state.scissor_count != 0) {
                                const p_scissors = viewport_state.p_scissors orelse return VkError.ValidationFailed;
                                const copy = allocator.dupe(vk.Rect2D, p_scissors[0..viewport_state.scissor_count]) catch return VkError.OutOfHostMemory;
                                scissors = copy;
                                break :blk scissors;
                            }
                        }
                        break :blk null;
                    },
                },
                .rasterization = .{
                    .rasterizer_discard_enable = rasterizer_discard_enable,
                    .polygon_mode = if (info.p_rasterization_state) |state| state.polygon_mode else return VkError.ValidationFailed,
                    .cull_mode = if (info.p_rasterization_state) |state| state.cull_mode else return VkError.ValidationFailed,
                    .front_face = if (info.p_rasterization_state) |state| state.front_face else return VkError.ValidationFailed,
                    .line_width = if (info.p_rasterization_state) |state| state.line_width else return VkError.ValidationFailed,
                    .depth_bias_enable = if (info.p_rasterization_state) |state| state.depth_bias_enable else return VkError.ValidationFailed,
                    .depth_bias_constant_factor = if (info.p_rasterization_state) |state| state.depth_bias_constant_factor else return VkError.ValidationFailed,
                    .depth_bias_clamp = if (info.p_rasterization_state) |state| state.depth_bias_clamp else return VkError.ValidationFailed,
                    .depth_bias_slope_factor = if (info.p_rasterization_state) |state| state.depth_bias_slope_factor else return VkError.ValidationFailed,
                },
                .multisample = blk: {
                    if (rasterizer_discard_enable) {
                        break :blk .{
                            .rasterization_samples = .{ .@"1_bit" = true },
                            .sample_mask = null,
                            .alpha_to_coverage_enable = .false,
                            .alpha_to_one_enable = .false,
                        };
                    }

                    const state = info.p_multisample_state orelse return VkError.ValidationFailed;
                    const mask_word_count: usize = @divTrunc(state.rasterization_samples.toInt() + 31, 32);
                    break :blk .{
                        .rasterization_samples = state.rasterization_samples,
                        .sample_mask = if (state.p_sample_mask) |mask| blk_mask: {
                            sample_mask = allocator.dupe(vk.SampleMask, mask[0..mask_word_count]) catch return VkError.OutOfHostMemory;
                            break :blk_mask sample_mask;
                        } else null,
                        .alpha_to_coverage_enable = state.alpha_to_coverage_enable,
                        .alpha_to_one_enable = state.alpha_to_one_enable,
                    };
                },
                .color_blend = blk: {
                    if (rasterizer_discard_enable or !has_color_attachments) {
                        break :blk .{
                            .attachments = null,
                            .constants = .{ 0.0, 0.0, 0.0, 0.0 },
                        };
                    }

                    if (info.p_color_blend_state) |state| {
                        break :blk .{
                            .attachments = if (state.attachment_count != 0) blk_attachments: {
                                const attachments = state.p_attachments orelse return VkError.ValidationFailed;
                                color_attachments = allocator.dupe(vk.PipelineColorBlendAttachmentState, attachments[0..state.attachment_count]) catch return VkError.OutOfHostMemory;
                                break :blk_attachments color_attachments;
                            } else null,
                            .constants = state.blend_constants,
                        };
                    }

                    break :blk .{
                        .attachments = null,
                        .constants = .{ 0.0, 0.0, 0.0, 0.0 },
                    };
                },
                .depth_stencil = if (rasterizer_discard_enable or !has_depth_stencil_attachment)
                    null
                else if (info.p_depth_stencil_state) |state|
                    state.*
                else
                    null,
                .dynamic_state = dynamic_state,
            },
        },
    };
}

fn parseDynamicState(info: ?*const vk.PipelineDynamicStateCreateInfo) VkError!DynamicState {
    var state: DynamicState = .{};
    const dynamic_state = info orelse return state;
    if (dynamic_state.dynamic_state_count == 0) {
        return state;
    }

    const states = dynamic_state.p_dynamic_states orelse return VkError.ValidationFailed;
    for (states[0..dynamic_state.dynamic_state_count]) |info_state| {
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

    return state;
}

fn renderPassAttachmentState(info: *const vk.GraphicsPipelineCreateInfo) VkError!struct { bool, bool } {
    if (info.render_pass == .null_handle) {
        return .{ true, true };
    }

    const render_pass = try NonDispatchable(RenderPass).fromHandleObject(info.render_pass);
    return .{
        try render_pass.subpassHasColorAttachments(info.subpass),
        try render_pass.subpassHasDepthStencilAttachment(info.subpass),
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
            if (graphics.viewport_state.viewports) |viewports| {
                allocator.free(viewports);
            }
            if (graphics.viewport_state.scissor) |scissor| {
                allocator.free(scissor);
            }
            if (graphics.multisample.sample_mask) |sample_mask| {
                allocator.free(sample_mask);
            }
            if (graphics.color_blend.attachments) |attachments| {
                allocator.free(attachments);
            }
        },
    }
    self.layout.unref(allocator);
    self.vtable.destroy(self, allocator);
}
