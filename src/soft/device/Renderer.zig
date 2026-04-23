const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const lib = @import("../lib.zig");

const SoftBuffer = @import("../SoftBuffer.zig");
const SoftDescriptorSet = @import("../SoftDescriptorSet.zig");
const SoftDevice = @import("../SoftDevice.zig");
const SoftFramebuffer = @import("../SoftFramebuffer.zig");
const SoftPipeline = @import("../SoftPipeline.zig");
const SoftRenderPass = @import("../SoftRenderPass.zig");

const VkError = base.VkError;

const Self = @This();

const VertexInputBindingState = struct {
    input_rate: vk.VertexInputRate,
    stride: usize,
};

const VertexInputAttributeState = struct {
    format: vk.Format,
    offset: usize,
    binding: usize,
};

pub const VertexBuffer = struct {
    buffer: *const SoftBuffer,
    offset: usize,
    size: usize,
};

pub const DynamicState = struct {
    viewport: vk.Viewport,
    scissor: vk.Rect2D,

    line_width: f32,
    cull_mode: vk.CullModeFlags,
    front_face: vk.FrontFace,
    primitive_topology: vk.PrimitiveTopology,

    vertex_input_bindings: [lib.MAX_VERTEX_INPUT_BINDINGS]VertexInputBindingState,
    vertex_input_attributes: [lib.MAX_VERTEX_INPUT_ATTRIBUTES]VertexInputAttributeState,

    vertex_buffers: [lib.MAX_VERTEX_INPUT_BINDINGS]VertexBuffer,
};

render_pass: ?*SoftRenderPass,
framebuffer: ?*SoftFramebuffer,
dynamic_state: DynamicState,

pub fn init() Self {
    return .{
        .render_pass = null,
        .framebuffer = null,
        .dynamic_state = undefined,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}
