const std = @import("std");
const shader_ir = @import("shader_ir");

const bc = @import("../bytecode.zig");
const Program = @import("../Program.zig");
const Runtime = @import("../Runtime.zig");
const copyWords = @import("slot_helpers.zig").copyWords;
const expectWords = @import("slot_helpers.zig").expectWords;

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
    copyWords(runtime.registers.slice(0, 4), &input);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try std.testing.expectEqual(@as(bc.Slot, 0), runtime.registers.at(4).*);
    try expectWords(&.{ 0, 32, 2, 12 }, runtime.registers.slice(5, 9));
    try expectWords(&.{ 0, 0xffff_ffff, 0x8000_0001, 0xe6a2_c480 }, runtime.registers.slice(9, 13));
}

test "[interpreter] signed and unsigned bit field operations use scalar ranges" {
    var code: std.ArrayList(bc.Instruction) = .empty;
    defer code.deinit(std.testing.allocator);

    const ranges = [_]struct { offset: u16, count: u16, unsigned: u16, signed: u16, inserted: u16 }{
        .{ .offset = 4, .count = 5, .unsigned = 6, .signed = 8, .inserted = 10 },
        .{ .offset = 12, .count = 13, .unsigned = 14, .signed = 18, .inserted = 16 },
    };
    for (ranges) |range| {
        for (0..2) |component_index| {
            const component: u16 = @intCast(component_index);
            try code.appendSlice(std.testing.allocator, &.{
                .{ .opcode = .integer_subtract, .a = reg(20), .b = reg(36), .c = reg(range.offset) },
                .{ .opcode = .compare_unsigned_less, .a = reg(21), .b = reg(20), .c = reg(range.count) },
                .{ .opcode = .compare_equal, .a = reg(22), .b = reg(range.count), .c = reg(38) },
                .{ .opcode = .logical_or, .a = reg(23), .b = reg(21), .c = reg(22) },
                .{ .opcode = .logical_not, .a = reg(23), .b = reg(23) },
                .{ .opcode = .bitwise_and, .a = reg(24), .b = reg(range.offset), .c = reg(40) },
                .{ .opcode = .integer_subtract, .a = reg(25), .b = reg(36), .c = reg(range.count) },
                .{ .opcode = .bitwise_and, .a = reg(25), .b = reg(25), .c = reg(40) },
                .{ .opcode = .logical_shift_right, .a = reg(26), .b = reg(39), .c = reg(25) },
                .{ .opcode = .select, .a = reg(26), .b = reg(22), .c = reg(38), .d = reg(26) },
                .{ .opcode = .logical_shift_right, .a = reg(27), .b = reg(component), .c = reg(24) },
                .{ .opcode = .bitwise_and, .a = reg(27), .b = reg(27), .c = reg(26) },
                .{ .opcode = .select, .a = reg(range.unsigned + component), .b = reg(23), .c = reg(27), .d = reg(38) },
                .{ .opcode = .shift_left, .a = reg(28), .b = reg(27), .c = reg(25) },
                .{ .opcode = .arithmetic_shift_right, .a = reg(28), .b = reg(28), .c = reg(25) },
                .{ .opcode = .select, .a = reg(range.signed + component), .b = reg(23), .c = reg(28), .d = reg(38) },
                .{ .opcode = .shift_left, .a = reg(29), .b = reg(26), .c = reg(24) },
                .{ .opcode = .bitwise_not, .a = reg(30), .b = reg(29) },
                .{ .opcode = .bitwise_and, .a = reg(30), .b = reg(component), .c = reg(30) },
                .{ .opcode = .shift_left, .a = reg(31), .b = reg(2 + component), .c = reg(24) },
                .{ .opcode = .bitwise_and, .a = reg(31), .b = reg(31), .c = reg(29) },
                .{ .opcode = .bitwise_or, .a = reg(31), .b = reg(30), .c = reg(31) },
                .{ .opcode = .select, .a = reg(range.inserted + component), .b = reg(23), .c = reg(31), .d = reg(component) },
            });
        }
    }
    try code.append(std.testing.allocator, .{ .opcode = .return_void });
    var program = bytecodeProgram(code.items, 41);
    defer program.deinit();

    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    runtime.registers.at(0).* = 0x0000_ff00;
    runtime.registers.at(1).* = 0x0000_8000;
    runtime.registers.at(2).* = 0x12;
    runtime.registers.at(3).* = 0x34;
    runtime.registers.at(4).* = 8;
    runtime.registers.at(5).* = 8;
    runtime.registers.at(12).* = 31;
    runtime.registers.at(13).* = 2;
    runtime.registers.at(36).* = 32;
    runtime.registers.at(38).* = 0;
    runtime.registers.at(39).* = 0xffff_ffff;
    runtime.registers.at(40).* = 31;

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try expectWords(&.{ 0xff, 0x80 }, runtime.registers.slice(6, 8));
    try expectWords(&.{ 0xffff_ffff, 0xffff_ff80 }, runtime.registers.slice(8, 10));
    try expectWords(&.{ 0x0000_1200, 0x0000_3400 }, runtime.registers.slice(10, 12));
    try expectWords(&.{ 0, 0 }, runtime.registers.slice(14, 16));
    try expectWords(&.{ 0x0000_ff00, 0x0000_8000 }, runtime.registers.slice(16, 18));
    try expectWords(&.{ 0, 0 }, runtime.registers.slice(18, 20));
}

