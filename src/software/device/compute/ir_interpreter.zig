const std = @import("std");
const base = @import("base");
const shader_ir = @import("shader_ir");

const ExecutionDevice = @import("../Device.zig");
const PipelineState = ExecutionDevice.PipelineState;
const Batch = @import("ComputeDispatcher.zig").Batch;
const Shader = @import("../../interpreter/Shader.zig");

const VkError = base.VkError;
const ir = shader_ir.ir;

pub const Context = struct {
    shader: *Shader,
    io: std.Io,
    local_size: [3]u32,
    local_xy: usize,
    local_count: usize,
    global_id: ?ir.id.InterfaceVariableId,
    resource_buffers: []?[]u8,

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        allocator.free(self.resource_buffers);
        self.* = undefined;
    }
};

pub fn prepare(allocator: std.mem.Allocator, shader: *Shader, state: *const PipelineState, io: std.Io) VkError!Context {
    const local_size = shader.workgroup_size orelse return VkError.ValidationFailed;
    const local_xy = std.math.mul(usize, local_size[0], local_size[1]) catch return VkError.ValidationFailed;
    const local_count = std.math.mul(usize, local_xy, local_size[2]) catch return VkError.ValidationFailed;
    if (shader.runtimes.len == 0)
        return VkError.InvalidPipelineDrv;

    const resource_buffers = allocator.alloc(?[]u8, shader.program.resources.len) catch return VkError.OutOfDeviceMemory;
    errdefer allocator.free(resource_buffers);
    @memset(resource_buffers, null);
    for (shader.program.resources, resource_buffers) |optional_resource, *buffer| {
        const resource = optional_resource orelse continue;
        if (resource.kind == .storage_buffer)
            buffer.* = try ExecutionDevice.mapStorageBuffer(state, resource.set, resource.binding);
    }

    return .{
        .shader = shader,
        .io = io,
        .local_size = local_size,
        .local_xy = local_xy,
        .local_count = local_count,
        .global_id = findGlobalInvocationId(&shader.program),
        .resource_buffers = resource_buffers,
    };
}

pub fn runBatch(context: Context, batch: Batch) !void {
    const shader = context.shader;
    if (batch.worker_index >= shader.runtimes.len)
        return VkError.InvalidPipelineDrv;

    const slot = &shader.runtimes[batch.worker_index];
    slot.mutex.lock(context.io) catch return VkError.DeviceLost;
    defer slot.mutex.unlock(context.io);

    const runtime = &slot.runtime;
    var group_index = batch.worker_index;
    while (group_index < batch.total_groups) : (group_index += batch.worker_count) {
        const group_id = batch.groupId(group_index);
        const group_x = std.math.cast(u32, group_id[0]) orelse return VkError.ValidationFailed;
        const group_y = std.math.cast(u32, group_id[1]) orelse return VkError.ValidationFailed;
        const group_z = std.math.cast(u32, group_id[2]) orelse return VkError.ValidationFailed;

        for (0..context.local_count) |local_index| {
            if (context.global_id) |variable| {
                const local_z = local_index / context.local_xy;
                const local_remainder = local_index - local_z * context.local_xy;
                const local_y = local_remainder / context.local_size[0];
                const local_x = local_remainder - local_y * context.local_size[0];
                try runtime.writeInput(&shader.program, variable, &.{
                    group_x * context.local_size[0] + @as(u32, @intCast(local_x)),
                    group_y * context.local_size[1] + @as(u32, @intCast(local_y)),
                    group_z * context.local_size[2] + @as(u32, @intCast(local_z)),
                });
            }
            _ = try runtime.run(&shader.program, .{ .resource_buffers = context.resource_buffers });
        }
    }
}

fn findGlobalInvocationId(program: *const @import("../../interpreter/Program.zig")) ?ir.id.InterfaceVariableId {
    for (program.interfaces, 0..) |optional_binding, index| {
        const binding = optional_binding orelse continue;
        if (binding.direction == .input and binding.semantic == .builtin and binding.semantic.builtin == .global_invocation_id)
            return ir.id.InterfaceVariableId.fromIndex(index);
    }
    return null;
}
