const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");

const PipelineState = @import("PipelineState.zig");

const SoftDevice = @import("../SoftDevice.zig");
const SoftPipeline = @import("../SoftPipeline.zig");

const VkError = base.VkError;

const Self = @This();

const RunData = struct {
    self: *Self,
    batch_id: usize,
    group_count: usize,
    group_count_x: usize,
    group_count_y: usize,
    group_count_z: usize,
    subgroups_per_workgroup: usize,
    pipeline: *SoftPipeline,
};

device: *SoftDevice,
state: *PipelineState,
batch_size: usize,

pub fn init(device: *SoftDevice, state: *PipelineState) Self {
    return .{
        .device = device,
        .state = state,
        .batch_size = 0,
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

    const invocations_per_subgroup = 4;
    const invocations_per_workgroup = spv_module.local_size_x * spv_module.local_size_y * spv_module.local_size_z;
    const subgroups_per_workgroup = @divTrunc(invocations_per_workgroup + invocations_per_subgroup - 1, invocations_per_subgroup);

    var wg: std.Thread.WaitGroup = .{};
    for (0..@min(self.batch_size, group_count)) |batch_id| {
        self.device.workers.spawnWg(&wg, runWrapper, .{
            RunData{
                .self = self,
                .batch_id = batch_id,
                .group_count = group_count,
                .group_count_x = @as(usize, @intCast(group_count_x)),
                .group_count_y = @as(usize, @intCast(group_count_y)),
                .group_count_z = @as(usize, @intCast(group_count_z)),
                .subgroups_per_workgroup = subgroups_per_workgroup,
                .pipeline = pipeline,
            },
        });
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

    var group_index: usize = data.batch_id;
    while (group_index < data.group_count) : (group_index += data.self.batch_size) {
        var modulo: usize = group_index;

        const group_z = @divTrunc(modulo, data.group_count_x * data.group_count_y);

        modulo -= group_z * data.group_count_x * data.group_count_y;
        const group_y = @divTrunc(modulo, data.group_count_x);

        modulo -= group_y * data.group_count_x;
        const group_x = modulo;

        try setupWorkgroupBuiltins(
            data.self,
            rt,
            .{
                @as(u32, @intCast(data.group_count_x)),
                @as(u32, @intCast(data.group_count_y)),
                @as(u32, @intCast(data.group_count_z)),
            },
            .{
                @as(u32, @intCast(group_x)),
                @as(u32, @intCast(group_y)),
                @as(u32, @intCast(group_z)),
            },
        );

        for (0..data.subgroups_per_workgroup) |i| {
            try setupSubgroupBuiltins(
                data.self,
                rt,
                .{
                    @as(u32, @intCast(group_x)),
                    @as(u32, @intCast(group_y)),
                    @as(u32, @intCast(group_z)),
                },
                i,
            );
            try data.self.syncDescriptorSets(allocator, rt, true);

            rt.callEntryPoint(allocator, entry) catch |err| switch (err) {
                spv.Runtime.RuntimeError.OutOfBounds => {},
                else => return err,
            };

            try data.self.syncDescriptorSets(allocator, rt, false);
        }
    }
}

fn syncDescriptorSets(self: *Self, allocator: std.mem.Allocator, rt: *spv.Runtime, write: bool) !void {
    sets: for (self.state.sets[0..], 0..) |set, set_index| {
        if (set == null)
            continue :sets;

        bindings: for (set.?.descriptors[0..], 0..) |binding, binding_index| {
            switch (binding) {
                .buffer => |buffer_data| if (buffer_data.object) |buffer| {
                    const memory = if (buffer.interface.memory) |memory| memory else continue :bindings;
                    const map: []u8 = @as([*]u8, @ptrCast(try memory.map(buffer_data.offset, buffer_data.size)))[0..buffer_data.size];
                    if (write) {
                        try rt.writeDescriptorSet(
                            allocator,
                            map,
                            @as(u32, @intCast(set_index)),
                            @as(u32, @intCast(binding_index)),
                        );
                    } else {
                        try rt.readDescriptorSet(
                            map,
                            @as(u32, @intCast(set_index)),
                            @as(u32, @intCast(binding_index)),
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
    group_count: [3]u32,
    group_id: [3]u32,
) spv.Runtime.RuntimeError!void {
    const spv_module = &self.state.pipeline.?.stages.getPtrAssertContains(.compute).module.module;
    const workgroup_size = [3]u32{
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
    group_id: [3]u32,
    local_invocation_index: usize,
) spv.Runtime.RuntimeError!void {
    const spv_module = &self.state.pipeline.?.stages.getPtrAssertContains(.compute).module.module;
    const workgroup_size = [3]u32{
        spv_module.local_size_x,
        spv_module.local_size_y,
        spv_module.local_size_z,
    };
    const local_base = [3]u32{
        workgroup_size[0] * group_id[0],
        workgroup_size[1] * group_id[1],
        workgroup_size[2] * group_id[2],
    };
    var local_invocation = [3]u32{ 0, 0, 0 };

    var idx: u32 = @intCast(local_invocation_index);
    local_invocation[2] = @divTrunc(idx, workgroup_size[0] * workgroup_size[1]);
    idx -= local_invocation[2] * workgroup_size[0] * workgroup_size[1];
    local_invocation[1] = @divTrunc(idx, workgroup_size[0]);
    idx -= local_invocation[1] * workgroup_size[0];
    local_invocation[0] = idx;

    const global_invocation_index = [3]u32{
        local_base[0] + local_invocation[0],
        local_base[1] + local_invocation[1],
        local_base[2] + local_invocation[2],
    };

    rt.writeBuiltIn(std.mem.asBytes(&global_invocation_index), .GlobalInvocationId) catch {};
}