test "[interpreter] carry borrow and extended multiply preserve structure layout" {
    const code = [_]bc.Instruction{
        .{ .opcode = .integer_add, .components = 2, .a = reg(16), .b = reg(0), .c = reg(2) },
        .{ .opcode = .compare_unsigned_less, .components = 2, .a = reg(18), .b = reg(16), .c = reg(0) },
        .{ .opcode = .integer_subtract, .components = 2, .a = reg(20), .b = reg(4), .c = reg(6) },
        .{ .opcode = .compare_unsigned_less, .components = 2, .a = reg(22), .b = reg(4), .c = reg(6) },
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
    copyWords(runtime.registers.slice(0, 16), &input);

    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    try expectWords(&.{ 0, 0, 1, 1 }, runtime.registers.slice(16, 20));
    try expectWords(&.{ 0xffff_ffff, 2, 1, 0 }, runtime.registers.slice(20, 24));
    try expectWords(&.{ 0xffff_fffe, 0, 1, 1 }, runtime.registers.slice(24, 28));
    try expectWords(&.{ 0, 1, 0xffff_ffff, 0 }, runtime.registers.slice(28, 32));
}

test "[interpreter] shared integer operations lower to bytecode" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    %zero: constant u32 = bits(0)
        \\    %one: constant u32 = bits(1)
        \\    %signed_one: constant i32 = bits(1)
        \\    %sign_shift: constant i32 = bits(31)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %counted: u32 = bit_count %one
        \\            %reversed: u32 = bit_reverse %one
        \\            %sum: u32 = integer_add %one, %one
        \\            %has_carry: bool = cmp_unsigned_less %sum, %one
        \\            %carry_bit: u32 = select %has_carry, %one, %zero
        \\            %carry: struct[u32, u32] = composite_construct %sum, %carry_bit
        \\            %difference: u32 = integer_subtract %zero, %one
        \\            %has_borrow: bool = cmp_unsigned_less %zero, %one
        \\            %borrow_bit: u32 = select %has_borrow, %one, %zero
        \\            %borrow: struct[u32, u32] = composite_construct %difference, %borrow_bit
        \\            %unsigned_product = unsigned_multiply_extended %one, %one
        \\            %signed_product = signed_multiply_extended %signed_one, %signed_one
        \\            %signed_shifted: i32 = shift_left %signed_one, %sign_shift
        \\            %signed_extract: i32 = arithmetic_shift_right %signed_shifted, %sign_shift
        \\            %unsigned_shifted: u32 = logical_shift_right %one, %zero
        \\            %unsigned_extract: u32 = bitwise_and %unsigned_shifted, %one
        \\            %inverse_mask: u32 = bitwise_not %one
        \\            %preserved: u32 = bitwise_and %zero, %inverse_mask
        \\            %insert_bits: u32 = bitwise_and %one, %one
        \\            %inserted: u32 = bitwise_or %preserved, %insert_bits
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    try @import("liveness.zig").makeResultsObservable(&module);
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();

    const expected = [_]bc.Opcode{
        .bit_count,
        .bit_reverse,
        .integer_add,
        .integer_subtract,
        .compare_unsigned_less,
        .select,
        .unsigned_multiply_extended,
        .signed_multiply_extended,
        .shift_left,
        .arithmetic_shift_right,
        .logical_shift_right,
        .bitwise_and,
        .bitwise_not,
        .bitwise_or,
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

test "[interpreter] mixed nested constants and constructs preserve typed extraction" {
    var module = ir.module.Module.init(std.testing.allocator, .compute);
    defer module.deinit();
    var builder = ir.Builder.init(&module);
    const void_type = try builder.internType(.void);
    const bool_type = try builder.internType(.boolean);
    const float_type = try builder.internType(.{ .floating = .{ .bits = 32 } });
    const signed_type = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .signed } });
    const unsigned_type = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });
    const child_type = try builder.internType(.{ .structure = .{ .members = &.{ float_type, signed_type, unsigned_type } } });
    const array_type = try builder.internType(.{ .array = .{ .element_type = child_type, .length = 2 } });
    const root_type = try builder.internType(.{ .structure = .{ .members = &.{ bool_type, array_type } } });
    const leaf_types = [_]ir.id.TypeId{ bool_type, float_type, signed_type, unsigned_type };
    const root_output = try builder.addInterfaceVariable(root_type, .output, .{ .location = .{ .location = 0 } }, "root");
    var leaf_outputs: [4]ir.id.InterfaceVariableId = undefined;
    for (leaf_types, 0..) |ty, index|
        leaf_outputs[index] = try builder.addInterfaceVariable(ty, .output, .{ .location = .{ .location = @intCast(index + 1) } }, null);

    const flag = try builder.internConstant(bool_type, .{ .boolean = true });
    const float = try builder.internConstant(float_type, .{ .float_bits = 0x3fc00000 });
    const signed = try builder.internConstant(signed_type, .{ .integer_bits = 0xfffffffe });
    const unsigned = try builder.internConstant(unsigned_type, .{ .integer_bits = 0xdeadbeef });
    const child_elements = [_]ir.id.ValueId{ float, signed, unsigned };
    var child_constants: [3]ir.id.ConstantId = undefined;
    for (child_elements, 0..) |value, index|
        child_constants[index] = module.values.get(value).?.definition.constant;
    const child = try builder.internConstant(child_type, .{ .composite = &child_constants });
    const child_constant = module.values.get(child).?.definition.constant;
    const array = try builder.internConstant(array_type, .{ .composite = &.{ child_constant, child_constant } });
    const constant_root = try builder.internConstant(root_type, .{ .composite = &.{ module.values.get(flag).?.definition.constant, module.values.get(array).?.definition.constant } });

    const function = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(function);
    const block = try builder.addBlock(function, "entry");
    const constructed_child = (try builder.appendInstruction(block, child_type, .{ .composite_construct = .{ .elements = &child_elements } }, null)).?;
    const constructed_array = (try builder.appendInstruction(block, array_type, .{ .composite_construct = .{ .elements = &.{ child, constructed_child } } }, null)).?;
    const constructed_root = (try builder.appendInstruction(block, root_type, .{ .composite_construct = .{ .elements = &.{ flag, constructed_array } } }, null)).?;
    const selected = (try builder.appendInstruction(block, root_type, .{ .select = .{ .condition = flag, .true_value = constructed_root, .false_value = constant_root } }, null)).?;
    const paths = [_][]const u32{ &.{0}, &.{ 1, 1, 0 }, &.{ 1, 1, 1 }, &.{ 1, 1, 2 } };
    for (leaf_types, paths, leaf_outputs, 0..) |ty, path, output, index| {
        const leaf = (try builder.appendInstruction(block, ty, .{ .composite_extract = .{ .composite = if (index < 2) constant_root else selected, .indices = path } }, null)).?;
        _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = output, .value = leaf } }, null);
    }
    _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = root_output, .value = selected } }, null);
    try builder.setTerminator(block, .return_void);
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    try std.testing.expectEqual(bc.ValueKind.mixed, program.interfaces[0].?.span.kind);
    try std.testing.expectEqual(@as(u8, 7), program.interfaces[0].?.span.components);
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    var root: [7]u32 = undefined;
    try runtime.readOutput(&program, ir.id.InterfaceVariableId.fromIndex(0), &root);
    try std.testing.expectEqualSlices(u32, &.{ 1, 0x3fc00000, 0xfffffffe, 0xdeadbeef, 0x3fc00000, 0xfffffffe, 0xdeadbeef }, &root);
    var leaves: [4]u32 = undefined;
    for (leaf_outputs, 0..) |output, index| {
        try std.testing.expectEqual(([_]bc.ValueKind{ .boolean, .floating, .signed_integer, .unsigned_integer })[index], program.interfaceBinding(output).?.span.kind);
        try runtime.readOutput(&program, output, leaves[index..][0..1]);
    }
    try std.testing.expectEqualSlices(u32, &.{ 1, 0x3fc00000, 0xfffffffe, 0xdeadbeef }, &leaves);
}

