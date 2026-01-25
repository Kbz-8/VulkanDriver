const std = @import("std");
const vk = @import("vulkan");
const lib = @import("lib.zig");

const NonDispatchable = @import("NonDispatchable.zig");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .shader_module;

owner: *Device,

vtable: *const VTable,

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.ShaderModuleCreateInfo) VkError!Self {
    if (std.process.hasEnvVarConstant(lib.DRIVER_LOG_SPIRV_ENV_NAME)) {
        logShaderModule(allocator, info) catch |e| {
            std.log.scoped(.ShaderModule).err("Failed to disassemble SPIR-V module to readable text: {s}", .{@errorName(e)});
        };
    }

    return .{
        .owner = device,
        .vtable = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}

fn logShaderModule(allocator: std.mem.Allocator, info: *const vk.ShaderModuleCreateInfo) !void {
    std.log.scoped(.ShaderModule).info("Logging SPIR-V module", .{});

    var process = std.process.Child.init(&[_][]const u8{ "spirv-dis", "/home/kbz_8/Documents/Code/Zig/SPIRV-Interpreter/example/shader.spv" }, allocator);

    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;
    process.stdin_behavior = .Pipe;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    try process.spawn();
    errdefer {
        _ = process.kill() catch {};
    }

    _ = info;
    //try process.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    //if (process.stdin) |stdin| {
    //    _ = try stdin.write(@as([*]const u8, @ptrCast(info.p_code))[0..info.code_size]);
    //} else {
    //    std.log.scoped(.ShaderModule).err("Failed to disassemble SPIR-V module to readable text.", .{});
    //}
    _ = try process.wait();

    if (stderr.items.len != 0) {
        std.log.scoped(.ShaderModule).err("Failed to disassemble SPIR-V module to readable text.\n{s}", .{stderr.items});
    } else if (stdout.items.len != 0) {
        std.log.scoped(.ShaderModule).info("{s}\n{d}", .{ stdout.items, stdout.items.len });
    }
}
