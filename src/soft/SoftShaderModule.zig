const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");
const lib = @import("lib.zig");

const VkError = base.VkError;
const Device = base.Device;

const Self = @This();
pub const Interface = base.ShaderModule;

interface: Interface,
module: spv.Module,

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.ShaderModuleCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);

    interface.vtable = &.{
        .destroy = destroy,
    };

    const code = info.p_code[0..@divExact(info.code_size, 4)];

    self.* = .{
        .interface = interface,
        .module = spv.Module.init(
            allocator,
            code,
            .{
                .use_simd_vectors_specializations = !std.process.hasEnvVarConstant(lib.NO_SHADER_SIMD_ENV_NAME),
            },
        ) catch |err| switch (err) {
            spv.Module.ModuleError.OutOfMemory => return VkError.OutOfHostMemory,
            else => return VkError.ValidationFailed,
        },
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    self.module.deinit(allocator);
    allocator.destroy(self);
}
