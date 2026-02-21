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

interface: Interface,

runtimes: []spv.Runtime,

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

    const runtimes = allocator.alloc(spv.Runtime, soft_device.workers.getIdCount()) catch return VkError.OutOfHostMemory;
    errdefer allocator.free(runtimes);

    for (runtimes) |*runtime| {
        runtime.* = spv.Runtime.init(allocator, &soft_module.module) catch |err| {
            std.log.scoped(.SpvRuntimeInit).err("SPIR-V Runtime failed to initialize, {s}", .{@errorName(err)});
            return VkError.Unknown;
        };
    }

    self.* = .{
        .interface = interface,
        .runtimes = runtimes,
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
        .runtimes = runtimes,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    for (self.runtimes) |*runtime| {
        runtime.deinit(allocator);
    }
    allocator.free(self.runtimes);
    allocator.destroy(self);
}
