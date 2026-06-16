const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");
const lib = @import("../lib.zig");

const ExecutionDevice = @import("Device.zig");
const PipelineState = ExecutionDevice.PipelineState;

const SoftDevice = @import("../SoftDevice.zig");
const SoftPipeline = @import("../SoftPipeline.zig");

const VkError = base.VkError;
const SpvRuntimeError = spv.Runtime.RuntimeError;

const Self = @This();

const RunData = struct {
    self: *Self,
    batch_id: usize,
    group_count: usize,
    base_group_x: usize,
    base_group_y: usize,
    base_group_z: usize,
    group_count_x: usize,
    group_count_y: usize,
    group_count_z: usize,
    invocations_per_workgroup: usize,
    pipeline: *SoftPipeline,
};

device: *SoftDevice,
state: *PipelineState,
batch_size: usize,

invocation_index: std.atomic.Value(usize),

early_dump: ?u32,
final_dump: ?u32,

pub fn init(device: *SoftDevice, state: *PipelineState) Self {
    return .{
        .device = device,
        .state = state,
        .batch_size = 0,
        .invocation_index = .init(0),
        .early_dump = base.config.soft_compute_dump_early_results_table,
        .final_dump = base.config.soft_compute_dump_final_results_table,
    };
}

pub fn dispatch(self: *Self, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    try self.dispatchBase(0, 0, 0, group_count_x, group_count_y, group_count_z);
}

pub fn dispatchBase(self: *Self, base_group_x: u32, base_group_y: u32, base_group_z: u32, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    const group_count_xy = std.math.mul(usize, group_count_x, group_count_y) catch return VkError.ValidationFailed;
    const group_count = std.math.mul(usize, group_count_xy, group_count_z) catch return VkError.ValidationFailed;

    const pipeline = self.state.pipeline orelse return VkError.InvalidPipelineDrv;
    const shader = pipeline.stages.getPtr(.compute) orelse return VkError.InvalidPipelineDrv;
    const spv_module = &shader.module.module;
    self.batch_size = shader.runtimes.len;

    const invocations_per_workgroup = spv_module.reflection_infos.local_size_x * spv_module.reflection_infos.local_size_y * spv_module.reflection_infos.local_size_z;

    self.invocation_index.store(0, .monotonic);

    const io = self.device.interface.io();
    const timer = std.Io.Timestamp.now(io, .real);
    defer if (comptime base.config.logs != .none) {
        const duration = timer.untilNow(io, .real);
        const ms: f32 = @floatFromInt(duration.toMicroseconds());
        std.log.scoped(.ComputeDispatcher).debug("Compute dispatch took {}ms", .{ms / 1000});
    };

    var wg: std.Io.Group = .init;
    for (0..@min(self.batch_size, group_count)) |batch_id| {
        const run_data: RunData = .{
            .self = self,
            .batch_id = batch_id,
            .group_count = group_count,
            .base_group_x = @as(usize, @intCast(base_group_x)),
            .base_group_y = @as(usize, @intCast(base_group_y)),
            .base_group_z = @as(usize, @intCast(base_group_z)),
            .group_count_x = @as(usize, @intCast(group_count_x)),
            .group_count_y = @as(usize, @intCast(group_count_y)),
            .group_count_z = @as(usize, @intCast(group_count_z)),
            .invocations_per_workgroup = invocations_per_workgroup,
            .pipeline = pipeline,
        };

        wg.async(self.device.interface.io(), runWrapper, .{run_data});
    }
    wg.await(self.device.interface.io()) catch return VkError.DeviceLost;
}

fn runWrapper(data: RunData) void {
    @call(.always_inline, run, .{data}) catch |err| {
        std.log.scoped(.@"SPIR-V runtime").err("SPIR-V runtime catched a '{s}'", .{@errorName(err)});
        if (comptime base.config.logs == .verbose) {
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
        }
    };
}

