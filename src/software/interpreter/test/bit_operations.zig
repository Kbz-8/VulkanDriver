const std = @import("std");
const shader_ir = @import("shader_ir");

const bc = @import("../bytecode.zig");
const Program = @import("../Program.zig");
const Runtime = @import("../Runtime.zig");

const ir = shader_ir.ir;

inline fn reg(index: u16) bc.Register {
    return @fromBackingInt(index);
}

fn bytecodeProgram(code: []const bc.Instruction, register_count: usize) Program {
    return .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .stage = .compute,
        .uses_atomics = false,
        .uses_control_barriers = false,
        .workgroup_memory_size = 0,
        .entry_pc = 0,
        .register_count = register_count,
        .scratch_count = 0,
        .array_lengths = &.{},
        .descriptor_arrays = &.{},
        .image_sampler_pairs = &.{},
        .code = code,
        .edges = &.{},
        .copies = &.{},
        .branches = &.{},
        .initializers = &.{},
        .interfaces = &.{},
        .resources = &.{},
        .workgroup_variables = &.{},
    };
}

test "[interpreter] bit count and reverse scalar and vector edge values" {
    const code = [_]bc.Instruction{
        .{ .opcode = .bit_count, .components = 1, .a = reg(4), .b = reg(0) },
        .{ .opcode = .bit_count, .components = 4, .a = reg(5), .b = reg(0) },
        .{ .opcode = .bit_reverse, .components = 4, .a = reg(9), .b = reg(0) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 13);
    defer program.deinit();

    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    const input = [_]u32{ 0, 0xffff_ffff, 0x8000_0001, 0x0123_4567 };
    @memcpy(runtime.registers[0..4], &input);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqual(@as(u32, 0), runtime.registers[4]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 32, 2, 12 }, runtime.registers[5..9]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0xffff_ffff, 0x8000_0001, 0xe6a2_c480 }, runtime.registers[9..13]);
}

test "[interpreter] signed and unsigned bit field operations use scalar ranges" {
    const code = [_]bc.Instruction{
        .{ .opcode = .bit_field_extract_unsigned, .components = 2, .a = reg(6), .b = reg(0), .c = reg(4), .d = reg(5) },
        .{ .opcode = .bit_field_extract_signed, .components = 2, .a = reg(8), .b = reg(0), .c = reg(4), .d = reg(5) },
        .{ .opcode = .bit_field_insert, .components = 2, .a = reg(10), .b = reg(0), .c = reg(2), .d = reg(4), .immediate = @backingInt(reg(5)) },
        .{ .opcode = .bit_field_extract_unsigned, .components = 2, .a = reg(14), .b = reg(0), .c = reg(12), .d = reg(13) },
        .{ .opcode = .bit_field_insert, .components = 2, .a = reg(16), .b = reg(0), .c = reg(2), .d = reg(12), .immediate = @backingInt(reg(13)) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 18);
    defer program.deinit();

    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    runtime.registers[0] = 0x0000_ff00;
    runtime.registers[1] = 0x0000_8000;
    runtime.registers[2] = 0x12;
    runtime.registers[3] = 0x34;
    runtime.registers[4] = 8;
    runtime.registers[5] = 8;
    runtime.registers[12] = 31;
    runtime.registers[13] = 2;

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqualSlices(u32, &.{ 0xff, 0x80 }, runtime.registers[6..8]);
    try std.testing.expectEqualSlices(u32, &.{ 0xffff_ffff, 0xffff_ff80 }, runtime.registers[8..10]);
    try std.testing.expectEqualSlices(u32, &.{ 0x0000_1200, 0x0000_3400 }, runtime.registers[10..12]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0 }, runtime.registers[14..16]);
    try std.testing.expectEqualSlices(u32, runtime.registers[0..2], runtime.registers[16..18]);
}

