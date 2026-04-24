const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = @import("zmath");
const lib = @import("../lib.zig");

const F32x4 = zm.F32x4;

const PipelineState = @import("Device.zig").PipelineState;

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
};

const Vertex = struct {
    position: F32x4,
    point_size: f32,
    index: usize,
};

device: *SoftDevice,
state: *PipelineState,

render_pass: ?*SoftRenderPass,
framebuffer: ?*SoftFramebuffer,
dynamic_state: DynamicState,

pub fn init(device: *SoftDevice, state: *PipelineState) Self {
    return .{
        .device = device,
        .state = state,
        .render_pass = null,
        .framebuffer = null,
        .dynamic_state = undefined,
    };
}

pub fn drawPrimitive(self: *Self, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize) void {
    const allocator = self.device.device_allocator.allocator();

    const vertices = self.fetchVertexInput(allocator, vertex_count, instance_count, first_vertex, first_instance);
    _ = vertices;
}

pub fn deinit(self: *Self) void {
    _ = self;
}

fn fetchVertexInput(self: *const Self, allocator: std.mem.Allocator, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize) []Vertex {
    _ = self;
    _ = allocator;
    _ = vertex_count;
    _ = instance_count;
    _ = first_vertex;
    _ = first_instance;
    return undefined;
}
