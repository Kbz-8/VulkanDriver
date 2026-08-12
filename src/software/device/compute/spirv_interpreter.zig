const std = @import("std");
const spv = @import("spv");

const SpvRuntimeError = spv.Runtime.RuntimeError;

const ExecutionDevice = @import("../Device.zig");
const SoftPipeline = @import("../../SoftPipeline.zig");
const Dispatcher = @import("ComputeDispatcher.zig");
const Batch = Dispatcher.Batch;

pub const SpvContext = struct {
    dispatcher: *Dispatcher,
    pipeline: *SoftPipeline,
    invocations_per_workgroup: usize,
    local_size: @Vector(3, u32),
};

pub fn runBatch(context: SpvContext, batch: Batch) !void {
    const dispatcher = context.dispatcher;
    const allocator = dispatcher.device.interface.device_allocator.allocator();
    const io = dispatcher.device.interface.io();

    const shader = context.pipeline.stages.getPtrAssertContains(.compute);
    const rt = &shader.runtimes[batch.worker_index].rt;

    const entry = try rt.getEntryPointByName(shader.entry);
    const uses_control_barrier = rt.mod.reflection_infos.has_control_barriers or rt.mod.reflection_infos.has_atomics;

    var barrier_runtimes: []spv.Runtime = &.{};
    var barrier_statuses: []spv.Runtime.EntryPointStatus = &.{};
    var initialized_barrier_runtimes: usize = 0;
    defer {
        for (barrier_runtimes[0..initialized_barrier_runtimes]) |*barrier_rt| {
            barrier_rt.resetInvocation(allocator);
            barrier_rt.deinit(allocator);
        }
        allocator.free(barrier_runtimes);
        allocator.free(barrier_statuses);
    }

    if (uses_control_barrier) {
        barrier_runtimes = try allocator.alloc(spv.Runtime, context.invocations_per_workgroup);
        barrier_statuses = try allocator.alloc(spv.Runtime.EntryPointStatus, context.invocations_per_workgroup);
        for (barrier_runtimes) |*barrier_rt| {
            barrier_rt.* = try spv.Runtime.init(allocator, rt.mod, rt.image_api);
            initialized_barrier_runtimes += 1;
            try barrier_rt.copySpecializationConstantsFrom(allocator, rt);
            try prepareRuntime(dispatcher, barrier_rt);
        }
    } else {
        try prepareRuntime(dispatcher, rt);
    }

    const group_count_vec = @Vector(3, u32){
        @intCast(batch.group_count[0]),
        @intCast(batch.group_count[1]),
        @intCast(batch.group_count[2]),
    };
    var group_index = batch.worker_index;
    while (group_index < batch.total_groups) : (group_index += batch.worker_count) {
        const group_id = batch.groupId(group_index);
        const group_id_vec = @Vector(3, u32){
            @intCast(group_id[0]),
            @intCast(group_id[1]),
            @intCast(group_id[2]),
        };

        if (uses_control_barrier) {
            try runBarrierWorkgroup(context, barrier_runtimes, barrier_statuses, entry, group_count_vec, group_id_vec);
            continue;
        }

        const workgroup_memory = try rt.createWorkgroupMemory(allocator);
        defer rt.destroyWorkgroupMemory(allocator, workgroup_memory);

        rt.resetInvocation(allocator);
        try rt.bindWorkgroupMemory(workgroup_memory);
        try setupWorkgroupBuiltins(dispatcher, rt, context.local_size, group_count_vec, group_id_vec);

        for (0..context.invocations_per_workgroup) |i| {
            rt.resetInvocation(allocator);

            const invocation_index = dispatcher.invocation_index.fetchAdd(1, .monotonic);

            try setupSubgroupBuiltins(dispatcher, rt, context.local_size, group_id_vec, i);

            if (dispatcher.early_dump != null and dispatcher.early_dump.? == invocation_index) {
                @branchHint(.cold);
                try dumpResultsTable(allocator, io, rt, true);
            }

            rt.callEntryPoint(allocator, entry) catch |err| switch (err) {
                SpvRuntimeError.OutOfBounds => {},
                SpvRuntimeError.Killed => continue,
                else => return err,
            };
            try flushWorkgroupMemory(rt, workgroup_memory);
            try rt.flushDescriptorSets(allocator);

            if (dispatcher.final_dump != null and dispatcher.final_dump.? == invocation_index) {
                @branchHint(.cold);
                try dumpResultsTable(allocator, io, rt, false);
            }
        }
    }
}

