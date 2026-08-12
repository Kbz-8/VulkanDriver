const std = @import("std");
const base = @import("base");
const spv = @import("spv");

const ExecutionDevice = @import("../Device.zig");
const PipelineState = ExecutionDevice.PipelineState;

const SoftDevice = @import("../../SoftDevice.zig");
const ir_interpreter = @import("ir_interpreter.zig");
const spirv_interpreter = @import("spirv_interpreter.zig");

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

const BackendContext = if (base.config.soft_ir_interpreter) ir_interpreter.Context else spirv_interpreter.SpvContext;

device: *SoftDevice,
state: *PipelineState,

invocation_index: std.atomic.Value(usize),

early_dump: ?u32,
final_dump: ?u32,

pub fn init(device: *SoftDevice, state: *PipelineState) Self {
    return .{
        .device = device,
        .state = state,
        .invocation_index = .init(0),
        .early_dump = base.config.soft_compute_dump_early_results_table,
        .final_dump = base.config.soft_compute_dump_final_results_table,
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

fn getLocalSize(rt: *spv.Runtime, allocator: std.mem.Allocator, spv_module: *const spv.Module) VkError!@Vector(3, u32) {
    if (rt.getWorkgroupSize(allocator) catch return VkError.ValidationFailed) |workgroup_size| {
        return workgroup_size;
    }

    return .{
        spv_module.reflection_infos.local_size_x,
        spv_module.reflection_infos.local_size_y,
        spv_module.reflection_infos.local_size_z,
    };
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
        std.log.scoped(.ComputeDispatcher).debug("Compute dispatch took {}ms using {s} interpreter", .{ ms / 1000, if (comptime base.config.soft_ir_interpreter) "IR" else "SPIR-V" });
    };

    var context: BackendContext = if (comptime base.config.soft_ir_interpreter)
        try ir_interpreter.prepare(allocator, shader, self.state, io)
    else blk: {
        if (shader.runtimes.len == 0)
            return VkError.InvalidPipelineDrv;
        const spv_module = &shader.module.module;
        const local_size = try getLocalSize(&shader.runtimes[0].rt, allocator, spv_module);
        const local_size_xy = std.math.mul(usize, local_size[0], local_size[1]) catch return VkError.ValidationFailed;
        const invocations_per_workgroup = std.math.mul(usize, local_size_xy, local_size[2]) catch return VkError.ValidationFailed;
        self.invocation_index.store(0, .monotonic);
        break :blk .{
            .dispatcher = self,
            .pipeline = pipeline,
            .invocations_per_workgroup = invocations_per_workgroup,
            .local_size = local_size,
        };
    };
    defer if (comptime base.config.soft_ir_interpreter)
        context.deinit(allocator);

    const worker_count = if (comptime base.config.soft_ir_interpreter)
        shader.runtimes.len
    else if (shader.module.module.reflection_infos.has_atomics)
        1
    else
        shader.runtimes.len;

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

fn runWrapper(context: BackendContext, batch: Batch) void {
    @call(.always_inline, run, .{ context, batch }) catch |err| {
        std.log.scoped(.ComputeDispatcher).err("{s} interpreter runtime caught a '{s}'", .{
            if (comptime base.config.soft_ir_interpreter) "IR" else "SPIR-V",
            @errorName(err),
        });
        if (comptime base.config.logs == .verbose) {
            if (@errorReturnTrace()) |trace|
                std.debug.dumpErrorReturnTrace(trace);
        }
    };
}

inline fn run(context: BackendContext, batch: Batch) !void {
    if (comptime base.config.soft_ir_interpreter) {
        return ir_interpreter.runBatch(context, batch);
    } else {
        return spirv_interpreter.runBatch(context, batch);
    }
}
