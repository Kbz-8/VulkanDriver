const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");
const lib = @import("../lib.zig");

const PipelineState = @import("PipelineState.zig");

const SoftDevice = @import("../SoftDevice.zig");
const SoftPipeline = @import("../SoftPipeline.zig");

const VkError = base.VkError;
const SpvRuntimeError = spv.Runtime.RuntimeError;

const Self = @This();

const RunData = struct {
    self: *Self,
    batch_id: usize,
    group_count: usize,
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
        .early_dump = std.process.parseEnvVarInt(lib.DUMP_EARLY_RESULT_TABLE_ENV_NAME, u32, 10) catch null,
        .final_dump = std.process.parseEnvVarInt(lib.DUMP_FINAL_RESULT_TABLE_ENV_NAME, u32, 10) catch null,
    };
}

pub fn destroy(self: *Self) void {
    _ = self;
}

pub fn dispatch(self: *Self, group_count_x: u32, group_count_y: u32, group_count_z: u32) VkError!void {
    const group_count: usize = @intCast(group_count_x * group_count_y * group_count_z);

    const pipeline = self.state.pipeline orelse return VkError.InvalidPipelineDrv;
    const shader = pipeline.stages.getPtr(.compute) orelse return VkError.InvalidPipelineDrv;
    const spv_module = &shader.module.module;
    self.batch_size = shader.runtimes.len;

    const invocations_per_workgroup = spv_module.local_size_x * spv_module.local_size_y * spv_module.local_size_z;

    self.invocation_index.store(0, .monotonic);

    var wg: std.Thread.WaitGroup = .{};
    for (0..@min(self.batch_size, group_count)) |batch_id| {
        if (std.process.hasEnvVarConstant(lib.SINGLE_THREAD_COMPUTE_EXECUTION_ENV_NAME)) {
            @branchHint(.cold); // Should only be reached for debugging

            runWrapper(
                RunData{
                    .self = self,
                    .batch_id = batch_id,
                    .group_count = group_count,
                    .group_count_x = @as(usize, @intCast(group_count_x)),
                    .group_count_y = @as(usize, @intCast(group_count_y)),
                    .group_count_z = @as(usize, @intCast(group_count_z)),
                    .invocations_per_workgroup = invocations_per_workgroup,
                    .pipeline = pipeline,
                },
            );
        } else {
            self.device.workers.spawnWg(&wg, runWrapper, .{
                RunData{
                    .self = self,
                    .batch_id = batch_id,
                    .group_count = group_count,
                    .group_count_x = @as(usize, @intCast(group_count_x)),
                    .group_count_y = @as(usize, @intCast(group_count_y)),
                    .group_count_z = @as(usize, @intCast(group_count_z)),
                    .invocations_per_workgroup = invocations_per_workgroup,
                    .pipeline = pipeline,
                },
            });
        }
    }
    self.device.workers.waitAndWork(&wg);
}

