const std = @import("std");
const base = @import("base");

const ExecutionDevice = @import("../Device.zig");
const PipelineState = ExecutionDevice.PipelineState;

const SoftDevice = @import("../../SoftDevice.zig");
const ir_interpreter = @import("ir_interpreter.zig");

const VkError = base.VkError;

const Self = @This();

pub const Batch = struct {
    worker_index: usize,
    worker_count: usize,
    total_groups: usize,
    base_group: [3]usize,
    group_count: [3]usize,

    pub fn groupId(self: Batch, linear_index: usize) [3]usize {
        const groups_xy = self.group_count[0] * self.group_count[1];
        const group_z = linear_index / groups_xy;
        const remainder = linear_index - group_z * groups_xy;
        const group_y = remainder / self.group_count[0];
        const group_x = remainder - group_y * self.group_count[0];
        return .{
            self.base_group[0] + group_x,
            self.base_group[1] + group_y,
            self.base_group[2] + group_z,
        };
    }
};

device: *SoftDevice,
state: *PipelineState,

pub fn init(device: *SoftDevice, state: *PipelineState) Self {
    return .{
        .device = device,
        .state = state,
    };
}

pub fn dispatch(self: *Self, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    try self.dispatchBase(0, 0, 0, group_count_x, group_count_y, group_count_z);
}

fn dispatchBatches(
    io: std.Io,
    context: anytype,
    worker_count: usize,
    total_groups: usize,
    base_group: [3]usize,
    group_count: [3]usize,
    comptime worker: anytype,
) !void {
    if (total_groups == 0)
        return;
    if (worker_count == 0)
        return error.NoWorkers;

    const active_workers = @min(worker_count, total_groups);
    var group: std.Io.Group = .init;
    for (0..active_workers) |worker_index| {
        group.async(io, worker, .{ context, Batch{
            .worker_index = worker_index,
            .worker_count = active_workers,
            .total_groups = total_groups,
            .base_group = base_group,
            .group_count = group_count,
        } });
    }
    try group.await(io);
}

pub fn dispatchBase(self: *Self, base_group_x: u32, base_group_y: u32, base_group_z: u32, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    const group_count_xy = std.math.mul(usize, group_count_x, group_count_y) catch return VkError.ValidationFailed;
    const group_count = std.math.mul(usize, group_count_xy, group_count_z) catch return VkError.ValidationFailed;

    const pipeline = self.state.pipeline orelse return VkError.InvalidPipelineDrv;
    const shader = pipeline.stages.getPtr(.compute) orelse return VkError.InvalidPipelineDrv;

    const io = self.device.interface.io();
    const allocator = self.device.interface.device_allocator.allocator();
    const timer = std.Io.Timestamp.now(io, .real);
    defer if (comptime base.config.logs != .none) {
        const duration = timer.untilNow(io, .real);
        const ms: f32 = @floatFromInt(duration.toMicroseconds());
        std.log.scoped(.ComputeDispatcher).debug("Compute dispatch took {}ms using IR interpreter", .{ms / 1000});
    };

    var context = try ir_interpreter.prepare(allocator, shader, self.state, io);
    defer context.deinit(allocator);

    const worker_count = if (shader.program.uses_atomics) 1 else shader.runtimes.len;

    dispatchBatches(
        io,
        context,
        worker_count,
        group_count,
        .{ base_group_x, base_group_y, base_group_z },
        .{ group_count_x, group_count_y, group_count_z },
        runWrapper,
    ) catch |err| switch (err) {
        error.NoWorkers => return VkError.InvalidPipelineDrv,
        else => return VkError.DeviceLost,
    };
}

fn runWrapper(context: ir_interpreter.Context, batch: Batch) void {
    @call(.always_inline, ir_interpreter.runBatch, .{ context, batch }) catch |err| {
        std.log.scoped(.ComputeDispatcher).err("IR interpreter runtime caught a '{s}'", .{@errorName(err)});
        if (comptime base.config.logs == .verbose) {
            if (@errorReturnTrace()) |trace|
                std.debug.dumpErrorReturnTrace(trace);
        }
    };
}