inline fn run(data: RunData) !void {
    const allocator = data.self.device.device_allocator.allocator();
    const io = data.self.device.interface.io();

    const shader = data.pipeline.stages.getPtrAssertContains(.compute);
    const rt = &shader.runtimes[data.batch_id].rt;

    const entry = try rt.getEntryPointByName(shader.entry);
    const uses_control_barrier = rt.mod.reflection_infos.has_control_barriers;

    var barrier_runtimes: []spv.Runtime = &.{};
    var barrier_statuses: []spv.Runtime.EntryPointStatus = &.{};
    if (uses_control_barrier) {
        barrier_runtimes = try allocator.alloc(spv.Runtime, data.invocations_per_workgroup);
        barrier_statuses = try allocator.alloc(spv.Runtime.EntryPointStatus, data.invocations_per_workgroup);
        for (barrier_runtimes) |*barrier_rt| {
            barrier_rt.* = try spv.Runtime.init(allocator, rt.mod, rt.image_api);
            try barrier_rt.copySpecializationConstantsFrom(allocator, rt);
        }
    }

    defer {
        for (barrier_runtimes) |*barrier_rt| {
            barrier_rt.deinit(allocator);
        }
        allocator.free(barrier_runtimes);
        allocator.free(barrier_statuses);
    }

    if (!uses_control_barrier)
        try ExecutionDevice.writeDescriptorSets(data.self.state, rt);

    try rt.populatePushConstants(data.self.state.push_constant_blob[0..]);

    var group_index: usize = data.batch_id;
    while (group_index < data.group_count) : (group_index += data.self.batch_size) {
        var modulo: usize = group_index;

        const group_z = @divTrunc(modulo, data.group_count_x * data.group_count_y);

        modulo -= group_z * data.group_count_x * data.group_count_y;
        const group_y = @divTrunc(modulo, data.group_count_x);

        modulo -= group_y * data.group_count_x;
        const group_x = modulo;

        const group_count_vec = @Vector(3, u32){
            @as(u32, @intCast(data.group_count_x)),
            @as(u32, @intCast(data.group_count_y)),
            @as(u32, @intCast(data.group_count_z)),
        };
        const group_id_vec = @Vector(3, u32){
            @as(u32, @intCast(data.base_group_x + group_x)),
            @as(u32, @intCast(data.base_group_y + group_y)),
            @as(u32, @intCast(data.base_group_z + group_z)),
        };

        if (uses_control_barrier) {
            try runBarrierWorkgroup(data, barrier_runtimes, barrier_statuses, entry, group_count_vec, group_id_vec);
            continue;
        }

        for (0..data.invocations_per_workgroup) |i| {
            rt.resetInvocation(allocator);
            try setupWorkgroupBuiltins(data.self, rt, group_count_vec, group_id_vec);

            const invocation_index = data.self.invocation_index.fetchAdd(1, .monotonic);

            try setupSubgroupBuiltins(data.self, rt, .{
                @as(u32, @intCast(data.base_group_x + group_x)),
                @as(u32, @intCast(data.base_group_y + group_y)),
                @as(u32, @intCast(data.base_group_z + group_z)),
            }, i);

            if (data.self.early_dump != null and data.self.early_dump.? == invocation_index) {
                @branchHint(.cold);
                try dumpResultsTable(allocator, io, rt, true);
            }

            rt.callEntryPoint(allocator, entry) catch |err| switch (err) {
                // Some errors can be ignored
                SpvRuntimeError.OutOfBounds => {},
                SpvRuntimeError.Killed => continue,
                else => return err,
            };

            if (data.self.final_dump != null and data.self.final_dump.? == invocation_index) {
                @branchHint(.cold);
                try dumpResultsTable(allocator, io, rt, false);
            }

            try rt.flushDescriptorSets(allocator);
        }
    }
}

