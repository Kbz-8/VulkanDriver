const std = @import("std");
const base = @import("base");
const shader_ir = @import("shader_ir");

const Program = @import("Program.zig");
const Runtime = @import("Runtime.zig");

const VkError = base.VkError;
const ir = shader_ir.ir;

pub const RuntimeSlot = struct {
    mutex: std.Io.Mutex = .init,
    runtime: Runtime,
};

const Self = @This();

program: Program,
runtimes: []RuntimeSlot,
workgroup_size: ?[3]u32,
early_fragment_tests: bool = false,

pub fn compile(allocator: std.mem.Allocator, module: *const ir.module.Module, runtime_count: usize) VkError!Self {
    const expected_stage = module.stage;

    var program = Program.compile(allocator, module) catch |err| {
        if (err == error.OutOfMemory)
            return VkError.OutOfDeviceMemory;
        std.log.scoped(.IrInterpreter).err("bytecode lowering failed: {s}", .{@errorName(err)});
        return VkError.ValidationFailed;
    };
    errdefer program.deinit();

    if (!hasCompatibleInterface(&program, expected_stage)) {
        std.log.scoped(.IrInterpreter).err("unsupported stage interface or execution modes", .{});
        return VkError.ValidationFailed;
    }

    const runtimes = allocator.alloc(RuntimeSlot, runtime_count) catch return VkError.OutOfDeviceMemory;
    var initialized: usize = 0;
    errdefer {
        for (runtimes[0..initialized]) |*slot|
            slot.runtime.deinit();
        allocator.free(runtimes);
    }
    for (runtimes) |*slot| {
        slot.* = .{ .runtime = Runtime.init(allocator, &program) catch return VkError.OutOfDeviceMemory };
        initialized += 1;
    }

    std.log.scoped(.IrInterpreter).debug("compiled {s} stage to {d} bytecode instructions", .{
        @tagName(expected_stage),
        program.code.len,
    });
    return .{
        .program = program,
        .runtimes = runtimes,
        .workgroup_size = module.execution_modes.workgroup_size,
        .early_fragment_tests = module.execution_modes.early_fragment_tests,
    };
}

pub fn deinit(self: *Self) void {
    for (self.runtimes) |*slot|
        slot.runtime.deinit();
    self.program.deinit();
    self.* = undefined;
}

fn hasCompatibleInterface(program: *const Program, stage: ir.module.Stage) bool {
    var has_position = false;
    for (program.interfaces) |optional_binding| {
        const binding = optional_binding orelse continue;
        switch (binding.semantic) {
            .location => |location| {
                if (stage == .compute or location.index != 0 or
                    @as(u16, location.component) + binding.span.components > 4)
                    return false;
            },
            .builtin => |builtin| switch (stage) {
                .vertex => switch (builtin) {
                    .vertex_index, .instance_index => if (binding.direction != .input) return false,
                    .position => {
                        if (binding.direction != .output or binding.span.kind != .floating or binding.span.components != 4)
                            return false;
                        has_position = true;
                    },
                    .point_size => if (binding.direction != .output or binding.span.kind != .floating or binding.span.components != 1)
                        return false,
                    else => return false,
                },
                .compute => switch (builtin) {
                    .device_index => return true,
                    .global_invocation_id,
                    .local_invocation_id,
                    .workgroup_id,
                    .num_workgroups,
                    .workgroup_size,
                    => if (binding.direction != .input or binding.span.kind != .unsigned_integer or binding.span.components != 3)
                        return false,
                    .local_invocation_index => if (binding.direction != .input or binding.span.kind != .unsigned_integer or binding.span.components != 1)
                        return false,
                    else => return false,
                },
                .fragment => switch (builtin) {
                    .frag_coord => if (binding.direction != .input or binding.span.kind != .floating or binding.span.components != 4)
                        return false,
                    .frag_depth => if (binding.direction != .output or binding.span.kind != .floating or binding.span.components != 1)
                        return false,
                    else => return false,
                },
            },
        }
    }
    return stage != .vertex or has_position;
}

test "IR interpreter accepts scalar vertex PointSize output" {
    var module = ir.module.Module.init(std.testing.allocator, .vertex);
    defer module.deinit();
    var builder = ir.Builder.init(&module);
    const void_type = try builder.internType(.void);
    const float_type = try builder.internType(.{ .floating = .{ .bits = 32 } });
    const vec4_type = try builder.internType(.{ .vector = .{ .element_type = float_type, .length = 4 } });
    _ = try builder.addInterfaceVariable(vec4_type, .output, .{ .builtin = .position }, "position");
    _ = try builder.addInterfaceVariable(float_type, .output, .{ .builtin = .point_size }, "point_size");
    const function = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(function);
    const block = try builder.addBlock(function, "entry");
    try builder.setTerminator(block, .return_void);

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    try std.testing.expect(hasCompatibleInterface(&program, .vertex));
}
