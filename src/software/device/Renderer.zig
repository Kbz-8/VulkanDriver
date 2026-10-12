const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;
const spv = @import("spv");

const ExecutionDevice = @import("Device.zig");
const PipelineState = ExecutionDevice.PipelineState;
const BoundedAllocator = @import("BoundedAllocator.zig");

const SoftBuffer = @import("../SoftBuffer.zig");
const SoftDevice = @import("../SoftDevice.zig");
const SoftFramebuffer = @import("../SoftFramebuffer.zig");
const SoftImageView = @import("../SoftImageView.zig");
const SoftPipeline = @import("../SoftPipeline.zig");
const SoftRenderPass = @import("../SoftRenderPass.zig");
const SoftSampler = @import("../SoftSampler.zig");

const rasterizer = @import("rasterizer.zig");
const vertex_dispatcher = @import("vertex/dispatcher.zig");

const VkError = base.VkError;
const F32x4 = zm.F32x4;

const Self = @This();

const @"1GiB" = 1_073_741_824;
const draw_allocator_limit: usize = @intCast(@min(@as(u64, 4) * @"1GiB", @as(u64, std.math.maxInt(usize))));

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

pub const PackedVertexOutput = struct {
    word: u32,
    interpolation_type: InterpolationType,
    centroid: bool,
};

pub const LegacyVertexOutput = struct {
    interpolation_type: InterpolationType,
    centroid: bool,
    blob: []u8,
    size: usize,
};

const EmptyVertexOutputs = struct {};
pub const PackedVertexOutputs = if (base.config.soft_ir_interpreter)
    [spv.SPIRV_MAX_OUTPUT_LOCATIONS][4]?PackedVertexOutput
else
    EmptyVertexOutputs;
pub const LegacyVertexOutputs = if (base.config.soft_ir_interpreter)
    EmptyVertexOutputs
else
    [spv.SPIRV_MAX_OUTPUT_LOCATIONS][4]?LegacyVertexOutput;

fn emptyPackedVertexOutputs() PackedVertexOutputs {
    if (comptime base.config.soft_ir_interpreter)
        return @splat(@splat(null));
    return .{};
}

fn emptyLegacyVertexOutputs() LegacyVertexOutputs {
    if (comptime base.config.soft_ir_interpreter)
        return .{};
    return @splat(@splat(null));
}

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
    packed_outputs: PackedVertexOutputs = emptyPackedVertexOutputs(),
    outputs: LegacyVertexOutputs = emptyLegacyVertexOutputs(),
};

pub const FragmentResources = struct {
    buffers: []?[]u8 = &.{},
    images: []?*SoftImageView = &.{},
    samplers: []?*SoftSampler = &.{},
};

