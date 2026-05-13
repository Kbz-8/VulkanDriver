const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;
const spv = @import("spv");

const PipelineState = @import("Device.zig").PipelineState;
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

pub const DynamicState = struct {
    viewports: ?[]const vk.Viewport,
    scissor: ?[]const vk.Rect2D,
    line_width: ?f32,
};

pub const Vertex = struct {
    position: F32x4,
    outputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]?struct {
        interpolation_type: enum { smooth, flat, noperspective },
        blob: []u8,
    },
};

pub const DrawCall = struct {
    renderer: *Self,
    vertices: []Vertex,

    viewport: vk.Viewport,
    scissor: vk.Rect2D,

    color_attachments: []*base.ImageView,
    depth_attachment: ?*base.ImageView,

    render_pass: *SoftRenderPass,
    framebuffer: *SoftFramebuffer,

    fn init(allocator: std.mem.Allocator, vertex_count: usize, instance_count: usize, renderer: *Self) VkError!@This() {
        const framebuffer = renderer.framebuffer orelse return VkError.InvalidHandleDrv;
        const render_pass = renderer.render_pass orelse return VkError.InvalidHandleDrv;

        const self: @This() = .{
            .vertices = allocator.alloc(Vertex, vertex_count * instance_count) catch return VkError.OutOfDeviceMemory,
            .renderer = renderer,
            .viewport = undefined,
            .scissor = undefined,
            .color_attachments = framebuffer.interface.attachments[0..],
            .depth_attachment = if (render_pass.interface.subpasses[0].depth_stencil_attachments) |desc| framebuffer.interface.attachments[desc.attachment] else null,
            .render_pass = render_pass,
            .framebuffer = framebuffer,
        };

        for (self.vertices) |*vertex| {
            @memset(vertex.outputs[0..], null);
        }

        return self;
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.vertices) |*vertex| {
            for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
                if (vertex.outputs[location]) |output| {
                    allocator.free(output.blob);
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
dynamic_state: DynamicState,

pub fn init(device: *SoftDevice, state: *PipelineState) Self {
    return .{
        .device = device,
        .state = state,
        .render_pass = null,
        .framebuffer = null,
        .dynamic_state = .{
            .viewports = null,
            .scissor = null,
            .line_width = null,
        },
    };
}

pub fn draw(self: *Self, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize) VkError!void {
    var bounded_allocator: BoundedAllocator = .init(self.device.device_allocator.allocator(), @"1GiB");
    try self.drawCall(&bounded_allocator, vertex_count, instance_count, first_vertex, first_instance, null);
}

pub fn drawIndexed(self: *Self, index_count: usize, instance_count: usize, first_index: usize, first_instance: usize, vertex_offset: i32) VkError!void {
    var bounded_allocator: BoundedAllocator = .init(self.device.device_allocator.allocator(), @"1GiB");
    const allocator = bounded_allocator.allocator();

    const indices = try self.readIndexBuffer(allocator, index_count, first_index, vertex_offset);

    try self.drawCall(&bounded_allocator, index_count, instance_count, 0, first_instance, indices);
}

fn drawCall(self: *Self, bounded_allocator: *BoundedAllocator, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize, indices: ?[]const i32) VkError!void {
    const io = self.device.interface.io();
    const allocator = bounded_allocator.allocator();

    var draw_call = try DrawCall.init(allocator, vertex_count, instance_count, self);
    defer draw_call.deinit(allocator);

    const timer = std.Io.Timestamp.now(io, .real);
    defer if (comptime base.config.logs != .none) {
        const duration = timer.untilNow(io, .real);
        const ms: f32 = @floatFromInt(duration.toMicroseconds());
        const memory_footprint = @divTrunc(bounded_allocator.queryFootprint(), 1000);
        const logger = std.log.scoped(.SoftwareRenderer);
        if (memory_footprint > 256_000)
            logger.warn("Drawcall stats:\n>   Took {d:.3}ms\n>   Allocated {d} KB", .{ ms / 1000, memory_footprint })
        else
            logger.debug("Drawcall stats:\n>   Took {d:.3}ms\n>   Allocated {d} KB", .{ ms / 1000, memory_footprint });
    };

    self.vertexShaderStage(allocator, &draw_call, vertex_count, instance_count, first_vertex, first_instance, indices) catch |err| {
        std.log.scoped(.@"Vertex stage").err("catched a '{s}'", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(trace);
        }
        return VkError.Unknown;
    };

    draw_call.viewport = try self.resolveViewport(0);
    draw_call.scissor = try self.resolveScissor(0);

    try rasterizer.processThenFragmentStage(self, allocator, &draw_call);
}

fn vertexShaderStage(self: *Self, allocator: std.mem.Allocator, draw_call: *DrawCall, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize, indices: ?[]const i32) !void {
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
                .instance_index = instance_index,
                .draw_call = draw_call,
            };

            wg.async(self.device.interface.io(), vertex_dispatcher.runWrapper, .{run_data});
        }
    }
    wg.await(self.device.interface.io()) catch return VkError.DeviceLost;
}

fn readIndexBuffer(self: *Self, allocator: std.mem.Allocator, index_count: usize, first_index: usize, vertex_offset: i32) VkError![]i32 {
    const index_buffer = self.state.data.graphics.index_buffer;
    const buffer = index_buffer.buffer;
    const buffer_memory = if (buffer.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
    const index_size = indexTypeSize(index_buffer.index_type) orelse {
        base.unsupported("index type {any}", .{index_buffer.index_type});
        return VkError.Unknown;
    };

    const byte_offset = buffer.interface.offset + index_buffer.offset + (first_index * index_size);
    const byte_size = index_count * index_size;
    const index_memory: []const u8 = @as([*]const u8, @ptrCast(@alignCast(try buffer_memory.map(byte_offset, byte_size))))[0..byte_size];

    const indices = allocator.alloc(i32, index_count) catch return VkError.OutOfDeviceMemory;
    for (indices, 0..) |*index, i| {
        const offset = i * index_size;
        const raw_index: u32 = switch (index_size) {
            1 => index_memory[offset],
            2 => std.mem.readInt(u16, index_memory[offset..][0..2], .little),
            4 => @intCast(std.mem.readInt(u32, index_memory[offset..][0..4], .little)),
            else => unreachable,
        };
        index.* = vertex_offset + @as(i32, @intCast(raw_index));
    }

    return indices;
}

fn indexTypeSize(index_type: vk.IndexType) ?usize {
    return switch (index_type) {
        .uint8 => 1,
        .uint16 => 2,
        .uint32 => 4,
        else => null,
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
