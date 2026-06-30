const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;
const spv = @import("spv");

const ExecutionDevice = @import("Device.zig");
const PipelineState = ExecutionDevice.PipelineState;
const BoundedAllocator = @import("BoundedAllocator.zig");

const SoftBuffer = @import("../SoftBuffer.zig");
const SoftDescriptorSet = @import("../SoftDescriptorSet.zig");
const SoftDevice = @import("../SoftDevice.zig");
const SoftFramebuffer = @import("../SoftFramebuffer.zig");
const SoftPipeline = @import("../SoftPipeline.zig");
const SoftRenderPass = @import("../SoftRenderPass.zig");

const blitter = @import("blitter.zig");
const rasterizer = @import("rasterizer.zig");
const vertex_dispatcher = @import("vertex_dispatcher.zig");
const clip = @import("clip.zig");

const VkError = base.VkError;
const F32x4 = zm.F32x4;

const Self = @This();

const @"1GiB" = 1_073_741_824;

pub const VertexBuffer = struct {
    buffer: *const SoftBuffer,
    offset: usize,
    size: usize,
};

pub const IndexBuffer = struct {
    buffer: *const SoftBuffer,
    offset: usize,
    index_type: vk.IndexType,
};

pub const InterpolationType = enum { smooth, flat, noperspective };

pub const DynamicState = struct {
    viewports: ?[]const vk.Viewport,
    scissor: ?[]const vk.Rect2D,
    line_width: ?f32,
    depth_bias: ?DepthBias,
    depth_bounds: ?DepthBounds,
    blend_constants: ?[4]f32,
    stencil_front_compare_mask: ?u32,
    stencil_back_compare_mask: ?u32,
    stencil_front_write_mask: ?u32,
    stencil_back_write_mask: ?u32,
    stencil_front_reference: ?u32,
    stencil_back_reference: ?u32,
};

pub const DepthBias = struct {
    constant_factor: f32,
    clamp: f32,
    slope_factor: f32,
};

pub const DepthBounds = struct {
    min: f32,
    max: f32,
};

pub const Vertex = struct {
    primitive_restart: bool,
    position: F32x4,
    point_size: f32,
    outputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS][4]?struct {
        interpolation_type: InterpolationType,
        blob: []u8,
        size: usize,
    },
};

pub const DrawCall = struct {
    renderer: *Self,
    vertices: []Vertex,
    vertex_count: usize,
    instance_count: usize,

    viewport: vk.Viewport,
    scissor: vk.Rect2D,

    color_attachments: []*base.ImageView,
    depth_attachment: ?*base.ImageView,
    input_attachment_snapshots: []const SoftPipeline.InputAttachmentSnapshot,

    render_pass: *SoftRenderPass,
    framebuffer: *SoftFramebuffer,

    rasterizer_wait_group: std.Io.Group,

    stats: struct {
        polygons_drawn: usize,
    },

    fn init(allocator: std.mem.Allocator, vertex_count: usize, instance_count: usize, renderer: *Self) VkError!@This() {
        const framebuffer = renderer.framebuffer orelse return VkError.InvalidHandleDrv;
        const render_pass = renderer.render_pass orelse return VkError.InvalidHandleDrv;

        const self: @This() = .{
            .vertices = allocator.alloc(Vertex, vertex_count * instance_count) catch return VkError.OutOfDeviceMemory,
            .vertex_count = vertex_count,
            .instance_count = instance_count,
            .renderer = renderer,
            .viewport = undefined,
            .scissor = undefined,
            .color_attachments = framebuffer.interface.attachments[0..],
            .depth_attachment = if (render_pass.interface.subpasses[renderer.subpass_index].depth_stencil_attachments) |desc| framebuffer.interface.attachments[desc.attachment] else null,
            .input_attachment_snapshots = &.{},
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .rasterizer_wait_group = .init,
            .stats = .{
                .polygons_drawn = 0,
            },
        };

        for (self.vertices) |*vertex| {
            vertex.primitive_restart = false;
            vertex.point_size = 1.0;
            for (&vertex.outputs) |*location| {
                @memset(location, null);
            }
        }

        return self;
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.vertices) |*vertex| {
            for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
                for (0..4) |component| {
                    if (vertex.outputs[location][component]) |output| {
                        allocator.free(output.blob);
                    }
                }
            }
        }
        allocator.free(self.vertices);
    }
};

device: *SoftDevice,
state: *PipelineState,

render_pass: ?*SoftRenderPass,
framebuffer: ?*SoftFramebuffer,
render_area: ?vk.Rect2D,
dynamic_state: DynamicState,
input_attachment_snapshots: []const SoftPipeline.InputAttachmentSnapshot,

subpass_index: usize,
active_occlusion_queries: *std.ArrayList(ExecutionDevice.ActiveOcclusionQuery),

