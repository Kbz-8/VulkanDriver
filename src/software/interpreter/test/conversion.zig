const std = @import("std");
const shader_ir = @import("shader_ir");

const bc = @import("../bytecode.zig");
const Program = @import("../Program.zig");
const Runtime = @import("../Runtime.zig");

fn reg(index: u16) bc.Register {
    return @enumFromInt(index);
}

fn f32Bits(value: f32) u32 {
    return @bitCast(value);
}

fn makeProgram(code: []const bc.Instruction, initializers: []const Program.RegisterInit) Program {
    const resources = struct {
        const bindings = [_]?Program.ResourceBinding{
            .{ .kind = .storage_buffer, .set = 0, .binding = 0, .array_element = 0 },
        };
    };

    return .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .stage = .compute,
        .uses_atomics = false,
        .uses_control_barriers = false,
        .workgroup_memory_size = 0,
        .entry_pc = 0,
        .register_count = 18,
        .scratch_count = 0,
        .array_lengths = &.{},
        .descriptor_arrays = &.{},
        .image_sampler_pairs = &.{},
        .code = code,
        .edges = &.{},
        .copies = &.{},
        .branches = &.{},
        .initializers = initializers,
        .interfaces = &.{},
        .resources = &resources.bindings,
        .workgroup_variables = &.{},
    };
}

test "[interpreter] integer-to-float conversions lower component-wise" {
    var module = try shader_ir.ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    %signed: constant vec2[i32] = null
        \\    %unsigned: constant vec3[u32] = null
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %signed_result: vec2[f32] = convert signed_to_float %signed
        \\            %unsigned_result: vec3[f32] = convert unsigned_to_float %unsigned
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();

    try std.testing.expectEqual(bc.Opcode.signed_to_float, program.code[0].opcode);
    try std.testing.expectEqual(@as(u16, 2), program.code[0].components);
    try std.testing.expectEqual(bc.Opcode.unsigned_to_float, program.code[1].opcode);
    try std.testing.expectEqual(@as(u16, 3), program.code[1].components);
}

test "[interpreter] signed and unsigned integer vectors convert to float" {
    const code = [_]bc.Instruction{
        .{ .opcode = .signed_to_float, .components = 4, .a = reg(8), .b = reg(0) },
        .{ .opcode = .unsigned_to_float, .components = 4, .a = reg(12), .b = reg(4) },
        .{ .opcode = .store_buffer, .components = 4, .a = reg(8), .b = reg(16), .immediate = 0 },
        .{ .opcode = .store_buffer, .components = 4, .a = reg(12), .b = reg(17), .immediate = 0 },
        .{ .opcode = .return_void },
    };
    const initializers = [_]Program.RegisterInit{
        .{ .register = reg(0), .value = @bitCast(@as(i32, -2)) },
        .{ .register = reg(1), .value = @bitCast(@as(i32, 0)) },
        .{ .register = reg(2), .value = @bitCast(@as(i32, 17)) },
        .{ .register = reg(3), .value = @bitCast(@as(i32, std.math.minInt(i32))) },
        .{ .register = reg(4), .value = 0 },
        .{ .register = reg(5), .value = 1 },
        .{ .register = reg(6), .value = 42 },
        .{ .register = reg(7), .value = std.math.maxInt(u32) },
        .{ .register = reg(16), .value = 0 },
        .{ .register = reg(17), .value = 16 },
    };

    var program = makeProgram(&code, &initializers);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    var output = [_]u8{0} ** 32;
    const resource_buffers = [_]?[]u8{output[0..]};
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{
        .resource_buffers = &resource_buffers,
    }));

    const expected = [_]u32{
        f32Bits(-2.0),
        f32Bits(0.0),
        f32Bits(17.0),
        f32Bits(@floatFromInt(std.math.minInt(i32))),
        f32Bits(0.0),
        f32Bits(1.0),
        f32Bits(42.0),
        f32Bits(@floatFromInt(std.math.maxInt(u32))),
    };
    for (expected, 0..) |value, index| {
        const offset = index * @sizeOf(u32);
        try std.testing.expectEqual(value, std.mem.readInt(u32, output[offset..][0..@sizeOf(u32)], .little));
    }
}
