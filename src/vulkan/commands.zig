const std = @import("std");
const vk = @import("vulkan");

const Buffer = @import("Buffer.zig");
const Image = @import("Image.zig");

pub const CommandType = enum {
    BindPipeline,
    BindVertexBuffer,
    ClearColorImage,
    CopyBuffer,
    CopyImage,
    CopyImageToBuffer,
    Draw,
    DrawIndexed,
    DrawIndexedIndirect,
    DrawIndirect,
    FillBuffer,
};

pub const CommandBindPipeline = struct {
    bind_point: vk.PipelineBindPoint,
};
pub const CommandBindVertexBuffer = struct {
    buffers: []*const Buffer,
    offsets: []vk.DeviceSize,
    first_binding: u32,
};
pub const CommandClearColorImage = struct {
    image: *Image,
    layout: vk.ImageLayout,
    clear_color: vk.ClearColorValue,
    range: vk.ImageSubresourceRange,
};
pub const CommandCopyBuffer = struct {
    src: *Buffer,
    dst: *Buffer,
    regions: []const vk.BufferCopy,
};
pub const CommandCopyImage = struct {
    src: *Image,
    src_layout: vk.ImageLayout,
    dst: *Image,
    dst_layout: vk.ImageLayout,
    regions: []const vk.ImageCopy,
};
pub const CommandCopyImageToBuffer = struct {
    src: *Image,
    src_layout: vk.ImageLayout,
    dst: *Buffer,
    regions: []const vk.BufferImageCopy,
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
pub const CommandDrawIndexedIndirect = struct {
    buffer: *Buffer,
    offset: vk.DeviceSize,
    count: u32,
    stride: u32,
};
pub const CommandDrawIndirect = struct {
    buffer: *Buffer,
    offset: vk.DeviceSize,
    count: u32,
    stride: u32,
};
pub const CommandFillBuffer = struct {
    buffer: *Buffer,
    offset: vk.DeviceSize,
    size: vk.DeviceSize,
    data: u32,
};

pub const Command = union(CommandType) {
    BindPipeline: CommandBindPipeline,
    BindVertexBuffer: CommandBindVertexBuffer,
    ClearColorImage: CommandClearColorImage,
    CopyBuffer: CommandCopyBuffer,
    CopyImage: CommandCopyImage,
    CopyImageToBuffer: CommandCopyImageToBuffer,
    Draw: CommandDraw,
    DrawIndexed: CommandDrawIndexed,
    DrawIndexedIndirect: CommandDrawIndexedIndirect,
    DrawIndirect: CommandDrawIndirect,
    FillBuffer: CommandFillBuffer,
};