pub fn init(device: *SoftDevice, state: *PipelineState, active_occlusion_queries: *std.ArrayList(ExecutionDevice.ActiveOcclusionQuery)) Self {
    return .{
        .device = device,
        .state = state,
        .render_pass = null,
        .framebuffer = null,
        .render_area = null,
        .input_attachment_snapshots = &.{},
        .dynamic_state = .{
            .viewports = null,
            .scissor = null,
            .line_width = null,
            .depth_bias = null,
            .depth_bounds = null,
            .blend_constants = null,
            .stencil_front_compare_mask = null,
            .stencil_back_compare_mask = null,
            .stencil_front_write_mask = null,
            .stencil_back_write_mask = null,
            .stencil_front_reference = null,
            .stencil_back_reference = null,
        },
        .subpass_index = 0,
        .active_occlusion_queries = active_occlusion_queries,
    };
}

pub fn resetInputAttachmentSnapshots(self: *Self) void {
    const allocator = self.device.device_allocator.allocator();
    for (self.input_attachment_snapshots) |snapshot| {
        allocator.free(snapshot.data);
    }
    allocator.free(self.input_attachment_snapshots);
    self.input_attachment_snapshots = &.{};
}

pub fn draw(self: *Self, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize) VkError!void {
    var bounded_allocator: BoundedAllocator = .init(self.device.device_allocator.allocator(), 4 * @"1GiB");
    try self.drawCall(&bounded_allocator, vertex_count, instance_count, first_vertex, first_instance, null, null);
}

pub fn drawIndexed(self: *Self, index_count: usize, instance_count: usize, first_index: usize, first_instance: usize, vertex_offset: i32) VkError!void {
    var bounded_allocator: BoundedAllocator = .init(self.device.device_allocator.allocator(), 4 * @"1GiB");
    const allocator = bounded_allocator.allocator();

    const indexed_draw = try self.readIndexBuffer(allocator, index_count, first_index, vertex_offset);

    try self.drawCall(&bounded_allocator, index_count, instance_count, 0, first_instance, indexed_draw.indices, indexed_draw.primitive_restart);
}

fn drawCall(self: *Self, bounded_allocator: *BoundedAllocator, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize, indices: ?[]const u32, primitive_restart: ?[]const bool) VkError!void {
    const io = self.device.interface.io();
    const allocator = bounded_allocator.allocator();

    var draw_call = try DrawCall.init(allocator, vertex_count, instance_count, self);
    defer draw_call.deinit(allocator);

    const timer = std.Io.Timestamp.now(io, .real);
    defer if (comptime base.config.logs != .none) {
        const duration = timer.untilNow(io, .real);
        const ms: f32 = @floatFromInt(duration.toMicroseconds());
        const memory_footprint = @divTrunc(bounded_allocator.queryFootprint(), 1000);
        const peak_memory_footprint = @divTrunc(bounded_allocator.queryPeakFootprint(), 1000);

        const fmt =
            \\Drawcall stats:
            \\>   Took {d:.3}ms
            \\>   Total allocation of {d} KB
            \\>   Peak concurrent allocation of {d} KB
            \\>   Total polygons drawn {d}
        ;
        const args = .{
            ms / 1000,
            memory_footprint,
            peak_memory_footprint,
            draw_call.stats.polygons_drawn,
        };

        const logger = std.log.scoped(.SoftwareRenderer);
        if (memory_footprint > 256_000)
            logger.warn(fmt, args)
        else
            logger.debug(fmt, args);
    };

    const pipeline = self.state.pipeline orelse return VkError.InvalidPipelineDrv;
    const vertex_shader = pipeline.stages.getPtrAssertContains(.vertex);
    for (vertex_shader.runtimes[0..]) |*runtime| {
        ExecutionDevice.writeDescriptorSets(self.state, &runtime.rt) catch return VkError.Unknown;
    }
    if (pipeline.stages.getPtr(.fragment)) |fragment_shader| {
        for (fragment_shader.runtimes[0..]) |*runtime| {
            ExecutionDevice.writeDescriptorSets(self.state, &runtime.rt) catch return VkError.Unknown;
        }
    }

    self.vertexShaderStage(allocator, &draw_call, vertex_count, instance_count, first_vertex, first_instance, indices, primitive_restart) catch |err| {
        std.log.scoped(.@"Vertex stage").err("catched a '{s}'", .{@errorName(err)});
        if (comptime base.config.logs == .verbose) {
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
        }

        return VkError.Unknown;
    };

    draw_call.viewport = try self.resolveViewport(0);
    draw_call.scissor = try self.resolveScissor(0);

    try rasterizer.processThenFragmentStage(self, allocator, &draw_call);
}