fn runBarrierWorkgroup(
    data: RunData,
    runtimes: []spv.Runtime,
    statuses: []spv.Runtime.EntryPointStatus,
    entry: spv.SpvWord,
    group_count: @Vector(3, u32),
    group_id: @Vector(3, u32),
) !void {
    const allocator = data.self.device.device_allocator.allocator();

    for (runtimes, 0..) |*rt, i| {
        rt.resetInvocation(allocator);
        try ExecutionDevice.writeDescriptorSets(data.self.state, rt);
        try rt.populatePushConstants(data.self.state.push_constant_blob[0..]);
        try setupWorkgroupBuiltins(data.self, rt, group_count, group_id);
        try setupSubgroupBuiltins(data.self, rt, group_id, i);
        statuses[i] = try rt.beginEntryPoint(allocator, entry);
        try rt.flushDescriptorSets(allocator);
    }

    while (true) {
        var pending = false;
        for (statuses) |status| {
            if (status == .barrier) {
                pending = true;
                break;
            }
        }
        if (!pending)
            break;

        for (runtimes, 0..) |*rt, i| {
            if (statuses[i] == .completed)
                continue;
            statuses[i] = try rt.continueEntryPoint(allocator);
            try rt.flushDescriptorSets(allocator);
        }
    }
}

fn dumpResultsTable(allocator: std.mem.Allocator, io: std.Io, rt: *spv.Runtime, comptime is_early: bool) !void {
    @branchHint(.cold);
    const file = try std.Io.Dir.cwd().createFile(
        io,
        std.fmt.comptimePrint("{s}_compute_result_table_dump.txt", .{if (is_early) "early" else "final"}),
        .{ .truncate = true },
    );
    defer file.close(io);
    var buffer = [_]u8{0} ** 1024;
    var writer = file.writer(io, buffer[0..]);
    try rt.dumpResultsTable(allocator, &writer.interface);
}

fn setupWorkgroupBuiltins(self: *Self, rt: *spv.Runtime, group_count: @Vector(3, u32), group_id: @Vector(3, u32)) spv.Runtime.RuntimeError!void {
    const spv_module = &self.state.pipeline.?.stages.getPtrAssertContains(.compute).module.module;
    const workgroup_size = @Vector(3, u32){
        spv_module.reflection_infos.local_size_x,
        spv_module.reflection_infos.local_size_y,
        spv_module.reflection_infos.local_size_z,
    };

    rt.writeBuiltIn(std.mem.asBytes(&workgroup_size), .WorkgroupSize) catch {};
    rt.writeBuiltIn(std.mem.asBytes(&group_count), .NumWorkgroups) catch {};
    rt.writeBuiltIn(std.mem.asBytes(&group_id), .WorkgroupId) catch {};
}

fn setupSubgroupBuiltins(self: *Self, rt: *spv.Runtime, group_id: @Vector(3, u32), local_invocation_index: usize) spv.Runtime.RuntimeError!void {
    const spv_module = &self.state.pipeline.?.stages.getPtrAssertContains(.compute).module.module;
    const workgroup_size = @Vector(3, u32){
        spv_module.reflection_infos.local_size_x,
        spv_module.reflection_infos.local_size_y,
        spv_module.reflection_infos.local_size_z,
    };
    const local_base = workgroup_size * group_id;
    var local_invocation = @Vector(3, u32){ 0, 0, 0 };

    var idx: u32 = @intCast(local_invocation_index);
    local_invocation[2] = @divTrunc(idx, workgroup_size[0] * workgroup_size[1]);
    idx -= local_invocation[2] * workgroup_size[0] * workgroup_size[1];
    local_invocation[1] = @divTrunc(idx, workgroup_size[0]);
    idx -= local_invocation[1] * workgroup_size[0];
    local_invocation[0] = idx;

    const global_invocation_index = local_base + local_invocation;

    rt.writeBuiltIn(std.mem.asBytes(&global_invocation_index), .GlobalInvocationId) catch {};
}
