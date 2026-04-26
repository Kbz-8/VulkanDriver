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

const vertex_dispatcher = @import("vertex_dispatcher.zig");

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
    _ = first_vertex;
    _ = first_instance;

    self.inputAssemblyStage() catch |err| {
        std.log.scoped(.@"Input assembly stage").err("catched a '{s}'", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(trace);
        }
    };

    self.vertexShaderStage(vertex_count, instance_count) catch |err| {
        std.log.scoped(.@"Input assembly stage").err("catched a '{s}'", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(trace);
        }
    };

    self.primitiveAssemblyStage();
    self.fragmentShaderStage();
}

pub fn deinit(self: *Self) void {
    _ = self;
}

fn inputAssemblyStage(self: *Self) !void {
    const pipeline = self.state.pipeline orelse return;
    for ((pipeline.stages.getPtr(.vertex) orelse return).runtimes) |*rt| {
        for (pipeline.interface.mode.graphics.input_assembly.attribute_description orelse return) |attribute| {
            const location_result = try rt.getResultByLocation(attribute.location, .input);

            const vertex_buffer = self.state.data.graphics.vertex_buffers[attribute.binding];
            const buffer = vertex_buffer.buffer;
            const buffer_memory_size = base.format.texelSize(attribute.format);
            const buffer_memory = if (buffer.interface.memory) |memory| memory else return VkError.InvalidDeviceMemoryDrv;
            const buffer_memory_map: []u8 = @as([*]u8, @ptrCast(@alignCast(try buffer_memory.map(buffer.interface.offset + attribute.offset, buffer_memory_size))))[0..buffer_memory_size];

            try rt.writeInput(buffer_memory_map, location_result);
        }
    }
}

fn vertexShaderStage(self: *Self, vertex_count: usize, instance_count: usize) !void {
    const invocation_count = vertex_count * instance_count;
    const pipeline = self.state.pipeline orelse return;
    const batch_size = (pipeline.stages.getPtr(.vertex) orelse return).runtimes.len;

    var wg: std.Io.Group = .init;
    for (0..@min(batch_size, invocation_count)) |batch_id| {
        const run_data: vertex_dispatcher.RunData = .{
            .renderer = self,
            .pipeline = pipeline,
            .batch_id = batch_id,
            .batch_size = batch_size,
            .invocation_count = invocation_count,
        };

        wg.async(self.device.interface.io(), vertex_dispatcher.runWrapper, .{run_data});
    }
    wg.await(self.device.interface.io()) catch return VkError.DeviceLost;
}

fn primitiveAssemblyStage(self: *Self) void {
    _ = self;
}

fn fragmentShaderStage(self: *Self) void {
    _ = self;
}