test "[interpreter] mixed aggregates branch select and swap block arguments in parallel" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    @condition: bool = input[location(0), component(0), index(0)]
        \\    @output: struct[f32, u32] = output[location(0), component(0), index(0)]
        \\    %f1: constant f32 = bits(0x3f800000)
        \\    %f2: constant f32 = bits(0x40000000)
        \\    %one: constant u32 = 1
        \\    %two: constant u32 = 2
        \\    %zero: constant u32 = 0
        \\    %first: constant struct[f32, u32] = [#0, #2]
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %condition: bool = load_interface @condition
        \\            %second: struct[f32, u32] = composite_construct %f2, %two
        \\            conditional_branch %condition, .yes(), .no()
        \\        .yes():
        \\            branch .loop(%first, %second, %zero)
        \\        .no():
        \\            branch .loop(%second, %first, %zero)
        \\        .loop(%a: struct[f32, u32], %b: struct[f32, u32], %index: u32):
        \\            %continue: bool = cmp_unsigned_less %index, %one
        \\            conditional_branch %continue, .body(), .exit()
        \\        .body():
        \\            %next: u32 = integer_add %index, %one
        \\            branch .loop(%b, %a, %next)
        \\        .exit():
        \\            %selected: struct[f32, u32] = select %condition, %a, %b
        \\            store_interface @output, %selected
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    try std.testing.expectEqual(bc.ValueKind.mixed, program.interfaces[1].?.span.kind);
    try std.testing.expect(program.scratch_count >= 4);
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    for ([_]u32{ 0, 1 }) |condition| {
        runtime.resetInvocation(&program);
        try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(0), &.{condition});
        try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
        var output: [2]u32 = undefined;
        try runtime.readOutput(&program, ir.id.InterfaceVariableId.fromIndex(1), &output);
        try std.testing.expectEqualSlices(u32, &.{ 0x40000000, 2 }, &output);
    }
}

