const std = @import("std");
const shader_ir = @import("shader_ir").ir;
const device = @import("device.zig");
const program_ir = @import("program.zig");

pub const Options = struct {
    dispatch_width: device.DispatchWidth = .simd8,
};

pub const Error = std.mem.Allocator.Error || error{
    MissingEntryPoint,
    InvalidEntryPoint,
    UnsupportedGeneration,
    UnsupportedStage,
    UnsupportedDispatchWidth,
    UnsupportedType,
    UnsupportedOperation,
    UnsupportedTerminator,
    LoweringNotImplemented,
};

pub const Lowerer = struct {
    allocator: std.mem.Allocator,
    module: *const shader_ir.module.Module,
    device_info: device.DeviceInfo,
    options: Options,

    pub fn init(
        allocator: std.mem.Allocator,
        module: *const shader_ir.module.Module,
        device_info: device.DeviceInfo,
        options: Options,
    ) Lowerer {
        return .{
            .allocator = allocator,
            .module = module,
            .device_info = device_info,
            .options = options,
        };
    }

    pub fn lower(self: *Lowerer) Error!program_ir.Program {
        var program = program_ir.Program.init(self.allocator, self.module.stage, self.device_info, self.options.dispatch_width);
        errdefer program.deinit();

        const entry_point = self.source.entryPoint(self.module.stage);
        if (entry_point) |ep| {
            program.entry_block = try program.addBlock(ep.name);
            _ = program.appendInstruction(program.entry_block orelse return error.InvalidBlock, self.options.dispatch_width, null, .{ .name = ep.name });
        }

        const blocks = self.source.blocks();
        for (blocks) |block| {
            const block_id = try program.addBlock(block.name);
            for (block.instructions) |inst| {
                _ = program.appendInstruction(block_id, self.options.dispatch_width, null, .{ .name = inst.name });
            }
            _ = program.setTerminator(block_id, .{ .name = block.terminator.name });
        }

        return program;
    }
};

/// Convenience entry point for callers that do not need to retain a lowerer.
pub inline fn lower(
    allocator: std.mem.Allocator,
    module: *const shader_ir.module.Module,
    device_info: device.DeviceInfo,
    options: Options,
) Error!program_ir.Program {
    var lowerer = Lowerer.init(allocator, module, device_info, options);
    return lowerer.lower();
}