fn prepareRuntime(dispatcher: *Dispatcher, rt: *spv.Runtime) !void {
    const allocator = dispatcher.device.interface.device_allocator.allocator();

    rt.resetInvocation(allocator);
    if (rt.specialization_constants.count() != 0)
        try rt.applySpecializationInvocationLayout(allocator);
    try ExecutionDevice.writeDescriptorSets(dispatcher.state, rt);
    try rt.populatePushConstants(dispatcher.state.push_constant_blob[0..]);
}

fn runBarrierWorkgroup(
    context: SpvContext,
    runtimes: []spv.Runtime,
    statuses: []spv.Runtime.EntryPointStatus,
    entry: spv.SpvWord,
    group_count: @Vector(3, u32),
    group_id: @Vector(3, u32),
) !void {
    const dispatcher = context.dispatcher;
    const allocator = dispatcher.device.interface.device_allocator.allocator();

    const workgroup_memory = try runtimes[0].createWorkgroupMemory(allocator);
    defer runtimes[0].destroyWorkgroupMemory(allocator, workgroup_memory);
    for (runtimes, 0..) |*rt, i| {
        rt.resetInvocation(allocator);
        try rt.bindWorkgroupMemory(workgroup_memory);
        try setupWorkgroupBuiltins(dispatcher, rt, context.local_size, group_count, group_id);
        try setupSubgroupBuiltins(dispatcher, rt, context.local_size, group_id, i);
        statuses[i] = try rt.beginEntryPoint(allocator, entry);
        try flushWorkgroupMemory(rt, workgroup_memory);
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
            try rt.bindWorkgroupMemory(workgroup_memory);
            statuses[i] = try rt.continueEntryPoint(allocator);
            try flushWorkgroupMemory(rt, workgroup_memory);
            try rt.flushDescriptorSets(allocator);
        }
    }
}

fn flushWorkgroupMemory(rt: *spv.Runtime, workgroup_memory: []const spv.Runtime.WorkgroupMemory) spv.Runtime.RuntimeError!void {
    for (workgroup_memory) |memory| {
        _ = try (try rt.results[memory.result].getValue()).read(memory.bytes);
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

fn setupWorkgroupBuiltins(dispatcher: *Dispatcher, rt: *spv.Runtime, local_size: @Vector(3, u32), group_count: @Vector(3, u32), group_id: @Vector(3, u32)) spv.Runtime.RuntimeError!void {
    const allocator = dispatcher.device.interface.device_allocator.allocator();

    rt.writeBuiltIn(allocator, std.mem.asBytes(&local_size), .WorkgroupSize) catch |err| switch (err) {
        SpvRuntimeError.NotFound => {},
        else => return err,
    };
    rt.writeBuiltIn(allocator, std.mem.asBytes(&group_count), .NumWorkgroups) catch |err| switch (err) {
        SpvRuntimeError.NotFound => {},
        else => return err,
    };
    rt.writeBuiltIn(allocator, std.mem.asBytes(&group_id), .WorkgroupId) catch |err| switch (err) {
        SpvRuntimeError.NotFound => {},
        else => return err,
    };
}

fn setupSubgroupBuiltins(dispatcher: *Dispatcher, rt: *spv.Runtime, local_size: @Vector(3, u32), group_id: @Vector(3, u32), local_invocation_index: usize) spv.Runtime.RuntimeError!void {
    const allocator = dispatcher.device.interface.device_allocator.allocator();

    const local_base = local_size * group_id;
    var local_invocation = @Vector(3, u32){ 0, 0, 0 };

    var idx: u32 = @intCast(local_invocation_index);
    local_invocation[2] = @divTrunc(idx, local_size[0] * local_size[1]);
    idx -= local_invocation[2] * local_size[0] * local_size[1];
    local_invocation[1] = @divTrunc(idx, local_size[0]);
    idx -= local_invocation[1] * local_size[0];
    local_invocation[0] = idx;

    const global_invocation_index = local_base + local_invocation;
    const local_invocation_index_u32: u32 = @intCast(local_invocation_index);

    rt.writeBuiltIn(allocator, std.mem.asBytes(&local_invocation), .LocalInvocationId) catch |err| switch (err) {
        SpvRuntimeError.NotFound => {},
        else => return err,
    };
    rt.writeBuiltIn(allocator, std.mem.asBytes(&local_invocation_index_u32), .LocalInvocationIndex) catch |err| switch (err) {
        SpvRuntimeError.NotFound => {},
        else => return err,
    };
    rt.writeBuiltIn(allocator, std.mem.asBytes(&global_invocation_index), .GlobalInvocationId) catch |err| switch (err) {
        SpvRuntimeError.NotFound => {},
        else => return err,
    };
}