test "[interpreter] carry borrow and extended multiply preserve structure layout" {
    const code = [_]bc.Instruction{
        .{ .opcode = .integer_add_carry, .components = 2, .a = reg(16), .b = reg(0), .c = reg(2) },
        .{ .opcode = .integer_subtract_borrow, .components = 2, .a = reg(20), .b = reg(4), .c = reg(6) },
        .{ .opcode = .unsigned_multiply_extended, .components = 2, .a = reg(24), .b = reg(8), .c = reg(10) },
        .{ .opcode = .signed_multiply_extended, .components = 2, .a = reg(28), .b = reg(12), .c = reg(14) },
        .{ .opcode = .return_void },
    };
    var program = bytecodeProgram(&code, 32);
    defer program.deinit();

    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    const input = [_]u32{
        0xffff_ffff, 0x8000_0000, 1, 0x8000_0000,
        0,           5,           1, 3,
        0xffff_ffff, 0x8000_0000, 2, 2,
        0x8000_0000, 0xffff_ffff, 2, 0xffff_ffff,
    };
    @memcpy(runtime.registers[0..16], &input);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 1, 1 }, runtime.registers[16..20]);
    try std.testing.expectEqualSlices(u32, &.{ 0xffff_ffff, 2, 1, 0 }, runtime.registers[20..24]);
    try std.testing.expectEqualSlices(u32, &.{ 0xffff_fffe, 0, 1, 1 }, runtime.registers[24..28]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 0xffff_ffff, 0 }, runtime.registers[28..32]);
}

test "[interpreter] shared integer operations lower to bytecode" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    %zero: constant u32 = bits(0)
        \\    %one: constant u32 = bits(1)
        \\    %signed_one: constant i32 = bits(1)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %counted: u32 = bit_count %one
        \\            %reversed: u32 = bit_reverse %one
        \\            %carry = integer_add_carry %one, %one
        \\            %borrow = integer_subtract_borrow %zero, %one
        \\            %unsigned_product = unsigned_multiply_extended %one, %one
        \\            %signed_product = signed_multiply_extended %signed_one, %signed_one
        \\            %signed_extract: i32 = bit_field_extract signed %signed_one, %zero, %one
        \\            %unsigned_extract: u32 = bit_field_extract unsigned %one, %zero, %one
        \\            %inserted: u32 = bit_field_insert %zero, %one, %zero, %one
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();

    const expected = [_]bc.Opcode{
        .bit_count,
        .bit_reverse,
        .integer_add_carry,
        .integer_subtract_borrow,
        .unsigned_multiply_extended,
        .signed_multiply_extended,
        .bit_field_extract_signed,
        .bit_field_extract_unsigned,
        .bit_field_insert,
    };
    var found: [expected.len]bool = @splat(false);
    for (program.code) |instruction| {
        for (expected, 0..) |opcode, index| {
            if (instruction.opcode == opcode)
                found[index] = true;
        }
    }
    for (found) |present|
        try std.testing.expect(present);
}

test "[interpreter] homogeneous structures flatten and extract by member shape" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    @output: vec2[u32] = output[location(0), component(0), index(0)]
        \\    %one: constant u32 = bits(1)
        \\    %two: constant u32 = bits(2)
        \\    %three: constant u32 = bits(3)
        \\    %four: constant u32 = bits(4)
        \\    %five: constant u32 = bits(5)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %pair: vec2[u32] = composite_construct %one, %two
        \\            %nested_pair: vec2[u32] = composite_construct %three, %four
        \\            %nested: struct[vec2[u32], u32] = composite_construct %nested_pair, %five
        \\            %root: struct[u32, vec2[u32], struct[vec2[u32], u32]] = composite_construct %one, %pair, %nested
        \\            %extracted: vec2[u32] = composite_extract %root[2][0]
        \\            store_interface @output, %extracted
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();

    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    var output: [2]u32 = undefined;
    try runtime.readOutput(&program, ir.id.InterfaceVariableId.fromIndex(0), &output);
    try std.testing.expectEqualSlices(u32, &.{ 3, 4 }, &output);
}
