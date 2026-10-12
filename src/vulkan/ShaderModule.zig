const std = @import("std");
const vk = @import("vulkan");
const config = @import("config");
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

    if (comptime config.dump_spirv) {
        const io = device.io();

        const file = blk: {
            while (true) {
                var random_bytes: [16]u8 = @splat(0);
                io.random(&random_bytes);

                var name: [51]u8 = @splat(0);
                @memcpy(name[0..15], "ape_spirv_dump_");
                @memcpy(name[47..51], ".spv");

                for (random_bytes, 0..) |byte, i| {
                    name[15 + i * 2] = std.fmt.hex_charset[byte >> 4];
                    name[16 + i * 2] = std.fmt.hex_charset[byte & 0x0f];
                }

                break :blk std.Io.Dir.cwd().createFile(io, &name, .{ .exclusive = true }) catch |err| switch (err) {
                    error.PathAlreadyExists => continue,
                    else => {
                        std.log.scoped(.vkCreateShaderModule).warn("Failed to dump SPIR-V shader, {t}", .{err});
                        break :blk null;
                    },
                };
            }
        };
        if (file) |f| {
            defer f.close(io);

            var buffer: [1024]u8 = @splat(0);
            var writer = f.writer(io, buffer[0..]);
            writer.interface.writeAll(std.mem.sliceAsBytes(words)) catch |err| std.log.scoped(.vkCreateShaderModule).warn("Failed to dump SPIR-V shader, {t}", .{err});
        }
    }

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

/// The returned module does not borrow from this shader module
pub fn instantiateIr(self: *const Self, allocator: std.mem.Allocator, options: InstantiateOptions) !IrModule {
    return shader_ir.spirv.translator.instantiate(allocator, &self.source, options);
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}
