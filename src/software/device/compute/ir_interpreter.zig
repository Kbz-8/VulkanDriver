const std = @import("std");
const base = @import("base");
const shader_ir = @import("shader_ir");

const ExecutionDevice = @import("../Device.zig");
const PipelineState = ExecutionDevice.PipelineState;
const Batch = @import("Dispatcher.zig").Batch;
const Shader = @import("../../interpreter/Shader.zig");
const Program = @import("../../interpreter/Program.zig");
const Runtime = @import("../../interpreter/Runtime.zig");
const SoftImageView = @import("../../SoftImageView.zig");

const VkError = base.VkError;
const ir = shader_ir.ir;

pub const Context = struct {
    shader: *Shader,
    allocator: std.mem.Allocator,
    io: std.Io,
    local_size: [3]u32,
    local_xy: usize,
    local_count: usize,
    global_id: ?ir.id.InterfaceVariableId,
    local_id: ?ir.id.InterfaceVariableId,
    local_index: ?ir.id.InterfaceVariableId,
    workgroup_id: ?ir.id.InterfaceVariableId,
    num_workgroups: ?ir.id.InterfaceVariableId,
    workgroup_size: ?ir.id.InterfaceVariableId,
    resource_buffers: []?[]u8,
    resource_images: []?*SoftImageView,

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        allocator.free(self.resource_buffers);
        allocator.free(self.resource_images);
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
        if (resource.kind == .storage_buffer or resource.kind == .uniform_buffer)
            buffer.* = try ExecutionDevice.mapBuffer(state, resource.set, resource.binding, resource.array_element);
    }

    const resource_images = allocator.alloc(?*SoftImageView, shader.program.resources.len) catch return VkError.OutOfDeviceMemory;
    errdefer allocator.free(resource_images);
    @memset(resource_images, null);

    for (shader.program.resources, resource_images) |optional_resource, *image| {
        const resource = optional_resource orelse continue;
        if (resource.kind == .storage_image)
            image.* = try ExecutionDevice.mapStorageImage(state, resource.set, resource.binding, resource.array_element);
    }

    return .{
        .shader = shader,
        .allocator = allocator,
        .io = io,
        .local_size = local_size,
        .local_xy = local_xy,
        .local_count = local_count,
        .global_id = findInputBuiltin(&shader.program, .global_invocation_id),
        .local_id = findInputBuiltin(&shader.program, .local_invocation_id),
        .local_index = findInputBuiltin(&shader.program, .local_invocation_index),
        .workgroup_id = findInputBuiltin(&shader.program, .workgroup_id),
        .num_workgroups = findInputBuiltin(&shader.program, .num_workgroups),
        .workgroup_size = findInputBuiltin(&shader.program, .workgroup_size),
        .resource_buffers = resource_buffers,
        .resource_images = resource_images,
    };
}

pub fn runBatch(context: Context, batch: Batch) !void {
    const shader = context.shader;

    if (batch.worker_index >= shader.runtimes.len)
        return VkError.InvalidPipelineDrv;

    const slot = &shader.runtimes[batch.worker_index];
    slot.mutex.lock(context.io) catch return VkError.DeviceLost;
    defer slot.mutex.unlock(context.io);

    var barrier_runtimes: []Runtime = &.{};
    var statuses: []Runtime.Outcome = &.{};
    var initialized: usize = 0;

    defer {
        for (barrier_runtimes[0..initialized]) |*runtime|
            runtime.deinit();
        context.allocator.free(barrier_runtimes);
        context.allocator.free(statuses);
    }

    if (shader.program.uses_control_barriers) {
        barrier_runtimes = try context.allocator.alloc(Runtime, context.local_count);
        statuses = try context.allocator.alloc(Runtime.Outcome, context.local_count);
        for (barrier_runtimes) |*runtime| {
            runtime.* = try Runtime.init(context.allocator, &shader.program);
            initialized += 1;
        }
    }

    var group_index = batch.worker_index;
    while (group_index < batch.total_groups) : (group_index += batch.worker_count) {
        const group_id_raw = batch.groupId(group_index);
        const group_id = [3]u32{
            std.math.cast(u32, group_id_raw[0]) orelse return VkError.ValidationFailed,
            std.math.cast(u32, group_id_raw[1]) orelse return VkError.ValidationFailed,
            std.math.cast(u32, group_id_raw[2]) orelse return VkError.ValidationFailed,
        };
        if (shader.program.uses_control_barriers)
            try runBarrierWorkgroup(context, batch, barrier_runtimes, statuses, group_id)
        else
            try runSimpleWorkgroup(context, batch, &slot.runtime, group_id);
    }
}

