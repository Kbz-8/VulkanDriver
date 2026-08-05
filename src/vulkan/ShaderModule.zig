const std = @import("std");
const vk = @import("vulkan");
const shader_ir = @import("shader_ir");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .shader_module;
pub const IrModule = shader_ir.ir.module.Module;
pub const InstantiateOptions = shader_ir.spirv.translator.Options;

owner: *Device,
source: shader_ir.spirv.SourceModule,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, _: std.mem.Allocator, info: *const vk.ShaderModuleCreateInfo) VkError!Self {
    if (info.code_size % @sizeOf(u32) != 0)
        return VkError.ValidationFailed;

    const source_allocator = device.device_allocator.allocator();
    const words = info.p_code[0 .. info.code_size / @sizeOf(u32)];
    var source = shader_ir.spirv.SourceModule.init(source_allocator, words) catch |err| return switch (err) {
        error.OutOfMemory => VkError.OutOfHostMemory,
        else => VkError.ValidationFailed,
    };
    errdefer source.deinit(source_allocator);

    return .{
        .owner = device,
        .source = source,
        // SAFETY: the backend assigns the vtable before returning the shader module.
        .vtable = undefined,
    };
}

pub fn deinit(self: *Self) void {
    self.source.deinit(self.owner.device_allocator.allocator());
}

pub fn code(self: *const Self) []const u32 {
    return self.source.code();
}

/// Instantiates one entry point as a fresh, backend-agnostic IR module.
/// The returned module does not borrow from this shader module.
pub fn instantiateIr(self: *const Self, allocator: std.mem.Allocator, options: InstantiateOptions) !IrModule {
    return shader_ir.spirv.translator.instantiate(allocator, &self.source, options);
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}
