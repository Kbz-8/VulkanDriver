const std = @import("std");
const vk = @import("vulkan");

const Buffer = @import("Buffer.zig");

pub const CommandType = enum {
    BindVertexBuffer,
    Draw,
    DrawIndexed,
    DrawIndirect,
    DrawIndexedIndirect,
    BindPipeline,
};

pub const CommandBindVertexBuffer = struct {
    buffers: std.ArrayList(Buffer),
    offsets: std.ArrayList(vk.DeviceSize),
    first_binding: u32,
};

pub const CommandDraw = struct {
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
};

pub const CommandDrawIndexed = struct {
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
};

pub const CommandDrawIndirect = struct {
    buffer: *Buffer,
    offset: vk.DeviceSize,
    count: u32,
    stride: u32,
};

pub const CommandDrawIndexedIndirect = struct {
    buffer: *Buffer,
    offset: vk.DeviceSize,
    count: u32,
    stride: u32,
};

pub const CommandBindPipeline = struct {
    bind_point: vk.PipelineBindPoint,
};

pub const Command = union(CommandType) {
    BindVertexBuffer: CommandBindVertexBuffer,
    Draw: CommandDraw,
    DrawIndexed: CommandDrawIndexed,
    DrawIndirect: CommandDrawIndirect,
    DrawIndexedIndirect: CommandDrawIndexedIndirect,
    BindPipeline: CommandBindPipeline,
};