pub const DrawProfile = struct {
    draw_wall_ns: u64 = 0,
    vertex_wall_ns: u64 = 0,
    raster_wall_ns: u64 = 0,
    binning_wall_ns: u64 = 0,
    tile_wall_ns: u64 = 0,
    active_tiles: usize = 0,
    raster_worker_ns: std.atomic.Value(u64) = .init(0),
    raster_coverage_ns: std.atomic.Value(u64) = .init(0),
    raster_depth_ns: std.atomic.Value(u64) = .init(0),
    raster_interpolation_ns: std.atomic.Value(u64) = .init(0),
    raster_target_output_ns: std.atomic.Value(u64) = .init(0),
    vertex_input_ns: std.atomic.Value(u64) = .init(0),
    vertex_shader_ns: std.atomic.Value(u64) = .init(0),
    vertex_output_ns: std.atomic.Value(u64) = .init(0),
    fragment_input_ns: std.atomic.Value(u64) = .init(0),
    fragment_shader_ns: std.atomic.Value(u64) = .init(0),
    fragment_output_ns: std.atomic.Value(u64) = .init(0),
    vertex_invocations: std.atomic.Value(u64) = .init(0),
    fragment_invocations: std.atomic.Value(u64) = .init(0),
    vertex_instructions: std.atomic.Value(u64) = .init(0),
    vertex_fast_path_instructions: std.atomic.Value(u64) = .init(0),
    vertex_waves: std.atomic.Value(u64) = .init(0),
    vertex_full_waves: std.atomic.Value(u64) = .init(0),
    fragment_instructions: std.atomic.Value(u64) = .init(0),
    fragment_fast_path_instructions: std.atomic.Value(u64) = .init(0),
    fragment_waves: std.atomic.Value(u64) = .init(0),
    fragment_full_waves: std.atomic.Value(u64) = .init(0),

    pub fn add(counter: *std.atomic.Value(u64), value: u64) void {
        _ = counter.fetchAdd(value, .monotonic);
    }

    fn milliseconds(nanoseconds: u64) f64 {
        return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
    }

    fn percentage(numerator: u64, denominator: u64) f64 {
        if (denominator == 0)
            return 0;
        return 100.0 * @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator));
    }

    pub fn report(self: *const DrawProfile, bounded_allocator: *BoundedAllocator, polygons: usize) void {
        const vertex_input_ns = self.vertex_input_ns.load(.monotonic);
        const vertex_shader_ns = self.vertex_shader_ns.load(.monotonic);
        const vertex_output_ns = self.vertex_output_ns.load(.monotonic);
        const fragment_input_ns = self.fragment_input_ns.load(.monotonic);
        const fragment_shader_ns = self.fragment_shader_ns.load(.monotonic);
        const fragment_output_ns = self.fragment_output_ns.load(.monotonic);
        const raster_worker_ns = self.raster_worker_ns.load(.monotonic);
        const raster_coverage_ns = self.raster_coverage_ns.load(.monotonic);
        const raster_depth_ns = self.raster_depth_ns.load(.monotonic);
        const raster_interpolation_ns = self.raster_interpolation_ns.load(.monotonic);
        const raster_target_output_ns = self.raster_target_output_ns.load(.monotonic);
        const fragment_frontend_ns = fragment_input_ns + fragment_output_ns;
        const fixed_function_worker_ns = raster_worker_ns -| (fragment_frontend_ns + fragment_shader_ns);
        const measured_fixed_function_ns = raster_coverage_ns + raster_depth_ns + raster_interpolation_ns + raster_target_output_ns;
        const other_fixed_function_ns = fixed_function_worker_ns -| measured_fixed_function_ns;
        const vertex_invocations = self.vertex_invocations.load(.monotonic);
        const vertex_instructions = self.vertex_instructions.load(.monotonic);
        const vertex_fast_path_instructions = self.vertex_fast_path_instructions.load(.monotonic);
        const vertex_waves = self.vertex_waves.load(.monotonic);
        const vertex_full_waves = self.vertex_full_waves.load(.monotonic);
        const fragment_invocations = self.fragment_invocations.load(.monotonic);
        const fragment_instructions = self.fragment_instructions.load(.monotonic);
        const fragment_fast_path_instructions = self.fragment_fast_path_instructions.load(.monotonic);
        const fragment_waves = self.fragment_waves.load(.monotonic);
        const fragment_full_waves = self.fragment_full_waves.load(.monotonic);
        const memory_footprint = @as(f32, @floatFromInt(bounded_allocator.queryFootprint())) / 1_000_000;
        const peak_memory_footprint = @as(f32, @floatFromInt(bounded_allocator.queryPeakFootprint())) / 1_000_000;

        const log = std.log.scoped(.SoftwareRenderer);
        log.debug(
            \\Draw profile:
            \\>   wall:
            \\>   >    total:               {d:.3}ms
            \\>   >    vertex:              {d:.3}ms
            \\>   >    raster:              {d:.3}ms
            \\>   vertex CPU:
            \\>   >    input:               {d:.3}ms
            \\>   >    shader:              {d:.3}ms
            \\>   >    output:              {d:.3}ms
            \\>   >    invocations:         {d}
            \\>   >    instructions:        {d}
            \\>   >    waves:               {d} ({d:.1}% full, {d:.1}% lane occupancy)
            \\>   >    SIMD fast path:      {d} lane-instructions ({d:.1}%)
        , .{
            milliseconds(self.draw_wall_ns),
            milliseconds(self.vertex_wall_ns),
            milliseconds(self.raster_wall_ns),
            milliseconds(vertex_input_ns),
            milliseconds(vertex_shader_ns),
            milliseconds(vertex_output_ns),
            vertex_invocations,
            vertex_instructions,
            vertex_waves,
            percentage(vertex_full_waves, vertex_waves),
            percentage(vertex_invocations, vertex_waves * 4),
            vertex_fast_path_instructions,
            percentage(vertex_fast_path_instructions, vertex_instructions),
        });
        log.debug(
            \\>   raster:
            \\>   >    binning:             {d:.3}ms
            \\>   >    tiles:               {d:.3}ms
            \\>   >    active_tiles:        {d}
            \\>   >    polygons:            {d}
            \\>   raster worker CPU:
            \\>   >    total:               {d:.3}ms
            \\>   >    fixed_function:      {d:.3}ms
            \\>   >    >    coverage/setup: {d:.3}ms
            \\>   >    >    early depth:    {d:.3}ms
            \\>   >    >    interpolation:  {d:.3}ms
            \\>   >    >    target output:  {d:.3}ms
            \\>   >    >    other/scalar:   {d:.3}ms
        , .{
            milliseconds(self.binning_wall_ns),
            milliseconds(self.tile_wall_ns),
            self.active_tiles,
            polygons,
            milliseconds(raster_worker_ns),
            milliseconds(fixed_function_worker_ns),
            milliseconds(raster_coverage_ns),
            milliseconds(raster_depth_ns),
            milliseconds(raster_interpolation_ns),
            milliseconds(raster_target_output_ns),
            milliseconds(other_fixed_function_ns),
        });
        log.debug(
            \\>   fragment CPU:
            \\>   >    input:               {d:.3}ms
            \\>   >    shader:              {d:.3}ms
            \\>   >    output:              {d:.3}ms
            \\>   >    invocations:         {d}
            \\>   >    instructions:        {d}
            \\>   >    waves:               {d} ({d:.1}% full, {d:.1}% lane occupancy)
            \\>   >    SIMD fast path:      {d} lane-instructions ({d:.1}%)
        , .{
            milliseconds(fragment_input_ns),
            milliseconds(fragment_shader_ns),
            milliseconds(fragment_output_ns),
            fragment_invocations,
            fragment_instructions,
            fragment_waves,
            percentage(fragment_full_waves, fragment_waves),
            percentage(fragment_invocations, fragment_waves * 4),
            fragment_fast_path_instructions,
            percentage(fragment_fast_path_instructions, fragment_instructions),
        });
        log.debug(
            \\>   memory:
            \\>   >    total:               {d:.3}MB
            \\>   >    peak concurrent:     {d:.3}MB
        , .{ memory_footprint, peak_memory_footprint });
    }
};