fn runSimpleWorkgroup(context: Context, batch: Batch, runtime: *Runtime, group_id: [3]u32) !void {
    const program = &context.shader.program;
    const memory = try context.allocator.alloc(u8, program.workgroup_memory_size);
    defer context.allocator.free(memory);
    @memset(memory, 0);

    for (0..context.local_count) |local_index| {
        runtime.resetInvocation(program);
        try setupInputs(context, batch, runtime, group_id, local_index);
        const outcome = try runtime.run(program, .{ .resource_buffers = context.resource_buffers, .resource_images = context.resource_images, .workgroup_memory = memory });
        if (outcome != .returned)
            return Runtime.RuntimeError.BarrierDivergence;
    }
}

fn runBarrierWorkgroup(context: Context, batch: Batch, runtimes: []Runtime, statuses: []Runtime.Outcome, group_id: [3]u32) !void {
    const program = &context.shader.program;
    const memory = try context.allocator.alloc(u8, program.workgroup_memory_size);
    defer context.allocator.free(memory);
    @memset(memory, 0);

    for (runtimes, statuses, 0..) |*runtime, *status, local_index| {
        runtime.resetInvocation(program);
        try setupInputs(context, batch, runtime, group_id, local_index);
        status.* = try runtime.run(program, .{ .resource_buffers = context.resource_buffers, .resource_images = context.resource_images, .workgroup_memory = memory });
    }

    while (true) {
        var all_returned = true;
        var all_barrier = true;
        for (statuses) |status| switch (status) {
            .returned => all_barrier = false,
            .barrier => all_returned = false,
            .discarded => return Runtime.RuntimeError.BarrierDivergence,
        };
        if (all_returned)
            return;
        if (!all_barrier)
            return Runtime.RuntimeError.BarrierDivergence;

        for (runtimes, statuses) |*runtime, *status|
            status.* = try runtime.continueExecution(program, .{ .resource_buffers = context.resource_buffers, .resource_images = context.resource_images, .workgroup_memory = memory });
    }
}

fn setupInputs(context: Context, batch: Batch, runtime: *Runtime, group_id: [3]u32, local_index: usize) !void {
    const program = &context.shader.program;

    if (context.num_workgroups) |variable|
        try runtime.writeInput(program, variable, &.{ @intCast(batch.group_count[0]), @intCast(batch.group_count[1]), @intCast(batch.group_count[2]) });

    if (context.workgroup_size) |variable|
        try runtime.writeInput(program, variable, &context.local_size);

    if (context.workgroup_id) |variable|
        try runtime.writeInput(program, variable, &group_id);

    const local_z = local_index / context.local_xy;
    const local_remainder = local_index - local_z * context.local_xy;
    const local_y = local_remainder / context.local_size[0];
    const local_x = local_remainder - local_y * context.local_size[0];
    const local_id = [3]u32{ @intCast(local_x), @intCast(local_y), @intCast(local_z) };

    if (context.global_id) |variable|
        try runtime.writeInput(program, variable, &.{
            group_id[0] * context.local_size[0] + local_id[0],
            group_id[1] * context.local_size[1] + local_id[1],
            group_id[2] * context.local_size[2] + local_id[2],
        });

    if (context.local_id) |variable|
        try runtime.writeInput(program, variable, &local_id);

    if (context.local_index) |variable|
        try runtime.writeInput(program, variable, &.{@intCast(local_index)});
}

fn findInputBuiltin(program: *const Program, builtin: ir.module.Builtin) ?ir.id.InterfaceVariableId {
    for (program.interfaces, 0..) |optional_binding, index| {
        const binding = optional_binding orelse continue;
        if (binding.direction == .input and binding.semantic == .builtin and binding.semantic.builtin == builtin)
            return ir.id.InterfaceVariableId.fromIndex(index);
    }
    return null;
}