fn runWrapper(data: RunData) void {
    @call(.always_inline, run, .{data}) catch |err| {
        std.log.scoped(.@"SPIR-V runtime").err("SPIR-V runtime catched a '{s}'", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    };
}

inline fn run(data: RunData) !void {
    const allocator = data.self.device.device_allocator.allocator();

    const shader = data.pipeline.stages.getPtrAssertContains(.compute);
    const rt = &shader.runtimes[data.batch_id];

    const entry = try rt.getEntryPointByName(shader.entry);

    try data.self.writeDescriptorSets(rt);

    var group_index: usize = data.batch_id;
    while (group_index < data.group_count) : (group_index += data.self.batch_size) {
        var modulo: usize = group_index;

        const group_z = @divTrunc(modulo, data.group_count_x * data.group_count_y);

        modulo -= group_z * data.group_count_x * data.group_count_y;
        const group_y = @divTrunc(modulo, data.group_count_x);

        modulo -= group_y * data.group_count_x;
        const group_x = modulo;

        try setupWorkgroupBuiltins(data.self, rt, .{
            @as(u32, @intCast(data.group_count_x)),
            @as(u32, @intCast(data.group_count_y)),
            @as(u32, @intCast(data.group_count_z)),
        }, .{
            @as(u32, @intCast(group_x)),
            @as(u32, @intCast(group_y)),
            @as(u32, @intCast(group_z)),
        });

        for (0..data.invocations_per_workgroup) |i| {
            const invocation_index = data.self.invocation_index.fetchAdd(1, .monotonic);

            try setupSubgroupBuiltins(data.self, rt, .{
                @as(u32, @intCast(group_x)),
                @as(u32, @intCast(group_y)),
                @as(u32, @intCast(group_z)),
            }, i);

            if (data.self.early_dump != null and data.self.early_dump.? == invocation_index) {
                @branchHint(.cold);
                try dumpResultsTable(allocator, rt, true);
            }

            rt.callEntryPoint(allocator, entry) catch |err| switch (err) {
                // Some errors can be ignored
                SpvRuntimeError.OutOfBounds,
                SpvRuntimeError.Killed,
                => {},
                else => return err,
            };

            if (data.self.final_dump != null and data.self.final_dump.? == invocation_index) {
                @branchHint(.cold);
                try dumpResultsTable(allocator, rt, false);
            }

            try rt.flushDescriptorSets(allocator);
        }
    }
}

inline fn dumpResultsTable(allocator: std.mem.Allocator, rt: *spv.Runtime, is_early: bool) !void {
    @branchHint(.cold);
    const file = try std.fs.cwd().createFile(
        std.fmt.comptimePrint("{s}_compute_result_table_dump.txt", .{if (is_early) "early" else "final"}),
        .{ .truncate = true },
    );
    defer file.close();
    var buffer = [_]u8{0} ** 1024;
    var writer = file.writer(buffer[0..]);
    try rt.dumpResultsTable(allocator, &writer.interface);
}

fn writeDescriptorSets(self: *Self, rt: *spv.Runtime) !void {
    sets: for (self.state.sets[0..], 0..) |set, set_index| {
        if (set == null)
            continue :sets;

        bindings: for (set.?.descriptors[0..], 0..) |binding, binding_index| {
            switch (binding) {
                .buffer => |buffer_data_array| for (buffer_data_array, 0..) |buffer_data, descriptor_index| {
                    if (buffer_data.object) |buffer| {
                        const memory = if (buffer.interface.memory) |memory| memory else continue :bindings;
                        const map: []u8 = @as([*]u8, @ptrCast(try memory.map(buffer_data.offset, buffer_data.size)))[0..buffer_data.size];
                        try rt.writeDescriptorSet(
                            map,
                            @as(u32, @intCast(set_index)),
                            @as(u32, @intCast(binding_index)),
                            @as(u32, @intCast(descriptor_index)),
                        );
                    }
                },
                else => {},
            }
        }
    }
}

fn setupWorkgroupBuiltins(
    self: *Self,
    rt: *spv.Runtime,
    group_count: @Vector(3, u32),
    group_id: @Vector(3, u32),
) spv.Runtime.RuntimeError!void {
    const spv_module = &self.state.pipeline.?.stages.getPtrAssertContains(.compute).module.module;
    const workgroup_size = @Vector(3, u32){
        spv_module.local_size_x,
        spv_module.local_size_y,
        spv_module.local_size_z,
    };

    rt.writeBuiltIn(std.mem.asBytes(&workgroup_size), .WorkgroupSize) catch {};
    rt.writeBuiltIn(std.mem.asBytes(&group_count), .NumWorkgroups) catch {};
    rt.writeBuiltIn(std.mem.asBytes(&group_id), .WorkgroupId) catch {};
}

fn setupSubgroupBuiltins(
    self: *Self,
    rt: *spv.Runtime,
    group_id: @Vector(3, u32),
    local_invocation_index: usize,
) spv.Runtime.RuntimeError!void {
    const spv_module = &self.state.pipeline.?.stages.getPtrAssertContains(.compute).module.module;
    const workgroup_size = @Vector(3, u32){
        spv_module.local_size_x,
        spv_module.local_size_y,
        spv_module.local_size_z,
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