pub fn profileElapsedNs(start: std.Io.Timestamp, io: std.Io) u64 {
    const elapsed = start.untilNow(io, .real).toNanoseconds();
    return if (elapsed > 0) @intCast(elapsed) else 0;
}

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
    fragment_resources: FragmentResources,

    render_pass: *SoftRenderPass,
    framebuffer: *SoftFramebuffer,

    rasterizer_wait_group: std.Io.Group,
    profile: DrawProfile,

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
            // SAFETY: draw assigns the viewport before the rasterizer receives this value.
            .viewport = undefined,
            // SAFETY: draw assigns the scissor before the rasterizer receives this value.
            .scissor = undefined,
            .color_attachments = framebuffer.interface.attachments[0..],
            .depth_attachment = if (render_pass.interface.subpasses[renderer.subpass_index].depth_stencil_attachments) |desc| framebuffer.interface.attachments[desc.attachment] else null,
            .input_attachment_snapshots = &.{},
            .fragment_resources = .{},
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .rasterizer_wait_group = .init,
            .profile = .{},
            .stats = .{
                .polygons_drawn = 0,
            },
        };

        for (self.vertices) |*vertex| {
            vertex.primitive_restart = false;
            vertex.point_size = 1.0;
            if (comptime base.config.soft_ir_interpreter) {
                vertex.packed_outputs = @splat(@splat(null));
            } else {
                for (&vertex.outputs) |*location|
                    @memset(location, null);
            }
        }

        return self;
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (comptime !base.config.soft_ir_interpreter) {
            for (self.vertices) |*vertex| {
                for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
                    for (0..4) |component| {
                        if (vertex.outputs[location][component]) |output|
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
    const allocator = self.device.interface.device_allocator.allocator();
    for (self.input_attachment_snapshots) |snapshot| {
        allocator.free(snapshot.data);
    }
    allocator.free(self.input_attachment_snapshots);
    self.input_attachment_snapshots = &.{};
}

pub fn draw(self: *Self, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize) VkError!void {
    var bounded_allocator: BoundedAllocator = .init(self.device.interface.device_allocator.allocator(), draw_allocator_limit);
    try self.drawCall(&bounded_allocator, vertex_count, instance_count, first_vertex, first_instance, null, null);
}

pub fn drawIndexed(self: *Self, index_count: usize, instance_count: usize, first_index: usize, first_instance: usize, vertex_offset: i32) VkError!void {
    var bounded_allocator: BoundedAllocator = .init(self.device.interface.device_allocator.allocator(), draw_allocator_limit);
    const allocator = bounded_allocator.allocator();

    const indexed_draw = try self.readIndexBuffer(allocator, index_count, first_index, vertex_offset);

    try self.drawCall(&bounded_allocator, index_count, instance_count, 0, first_instance, indexed_draw.indices, indexed_draw.primitive_restart);
}

fn drawCall(self: *Self, bounded_allocator: *BoundedAllocator, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize, indices: ?[]const u32, primitive_restart: ?[]const bool) VkError!void {
    const io = self.device.interface.io();
    const allocator = bounded_allocator.allocator();

    var draw_call = try DrawCall.init(allocator, vertex_count, instance_count, self);
    defer draw_call.deinit(allocator);

    // SAFETY: only read when soft_profile is enabled at comptime, which also initializes the timer
    const profile_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(io, .real) else undefined;
    defer if (comptime base.config.soft_profile) {
        draw_call.profile.draw_wall_ns = profileElapsedNs(profile_timer, io);
        draw_call.profile.report(bounded_allocator, draw_call.stats.polygons_drawn);
    };

    const pipeline = self.state.pipeline orelse return VkError.InvalidPipelineDrv;
    if (comptime !base.config.soft_ir_interpreter) {
        const vertex_shader = pipeline.stages.getPtrAssertContains(.vertex);
        for (vertex_shader.runtimes) |*runtime| {
            ExecutionDevice.writeDescriptorSets(self.state, &runtime.rt) catch return VkError.Unknown;
        }
        if (pipeline.stages.getPtr(.fragment)) |fragment_shader| {
            for (fragment_shader.runtimes) |*runtime| {
                ExecutionDevice.writeDescriptorSets(self.state, &runtime.rt) catch return VkError.Unknown;
            }
        }
    }

    // SAFETY: only read when soft_profile is enabled at comptime, which also initializes the timer
    const vertex_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(io, .real) else undefined;
    self.vertexShaderStage(allocator, &draw_call, vertex_count, instance_count, first_vertex, first_instance, indices, primitive_restart) catch |err| {
        std.log.scoped(.@"Vertex stage").err("catched a '{s}'", .{@errorName(err)});
        if (comptime base.config.logs == .verbose) {
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
        }

        return VkError.Unknown;
    };
    if (comptime base.config.soft_profile)
        draw_call.profile.vertex_wall_ns = profileElapsedNs(vertex_timer, io);

    if (pipeline.interface.mode.graphics.rasterization.rasterizer_discard_enable)
        return;

    draw_call.viewport = try self.resolveViewport(0);
    draw_call.scissor = try self.resolveScissor(0);

    // SAFETY: only read when soft_profile is enabled at comptime, which also initializes the timer
    const raster_timer = if (comptime base.config.soft_profile) std.Io.Timestamp.now(io, .real) else undefined;
    try rasterizer.processThenFragmentStage(self, allocator, &draw_call);
    if (comptime base.config.soft_profile)
        draw_call.profile.raster_wall_ns = profileElapsedNs(raster_timer, io);
}

fn vertexShaderStage(self: *Self, allocator: std.mem.Allocator, draw_call: *DrawCall, vertex_count: usize, instance_count: usize, first_vertex: usize, first_instance: usize, indices: ?[]const u32, primitive_restart: ?[]const bool) !void {
    const pipeline = self.state.pipeline orelse return;
    const vertex_shader = pipeline.stages.getPtr(.vertex) orelse return;
    const batch_size = if (comptime base.config.soft_ir_interpreter) vertex_shader.workerCount() else vertex_shader.runtimes.len;

    var vertex_reuse: ?VertexReuse = if (comptime base.config.soft_ir_interpreter)
        if (indices) |draw_indices|
            if (vertexProgramAllowsReuse(&vertex_shader.program)) try VertexReuse.init(allocator, draw_indices, primitive_restart) else null
        else
            null
    else
        null;
    defer if (vertex_reuse) |*reuse| reuse.deinit(allocator);
    const invocation_indices: ?[]const usize = if (vertex_reuse) |*reuse| reuse.uniqueInvocations() else null;
    const shader_vertex_count = if (invocation_indices) |items| items.len else vertex_count;

    if (comptime base.config.soft_ir_interpreter) {
        const invocation_count = std.math.mul(usize, shader_vertex_count, instance_count) catch std.math.maxInt(usize);
        if (invocation_count == 0)
            return;
        const estimated_work = std.math.mul(usize, invocation_count, vertex_shader.program.code.len) catch std.math.maxInt(usize);
        const inline_vertex_work_limit = 4096;
        if (estimated_work <= inline_vertex_work_limit) {
            for (0..instance_count) |instance_index| {
                try vertex_dispatcher.runInline(.{
                    .allocator = allocator,
                    .pipeline = pipeline,
                    .batch_id = 0,
                    .batch_size = 1,
                    .vertex_count = vertex_count,
                    .invocation_indices = invocation_indices,
                    .first_vertex = first_vertex,
                    .first_instance = first_instance,
                    .indices = indices,
                    .primitive_restart = primitive_restart,
                    .instance_index = instance_index,
                    .draw_call = draw_call,
                });
            }
            if (vertex_reuse) |reuse|
                reuse.copyReusedVertices(draw_call, vertex_count, instance_count);
            return;
        }
    }

    const batch_count = std.math.divCeil(usize, shader_vertex_count, vertex_dispatcher.batch_width) catch return VkError.ValidationFailed;
    var wg: std.Io.Group = .init;
    for (0..instance_count) |instance_index| {
        for (0..@min(batch_size, batch_count)) |batch_id| {
            const run_data: vertex_dispatcher.RunData = .{
                .allocator = allocator,
                .pipeline = pipeline,
                .batch_id = batch_id,
                .batch_size = batch_size,
                .vertex_count = vertex_count,
                .invocation_indices = invocation_indices,
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
    if (vertex_reuse) |reuse|
        reuse.copyReusedVertices(draw_call, vertex_count, instance_count);
}

fn vertexProgramAllowsReuse(program: anytype) bool {
    if (program.uses_atomics)
        return false;
    for (program.code) |instruction| switch (instruction.opcode) {
        .image_write, .image_write_float, .store_buffer, .store_workgroup => return false,
        else => {},
    };
    return true;
}

const VertexReuse = struct {
    representatives: []usize,
    unique_storage: []usize,
    unique_count: usize,

    fn init(allocator: std.mem.Allocator, indices: []const u32, primitive_restart: ?[]const bool) VkError!?VertexReuse {
        const representatives = allocator.alloc(usize, indices.len) catch return VkError.OutOfDeviceMemory;
        errdefer allocator.free(representatives);
        const unique_storage = allocator.alloc(usize, indices.len) catch return VkError.OutOfDeviceMemory;
        errdefer allocator.free(unique_storage);

        var first_occurrences = std.AutoHashMap(u32, usize).init(allocator);
        defer first_occurrences.deinit();
        var unique_count: usize = 0;
        for (indices, 0..) |index, invocation_index| {
            if (primitive_restart) |restart| {
                if (restart[invocation_index]) {
                    representatives[invocation_index] = invocation_index;
                    unique_storage[unique_count] = invocation_index;
                    unique_count += 1;
                    continue;
                }
            }

            const entry = first_occurrences.getOrPut(index) catch return VkError.OutOfDeviceMemory;
            if (!entry.found_existing) {
                entry.value_ptr.* = invocation_index;
                unique_storage[unique_count] = invocation_index;
                unique_count += 1;
            }
            representatives[invocation_index] = entry.value_ptr.*;
        }

        if (unique_count == indices.len) {
            allocator.free(representatives);
            allocator.free(unique_storage);
            return null;
        }
        return .{
            .representatives = representatives,
            .unique_storage = unique_storage,
            .unique_count = unique_count,
        };
    }

    fn deinit(self: *VertexReuse, allocator: std.mem.Allocator) void {
        allocator.free(self.representatives);
        allocator.free(self.unique_storage);
        self.* = undefined;
    }

    fn uniqueInvocations(self: *const VertexReuse) []const usize {
        return self.unique_storage[0..self.unique_count];
    }

    fn copyReusedVertices(self: VertexReuse, draw_call: *DrawCall, vertex_count: usize, instance_count: usize) void {
        for (0..instance_count) |instance_index| {
            const instance_base = instance_index * vertex_count;
            for (self.representatives, 0..) |representative, invocation_index| {
                if (representative != invocation_index)
                    draw_call.vertices[instance_base + invocation_index] = draw_call.vertices[instance_base + representative];
            }
        }
    }
};

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
