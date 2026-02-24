const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");

const VkError = base.VkError;
const Device = base.Device;

const NonDispatchable = base.NonDispatchable;
const ShaderModule = base.ShaderModule;

const SoftDevice = @import("SoftDevice.zig");
const SoftShaderModule = @import("SoftShaderModule.zig");

const Self = @This();
pub const Interface = base.Pipeline;

const Shader = struct {
    module: *SoftShaderModule,
    runtimes: []spv.Runtime,
    entry: []const u8,
};

const Stages = enum {
    vertex,
    tessellation_control,
    tessellation_evaluation,
    geometry,
    fragment,
    compute,
};

interface: Interface,
stages: std.EnumMap(Stages, Shader),

pub fn createCompute(device: *base.Device, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.ComputePipelineCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.initCompute(device, allocator, cache, info);

    interface.vtable = &.{
        .destroy = destroy,
    };

    const soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", device));
    const module = try NonDispatchable(ShaderModule).fromHandleObject(info.stage.module);
    const soft_module: *SoftShaderModule = @alignCast(@fieldParentPtr("interface", module));

    const device_allocator = soft_device.device_allocator.allocator();

    self.* = .{
        .interface = interface,
        .stages = std.EnumMap(Stages, Shader).init(.{
            .compute = .{
                .module = blk: {
                    soft_module.ref();
                    break :blk soft_module;
                },
                .runtimes = blk: {
                    const runtimes = device_allocator.alloc(spv.Runtime, soft_device.workers.getIdCount()) catch return VkError.OutOfHostMemory;
                    errdefer device_allocator.free(runtimes);

                    for (runtimes) |*runtime| {
                        runtime.* = spv.Runtime.init(device_allocator, &soft_module.module) catch |err| {
                            std.log.scoped(.SpvRuntimeInit).err("SPIR-V Runtime failed to initialize, {s}", .{@errorName(err)});
                            return VkError.Unknown;
                        };
                    }
                    break :blk runtimes;
                },
                .entry = allocator.dupe(u8, std.mem.span(info.stage.p_name)) catch return VkError.OutOfHostMemory,
            },
        }),
    };
    return self;
}

pub fn createGraphics(device: *base.Device, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.GraphicsPipelineCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.initGraphics(device, allocator, cache, info);

    interface.vtable = &.{
        .destroy = destroy,
    };

    const soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", device));

    const runtimes = allocator.alloc(spv.Runtime, soft_device.workers.getIdCount()) catch return VkError.OutOfHostMemory;
    errdefer allocator.free(runtimes);

    //for (runtimes) |*runtime| {
    //    runtime.* = spv.Runtime.init() catch |err| {
    //        std.log.scoped(.SpvRuntimeInit).err("SPIR-V Runtime failed to initialize, {s}", .{@errorName(err)});
    //        return VkError.Unknown;
    //    };
    //}

    self.* = .{
        .interface = interface,
        .stages = std.enums.EnumMap(Stages, Shader).init(.{}),
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", interface.owner));
    const device_allocator = soft_device.device_allocator.allocator();

    var it = self.stages.iterator();
    while (it.next()) |stage| {
        stage.value.module.unref(allocator);
        for (stage.value.runtimes) |*runtime| {
            runtime.deinit(device_allocator);
        }
        device_allocator.free(stage.value.runtimes);
        allocator.free(stage.value.entry);
    }
    allocator.destroy(self);
}
