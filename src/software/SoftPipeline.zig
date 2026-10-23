const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const VkError = base.VkError;

pub const InputAttachmentSnapshot = struct {
    image: *base.Image,
    aspect_mask: vk.ImageAspectFlags,
    mip_level: u32,
    array_layer: u32,
    data: []const u8,
    row_pitch: usize,
    slice_pitch: usize,
    sample_stride: usize,
};

const SoftInstance = @import("SoftInstance.zig");
const InterpreterShader = @import("interpreter/Shader.zig");

const Self = @This();
pub const Interface = base.Pipeline;

const Stages = enum {
    vertex,
    fragment,
    compute,
};

interface: Interface,
runtimes_allocator: std.heap.ArenaAllocator,
stages: std.EnumMap(Stages, InterpreterShader),

pub fn createCompute(device: *base.Device, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.ComputePipelineCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    var initialized = false;
    errdefer if (initialized) self.interface.destroy(allocator) else allocator.destroy(self);

    var interface = try Interface.initCompute(device, allocator, cache, info);

    interface.vtable = &.{
        .destroy = destroy,
    };

    self.* = .{
        .interface = interface,
        .runtimes_allocator = .init(device.device_allocator.allocator()),
        .stages = std.EnumMap(Stages, InterpreterShader).init(.{}),
    };
    initialized = true;
    const runtimes_count = runtimeCount(device);

    self.stages.put(.compute, try InterpreterShader.compile(
        self.runtimes_allocator.allocator(),
        &self.interface.common_stages[0].module,
        runtimes_count,
    ));
    std.log.scoped(.ComputePipeline).debug("Created {d} IR runtimes for compute stage", .{runtimes_count});
    return self;
}

pub fn createGraphics(device: *base.Device, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.GraphicsPipelineCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    var initialized = false;
    errdefer if (initialized) self.interface.destroy(allocator) else allocator.destroy(self);

    var interface = try Interface.initGraphics(device, allocator, cache, info);

    interface.vtable = &.{
        .destroy = destroy,
    };

    self.* = .{
        .interface = interface,
        .runtimes_allocator = .init(device.device_allocator.allocator()),
        .stages = std.EnumMap(Stages, InterpreterShader).init(.{}),
    };
    initialized = true;
    const runtimes_count = runtimeCount(device);

    if (info.p_stages) |stages| {
        for (stages[0..info.stage_count], 0..) |stage, stage_index| {
            const driver_stage: Stages = blk: {
                if (stage.stage.contains(.{ .vertex = true })) {
                    break :blk .vertex;
                } else if (stage.stage.contains(.{ .fragment = true })) {
                    break :blk .fragment;
                } else {
                    std.log.scoped(.GraphicsPipeline).err("Invalid shader stage", .{});
                    return VkError.Unknown;
                }
            };

            std.log.scoped(.GraphicsPipeline).debug("Compiling {t} shader...", .{driver_stage});

            const shader = try InterpreterShader.compile(
                self.runtimes_allocator.allocator(),
                &self.interface.common_stages[stage_index].module,
                runtimes_count,
            );
            self.stages.put(driver_stage, shader);

            std.log.scoped(.GraphicsPipeline).debug("Created {d} IR runtimes for {t} stage", .{ runtimes_count, driver_stage });
        }
    } else {
        return VkError.ValidationFailed;
    }

    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    var it = self.stages.iterator();
    while (it.next()) |entry|
        entry.value.deinit();
    self.runtimes_allocator.deinit();
    allocator.destroy(self);
}

fn runtimeCount(device: *base.Device) usize {
    const instance: *SoftInstance = @alignCast(@fieldParentPtr("interface", device.instance));
    return switch (instance.threaded.async_limit) {
        .nothing => 1,
        .unlimited => std.Thread.getCpuCount() catch 1,
        else => |count| blk: {
            const cpu_count: usize = std.Thread.getCpuCount() catch break :blk @backingInt(count);
            break :blk @min(@backingInt(count), cpu_count);
        },
    };
}