test "[interpreter] mixed aggregate component counts remain checked" {
    const sources = [_][]const u8{
        \\shader compute @main
        \\{
        \\    %large: constant struct[array[u32, 255], f32] = null
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            return
        \\    }
        \\}
        ,
        \\shader compute @main
        \\{
        \\    %large: constant array[struct[u32, f32], 128] = null
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            return
        \\    }
        \\}
        ,
    };
    for (sources) |source| {
        var module = try ir.parser.parseString(std.testing.allocator, source);
        defer module.deinit();
        var builder = ir.Builder.init(&module);
        const value = module.values.get(ir.id.ValueId.fromIndex(0)).?;
        _ = try builder.addInterfaceVariable(value.type, .output, .{ .location = .{ .location = 0 } }, null);
        try std.testing.expectError(Program.CompileError.UnsupportedType, Program.compile(std.testing.allocator, &module));
    }
}

test "[interpreter] scalar unary arithmetic does not interpret mixed spans" {
    for ([_]ir.instruction.UnaryOpcode{ .bit_count, .bit_reverse, .negate }) |opcode| {
        var module = ir.module.Module.init(std.testing.allocator, .compute);
        defer module.deinit();
        var builder = ir.Builder.init(&module);
        const void_type = try builder.internType(.void);
        const float_type = try builder.internType(.{ .floating = .{ .bits = 32 } });
        const uint_type = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });
        const mixed_type = try builder.internType(.{ .structure = .{ .members = &.{ float_type, uint_type } } });
        const value = try builder.internConstant(mixed_type, .null);
        const function = try builder.addFunction(void_type, "main");
        builder.setEntryPoint(function);
        const block = try builder.addBlock(function, "entry");
        _ = try builder.appendInstruction(block, mixed_type, .{ .unary = .{ .opcode = opcode, .operand = value } }, null);
        try @import("liveness.zig").makeResultsObservable(&module);
        try builder.setTerminator(block, .return_void);
        // Bypass typed IR validation to exercise the lowerer's own scalar-kind guard.
        module.properties.valid_cfg = true;
        module.properties.valid_ssa = true;
        try std.testing.expectError(Program.CompileError.InvalidOperation, Program.compile(std.testing.allocator, &module));
    }
}

test "[interpreter] inlined function mixed return bundle executes with typed members" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    @output: vec2[u32] = output[location(0), component(0), index(0)]
        \\    %float: constant f32 = bits(0x3fc00000)
        \\    %uint: constant u32 = bits(0xdeadbeef)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %bundle: struct[f32, u32] = call @helper(%float, %uint)
        \\            %f: f32 = composite_extract %bundle[0]
        \\            %u: u32 = composite_extract %bundle[1]
        \\            %bits: u32 = bitcast %f
        \\            %words: vec2[u32] = composite_construct %bits, %u
        \\            store_interface @output, %words
        \\            return
        \\    }
        \\    fn @helper(%f_arg: f32, %u_arg: u32) -> struct[f32, u32]
        \\    {
        \\        .entry():
        \\            %result: struct[f32, u32] = composite_construct %f_arg, %u_arg
        \\            return %result
        \\    }
        \\}
    );
    defer module.deinit();
    var manager = ir.transformer_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.add(ir.inline_all_functions.transformer);
    var context: ir.transformer_manager.Context = .{ .allocator = std.testing.allocator };
    try std.testing.expect(try manager.run(&module, &context));
    try ir.validator.validate(&module);
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    var output: [2]u32 = undefined;
    try runtime.readOutput(&program, ir.id.InterfaceVariableId.fromIndex(0), &output);
    try std.testing.expectEqualSlices(u32, &.{ 0x3fc00000, 0xdeadbeef }, &output);
}
