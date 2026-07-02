const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");
const lib = @import("lib.zig");

const VkError = base.VkError;
const Device = base.Device;

const SoftDevice = @import("SoftDevice.zig");

const Self = @This();
pub const Interface = base.ShaderModule;

interface: Interface,
module: spv.Module,

/// Pipelines need SPIR-V module reference so shader module may not
/// be destroy on call to `vkDestroyShaderModule`
ref_count: std.atomic.Value(usize),

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.ShaderModuleCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);

    const device_allocator = device.device_allocator.allocator();

    interface.vtable = &.{
        .destroy = destroy,
    };

    const code = info.p_code[0..@divExact(info.code_size, 4)];

    self.* = .{
        .interface = interface,
        .module = spv.Module.init(device_allocator, code, .{
            .use_simd_vectors_specializations = base.config.soft_shaders_simd,
        }) catch |err| switch (err) {
            spv.Module.ModuleError.OutOfMemory => return VkError.OutOfHostMemory,
            else => {
                std.log.scoped(.@"SPIR-V module").err("module creation catched a '{s}'", .{@errorName(err)});
                if (comptime base.config.logs == .verbose) {
                    if (@errorReturnTrace()) |trace| {
                        std.debug.dumpErrorReturnTrace(trace);
                    }
                }
                return VkError.ValidationFailed;
            },
        },
        .ref_count = std.atomic.Value(usize).init(1),
    };

    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.unref(allocator);
}

pub fn drop(self: *Self, allocator: std.mem.Allocator) void {
    const device_allocator = self.interface.owner.device_allocator.allocator();

    self.module.deinit(device_allocator);

    allocator.destroy(self);
}

pub fn ref(self: *Self) void {
    _ = self.ref_count.fetchAdd(1, .monotonic);
}

pub fn unref(self: *Self, allocator: std.mem.Allocator) void {
    if (self.ref_count.fetchSub(1, .release) == 1) {
        self.drop(allocator);
    }
}