fn vertexShaderStage(self: *Self, allocator: std.mem.Allocator, draw_call: *DrawCall, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize, indices: ?[]const u32, primitive_restart: ?[]const bool) !void {
    const pipeline = self.state.pipeline orelse return;
    const batch_size = (pipeline.stages.getPtr(.vertex) orelse return).runtimes.len;

    var wg: std.Io.Group = .init;
    for (0..instance_count) |instance_index| {
        for (0..@min(batch_size, vertex_count)) |batch_id| {
            const run_data: vertex_dispatcher.RunData = .{
                .allocator = allocator,
                .pipeline = pipeline,
                .batch_id = batch_id,
                .batch_size = batch_size,
                .vertex_count = vertex_count,
                .first_vertex = first_vertex,
                .first_instance = first_instance,
                .indices = indices,
                .primitive_restart = primitive_restart,
                .instance_index = instance_index,
                .draw_call = draw_call,
            };

            wg.async(self.device.interface.io(), vertex_dispatcher.runWrapper, .{run_data});
        }
    }
    wg.await(self.device.interface.io()) catch return VkError.DeviceLost;
}

const IndexedDrawData = struct {
    indices: []u32,
    primitive_restart: ?[]bool,
};

fn readIndexBuffer(self: *Self, allocator: std.mem.Allocator, index_count: usize, first_index: usize, vertex_offset: i32) VkError!IndexedDrawData {
    const index_buffer = self.state.data.graphics.index_buffer;
    const buffer = index_buffer.buffer;
    const buffer_memory = if (buffer.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    const index_size = indexTypeSize(index_buffer.index_type) orelse {
        base.unsupported("index type {any}", .{index_buffer.index_type});
        return VkError.Unknown;
    };

    const byte_offset = buffer.interface.offset + index_buffer.offset + (first_index * index_size);
    const byte_size = index_count * index_size;
    const index_memory: []const u8 = try buffer_memory.map(byte_offset, byte_size);

    const indices = allocator.alloc(u32, index_count) catch return VkError.OutOfDeviceMemory;
    const restart_enabled = (self.state.pipeline orelse return VkError.InvalidPipelineDrv).interface.mode.graphics.input_assembly.primitive_restart_enable == .true;
    const restart_index = primitiveRestartIndex(index_buffer.index_type);
    const primitive_restart = if (restart_enabled) allocator.alloc(bool, index_count) catch return VkError.OutOfDeviceMemory else null;

    for (indices, 0..) |*index, i| {
        const offset = i * index_size;
        const raw_index: u32 = switch (index_size) {
            1 => index_memory[offset],
            2 => std.mem.readInt(u16, index_memory[offset..][0..2], .little),
            4 => @intCast(std.mem.readInt(u32, index_memory[offset..][0..4], .little)),
            else => unreachable,
        };
        if (primitive_restart) |restart| {
            restart[i] = raw_index == restart_index;
            if (restart[i]) {
                index.* = 0;
                continue;
            }
        }
        const shifted = @as(i64, raw_index) + @as(i64, vertex_offset);
        index.* = @as(u32, @truncate(@as(u64, @bitCast(shifted))));
    }

    return .{
        .indices = indices,
        .primitive_restart = primitive_restart,
    };
}

fn indexTypeSize(index_type: vk.IndexType) ?usize {
    return switch (index_type) {
        .uint8 => 1,
        .uint16 => 2,
        .uint32 => 4,
        else => null,
    };
}

fn primitiveRestartIndex(index_type: vk.IndexType) u32 {
    return switch (index_type) {
        .uint8 => std.math.maxInt(u8),
        .uint16 => std.math.maxInt(u16),
        .uint32 => std.math.maxInt(u32),
        else => unreachable,
    };
}

fn resolveViewport(self: *Self, viewport_index: usize) VkError!vk.Viewport {
    const pipeline_data =
        &(self.state.pipeline orelse return VkError.InvalidPipelineDrv).interface.mode.graphics;

    if (pipeline_data.dynamic_state.viewport) {
        if (self.dynamic_state.viewports) |viewports| {
            if (viewport_index < viewports.len)
                return viewports[viewport_index];
        }

        return VkError.Unknown;
    }

    if (pipeline_data.viewport_state.viewports) |viewports| {
        if (viewport_index < viewports.len)
            return viewports[viewport_index];
    }

    return VkError.Unknown;
}

fn resolveScissor(self: *Self, scissor_index: usize) VkError!vk.Rect2D {
    const pipeline_data =
        &(self.state.pipeline orelse return VkError.InvalidPipelineDrv).interface.mode.graphics;

    if (pipeline_data.dynamic_state.scissor) {
        if (self.dynamic_state.scissor) |scissor| {
            if (scissor_index < scissor.len)
                return scissor[scissor_index];
        }

        return VkError.Unknown;
    }

    if (pipeline_data.viewport_state.scissor) |scissor| {
        if (scissor_index < scissor.len)
            return scissor[scissor_index];
    }

    return VkError.Unknown;
}
