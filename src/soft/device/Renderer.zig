const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;
const lib = @import("../lib.zig");
const spv = @import("spv");

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

pub const IndexBuffer = struct {
    buffer: *const SoftBuffer,
    offset: usize,
    index_type: vk.IndexType,
};

pub const DynamicState = struct {
    viewports: ?[]const vk.Viewport,
    scissor: ?[]vk.Rect2D,
    line_width: ?f32,
};

pub const Vertex = struct {
    position: F32x4,
    outputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS]?struct {
        interpolation_type: enum { smooth, flat, noperspective },
        blob: []u8,
    },
};

pub const Fragment = struct {
    position: F32x4,
    color: F32x4,
    inputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS][]u8,
};

pub const DrawCall = struct {
    vertices: []Vertex,
    fragments: []Fragment,

    pub fn init(allocator: std.mem.Allocator, vertex_count: usize, instance_count: usize) VkError!@This() {
        const self: @This() = .{
            .vertices = allocator.alloc(Vertex, vertex_count * instance_count) catch return VkError.OutOfDeviceMemory,
            .fragments = undefined,
        };

        for (self.vertices) |*vertex| {
            @memset(vertex.outputs[0..], null);
        }

        return self;
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
    const io = self.device.interface.io();

    var arena: std.heap.ArenaAllocator = .init(self.device.device_allocator.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var draw_call = try DrawCall.init(allocator, vertex_count, instance_count);

    const timer = std.Io.Timestamp.now(io, .real);
    defer if (comptime base.config.logs != .none) {
        const duration = timer.untilNow(io, .real);
        const ms = duration.toMicroseconds();
        std.log.scoped(.SoftwareRenderer).debug("Drawcall stats:\n>   Took {d}us\n>   Allocated {d} KB", .{ ms, @divTrunc(arena.queryCapacity(), 1000) });
    };

    self.vertexShaderStage(allocator, &draw_call, vertex_count, instance_count, first_vertex, first_instance, null) catch |err| {
        std.log.scoped(.@"Vertex stage").err("catched a '{s}'", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(trace);
        }
    };

    try self.postVertexDraw(allocator, &draw_call);
}

pub fn drawIndexed(self: *Self, index_count: usize, instance_count: usize, first_index: usize, first_instance: usize, vertex_offset: i32) VkError!void {
    const io = self.device.interface.io();

    var arena: std.heap.ArenaAllocator = .init(self.device.device_allocator.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var draw_call = try DrawCall.init(allocator, index_count, instance_count);
    const indices = try self.readIndexBuffer(allocator, index_count, first_index, vertex_offset);

    const timer = std.Io.Timestamp.now(io, .real);
    defer if (comptime base.config.logs != .none) {
        const duration = timer.untilNow(io, .real);
        const ms = duration.toMicroseconds();
        std.log.scoped(.SoftwareRenderer).debug("Drawcall indexed stats:\n>   Took {d}us\n>   Allocated {d} KB", .{ ms, @divTrunc(arena.queryCapacity(), 1000) });
    };

    self.vertexShaderStage(allocator, &draw_call, index_count, instance_count, 0, first_instance, indices) catch |err| {
        std.log.scoped(.@"Vertex stage").err("catched a '{s}'", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(trace);
        }
    };

    try self.postVertexDraw(allocator, &draw_call);
}

pub fn deinit(self: *Self) void {
    _ = self;
}

fn vertexShaderStage(self: *Self, allocator: std.mem.Allocator, draw_call: *DrawCall, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize, indices: ?[]const i32) !void {
    const pipeline = self.state.pipeline orelse return;
    const batch_size = (pipeline.stages.getPtr(.vertex) orelse return).runtimes.len;

    var wg: std.Io.Group = .init;
    for (0..instance_count) |instance_index| {
        for (0..@min(batch_size, vertex_count)) |batch_id| {
            const run_data: vertex_dispatcher.RunData = .{
                .allocator = allocator,
                .renderer = self,
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

fn postVertexDraw(self: *Self, allocator: std.mem.Allocator, draw_call: *DrawCall) VkError!void {
    const render_target_view: *base.ImageView = (self.framebuffer orelse return).interface.attachments[0];
    const render_target: *SoftImage = @alignCast(@fieldParentPtr("interface", render_target_view.image));

    try self.primitiveAssemblyStage(draw_call);
    try self.rasterizationStage(allocator, draw_call);

    self.fragmentShaderStage(draw_call) catch |err| {
        std.log.scoped(.@"Fragment stage").err("catched a '{s}'", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(trace);
        }
    };

    for (draw_call.fragments) |fragment| {
        try render_target.writeFloat4(
            .{
                .x = @intFromFloat(fragment.position[0]),
                .y = @intFromFloat(fragment.position[1]),
                .z = 0, // FIXME
            },
            .{
                .aspect_mask = render_target_view.subresource_range.aspect_mask,
                .mip_level = render_target_view.subresource_range.base_mip_level,
                .array_layer = render_target_view.subresource_range.base_array_layer,
            },
            render_target_view.format,
            fragment.color,
        );
    }
}

fn primitiveAssemblyStage(self: *Self, draw_call: *DrawCall) VkError!void {
    const viewport = blk: {
        const pipeline_data = &(self.state.pipeline orelse return VkError.InvalidPipelineDrv).interface.mode.graphics;
        if (pipeline_data.dynamic_state.viewport) {
            if (self.dynamic_state.viewports) |viewports|
                break :blk viewports[0];
        }
        if (pipeline_data.viewport_state.viewports) |viewports|
            break :blk viewports[0];
        return VkError.Unknown;
    };

    for (draw_call.vertices) |*vertex| {
        const x = vertex.position[0];
        const y = vertex.position[1];
        const z = vertex.position[2];
        const w = vertex.position[3];

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

        vertex.position = zm.f32x4(x_screen, y_screen, z_screen, 1.0);
    }
}

fn rasterizationStage(self: *Self, allocator: std.mem.Allocator, draw_call: *DrawCall) VkError!void {
    var fragments: std.ArrayList(Fragment) = .empty;

    const pipeline_data = (self.state.pipeline orelse return VkError.InvalidHandleDrv).interface.mode.graphics;
    const topology = pipeline_data.input_assembly.topology;
    switch (topology) {
        .triangle_list => for (0..@divTrunc(draw_call.vertices.len, 3)) |triangle_index| {
            const first_vertex = triangle_index * 3;
            const v0 = &draw_call.vertices[first_vertex + 0];
            const v1 = &draw_call.vertices[first_vertex + 1];
            const v2 = &draw_call.vertices[first_vertex + 2];

            try self.rasterizeTriangle(allocator, &fragments, v0, v1, v2, v0, v1, v2);
        },
        .triangle_fan => if (draw_call.vertices.len >= 3) {
            const v0 = &draw_call.vertices[0];
            for (1..(draw_call.vertices.len - 1)) |vertex_index| {
                const v1 = &draw_call.vertices[vertex_index];
                const v2 = &draw_call.vertices[vertex_index + 1];

                try self.rasterizeTriangle(allocator, &fragments, v0, v1, v2, v0, v1, v2);
            }
        },
        .triangle_strip => if (draw_call.vertices.len >= 3) {
            for (0..(draw_call.vertices.len - 2)) |vertex_index| {
                const v0 = &draw_call.vertices[vertex_index + 0];
                const v1 = &draw_call.vertices[vertex_index + 1];
                const v2 = &draw_call.vertices[vertex_index + 2];

                if ((vertex_index & 1) == 0) {
                    try self.rasterizeTriangle(allocator, &fragments, v0, v1, v2, v0, v1, v2);
                } else {
                    try self.rasterizeTriangle(allocator, &fragments, v0, v1, v2, v1, v0, v2);
                }
            }
        },
        else => base.unsupported("primitive topology {any}", .{topology}),
    }

    draw_call.fragments = fragments.toOwnedSlice(allocator) catch return VkError.OutOfDeviceMemory;
}

fn rasterizeTriangle(
    self: *Self,
    allocator: std.mem.Allocator,
    fragments: *std.ArrayList(Fragment),
    v0: *Vertex,
    v1: *Vertex,
    v2: *Vertex,
    cull_v0: *const Vertex,
    cull_v1: *const Vertex,
    cull_v2: *const Vertex,
) VkError!void {
    if (try self.triangleIsCulled(cull_v0, cull_v1, cull_v2))
        return;

    const pipeline_data = (self.state.pipeline orelse return VkError.InvalidHandleDrv).interface.mode.graphics;
    switch (pipeline_data.rasterization.polygon_mode) {
        .fill => try rasterizer.drawTriangleFilled(allocator, fragments, v0, v1, v2),
        .line => {
            try rasterizer.drawLineBresenham(allocator, fragments, v0, v1);
            try rasterizer.drawLineBresenham(allocator, fragments, v1, v2);
            try rasterizer.drawLineBresenham(allocator, fragments, v2, v0);
        },
        .point => {},
        else => base.unsupported("polygon mode {any}", .{pipeline_data.rasterization.polygon_mode}),
    }
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

fn triangleArea2(v0: *const Vertex, v1: *const Vertex, v2: *const Vertex) f32 {
    const x0 = v0.position[0];
    const y0 = v0.position[1];
    const x1 = v1.position[0];
    const y1 = v1.position[1];
    const x2 = v2.position[0];
    const y2 = v2.position[1];

    return ((x1 - x0) * (y2 - y0)) - ((y1 - y0) * (x2 - x0));
}

fn triangleIsCulled(self: *Self, v0: *const Vertex, v1: *const Vertex, v2: *const Vertex) VkError!bool {
    const pipeline_data = (self.state.pipeline orelse return VkError.InvalidHandleDrv).interface.mode.graphics;
    const rasterization = pipeline_data.rasterization;
    const cull_mode = rasterization.cull_mode;

    if (!cull_mode.front_bit and !cull_mode.back_bit)
        return false;

    if (cull_mode.front_bit and cull_mode.back_bit)
        return true;

    const area = triangleArea2(v0, v1, v2);
    if (area == 0.0)
        return true;

    const front_face = switch (rasterization.front_face) {
        .counter_clockwise => area < 0.0,
        .clockwise => area > 0.0,
        else => return false,
    };

    return (cull_mode.front_bit and front_face) or (cull_mode.back_bit and !front_face);
}
