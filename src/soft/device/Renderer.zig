const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;
const lib = @import("../lib.zig");

pub const F32x4 = zm.F32x4;

const PipelineState = @import("Device.zig").PipelineState;

const SoftBuffer = @import("../SoftBuffer.zig");
const SoftDescriptorSet = @import("../SoftDescriptorSet.zig");
const SoftDevice = @import("../SoftDevice.zig");
const SoftFramebuffer = @import("../SoftFramebuffer.zig");
const SoftImage = @import("../SoftImage.zig");
const SoftPipeline = @import("../SoftPipeline.zig");
const SoftRenderPass = @import("../SoftRenderPass.zig");

const blitter = @import("blitter.zig");
const rasterizer = @import("rasterizer.zig");
const vertex_dispatcher = @import("vertex_dispatcher.zig");
const fragment_dispatcher = @import("fragment_dispatcher.zig");

const VkError = base.VkError;

const Self = @This();

pub const VertexBuffer = struct {
    buffer: *const SoftBuffer,
    offset: usize,
    size: usize,
};

pub const DynamicState = struct {
    viewport: vk.Viewport,
    scissor: vk.Rect2D,
    line_width: f32,
};

pub const Fragment = struct {
    position: F32x4,
    color: F32x4,
};

pub const DrawCall = struct {
    vertices: []F32x4,
    fragments: []Fragment,
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

pub fn draw(self: *Self, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize) VkError!void {
    const render_target_view: *base.ImageView = (self.framebuffer orelse return).interface.attachments[0];
    const render_target: *SoftImage = @alignCast(@fieldParentPtr("interface", render_target_view.image));
    const render_target_memory = if (render_target.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;

    var arena: std.heap.ArenaAllocator = .init(self.device.device_allocator.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var draw_call: DrawCall = .{
        .vertices = allocator.alloc(F32x4, vertex_count * instance_count) catch return VkError.OutOfDeviceMemory,
        .fragments = undefined,
    };

    self.vertexShaderStage(&draw_call, vertex_count, instance_count) catch |err| {
        std.log.scoped(.@"Vertex stage").err("catched a '{s}'", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(trace);
        }
    };

    self.primitiveAssemblyStage(&draw_call);
    try self.rasterizationStage(allocator, &draw_call);
    self.fragmentShaderStage(&draw_call) catch |err| {
        std.log.scoped(.@"Fragment stage").err("catched a '{s}'", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(trace);
        }
    };

    const texel_size = base.format.texelSize(render_target_view.format);

    for (draw_call.fragments) |fragment| {
        const texel_offset = try render_target.getTexelMemoryOffset(
            .{
                .x = @intFromFloat(fragment.position[0]),
                .y = @intFromFloat(fragment.position[1]),
                .z = @intFromFloat(fragment.position[2]),
            },
            .{
                .aspect_mask = render_target_view.subresource_range.aspect_mask,
                .mip_level = render_target_view.subresource_range.base_mip_level,
                .array_layer = render_target_view.subresource_range.base_array_layer,
            },
        );
        const map: []u8 = @as([*]u8, @ptrCast(try render_target_memory.map(render_target.interface.memory_offset + texel_offset, texel_size)))[0..texel_size];
        blitter.writeFloat4(fragment.color, map, render_target_view.format);
    }

    _ = first_vertex;
    _ = first_instance;
}

pub fn deinit(self: *Self) void {
    _ = self;
}

fn vertexShaderStage(self: *Self, draw_call: *DrawCall, vertex_count: usize, instance_count: usize) !void {
    const pipeline = self.state.pipeline orelse return;
    const batch_size = (pipeline.stages.getPtr(.vertex) orelse return).runtimes.len;

    var wg: std.Io.Group = .init;
    for (0..instance_count) |instance_index| {
        for (0..@min(batch_size, vertex_count)) |batch_id| {
            const run_data: vertex_dispatcher.RunData = .{
                .renderer = self,
                .pipeline = pipeline,
                .batch_id = batch_id,
                .batch_size = batch_size,
                .vertex_count = vertex_count,
                .instance_index = instance_index,
                .draw_call = draw_call,
            };

            wg.async(self.device.interface.io(), vertex_dispatcher.runWrapper, .{run_data});
        }
    }
    wg.await(self.device.interface.io()) catch return VkError.DeviceLost;
}

fn primitiveAssemblyStage(self: *Self, draw_call: *DrawCall) void {
    const viewport = (self.state.pipeline orelse return).interface.mode.graphics.viewport_state.viewports[0];

    for (draw_call.vertices) |*vertex| {
        const x = vertex[0];
        const y = vertex[1];
        const z = vertex[2];
        const w = vertex[3];

        // Perspective division.
        const x_ndc = x / w;
        const y_ndc = y / w;
        const z_ndc = z / w;

        const p_x = viewport.width;
        const p_y = viewport.height;
        const p_z = viewport.max_depth - viewport.min_depth;

        const o_x = viewport.x + viewport.width / 2.0;
        const o_y = viewport.y + viewport.height / 2.0;
        const o_z = viewport.min_depth;

        const x_screen = ((p_x / 2.0) * x_ndc) + o_x;
        const y_screen = ((p_y / 2.0) * y_ndc) + o_y;
        const z_screen = (p_z * z_ndc) + o_z;

        vertex.* = zm.f32x4(x_screen, y_screen, z_screen, 1.0);
    }
}

fn rasterizationStage(self: *Self, allocator: std.mem.Allocator, draw_call: *DrawCall) VkError!void {
    var fragments: std.ArrayList(Fragment) = .empty;

    const pipeline_data = (self.state.pipeline orelse return VkError.InvalidHandleDrv).interface.mode.graphics;
    const topology = pipeline_data.input_assembly.topology;
    switch (topology) {
        .triangle_list => for (0..@divExact(draw_call.vertices.len, 3)) |triangle_index| {
            const first_vertex = triangle_index * 3;
            const v0 = draw_call.vertices[first_vertex + 0];
            const v1 = draw_call.vertices[first_vertex + 1];
            const v2 = draw_call.vertices[first_vertex + 2];

            switch (pipeline_data.rasterization.polygon_mode) {
                .fill => try rasterizer.drawTriangleFilled(allocator, &fragments, v0, v1, v2),
                .line => {
                    try rasterizer.drawLineBresenham(allocator, &fragments, v0, v1);
                    try rasterizer.drawLineBresenham(allocator, &fragments, v1, v2);
                    try rasterizer.drawLineBresenham(allocator, &fragments, v2, v0);
                },
                .point => {},
                else => base.unsupported("polygon mode {any}", .{pipeline_data.rasterization.polygon_mode}),
            }
        },
        else => base.unsupported("primitive topology {any}", .{topology}),
    }

    draw_call.fragments = fragments.toOwnedSlice(allocator) catch return VkError.OutOfDeviceMemory;
}

fn fragmentShaderStage(self: *Self, draw_call: *DrawCall) !void {
    const pipeline = self.state.pipeline orelse return;
    const batch_size = (pipeline.stages.getPtr(.fragment) orelse return).runtimes.len;
    const fragment_count = draw_call.fragments.len;

    var wg: std.Io.Group = .init;
    for (0..@min(batch_size, fragment_count)) |batch_id| {
        const run_data: fragment_dispatcher.RunData = .{
            .renderer = self,
            .pipeline = pipeline,
            .batch_id = batch_id,
            .batch_size = batch_size,
            .fragment_count = fragment_count,
            .draw_call = draw_call,
        };

        wg.async(self.device.interface.io(), fragment_dispatcher.runWrapper, .{run_data});
    }
    wg.await(self.device.interface.io()) catch return VkError.DeviceLost;
}
