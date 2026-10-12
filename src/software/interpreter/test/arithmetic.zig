const std = @import("std");
const shader_ir = @import("shader_ir");

const bc = @import("../bytecode.zig");
const Program = @import("../Program.zig");
const Runtime = @import("../Runtime.zig");

const ir = shader_ir.ir;

fn f32Bits(value: f32) u32 {
    return @bitCast(value);
}

fn bitsF32(value: u32) f32 {
    return @bitCast(value);
}

test "[interpreter] vector float arithmetic" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\ shader vertex @main
        \\ {
        \\     @lhs: vec4[f32] = input[location(0), component(0), index(0)]
        \\     @rhs: vec4[f32] = input[location(1), component(0), index(0)]
        \\     @output: vec4[f32] = output[location(0), component(0), index(0)]
        \\
        \\     fn @main() -> void
        \\     {
        \\         .entry():
        \\             %lhs_value: vec4[f32] = load_interface @lhs
        \\             %rhs_value: vec4[f32] = load_interface @rhs
        \\             %product: vec4[f32] = float_multiply %lhs_value, %rhs_value
        \\             store_interface @output, %product
        \\             return
        \\     }
        \\ }
    );
    defer module.deinit();

    const lhs = ir.id.InterfaceVariableId.fromIndex(0);
    const rhs = ir.id.InterfaceVariableId.fromIndex(1);
    const output = ir.id.InterfaceVariableId.fromIndex(2);

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    try runtime.writeInput(&program, lhs, &.{ f32Bits(2), f32Bits(-3), f32Bits(0.5), f32Bits(8) });
    try runtime.writeInput(&program, rhs, &.{ f32Bits(4), f32Bits(2), f32Bits(6), f32Bits(0.25) });
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));

    var result: [4]u32 = undefined;
    try runtime.readOutput(&program, output, &result);
    const expected = [_]f32{ 8, -6, 3, 2 };
    for (result, expected) |actual, wanted|
        try std.testing.expectEqual(wanted, bitsF32(actual));
}

test "[interpreter] native-width SIMD wave executes every lane" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    @lhs: f32 = input[location(0), component(0), index(0)]
        \\    @rhs: f32 = input[location(1), component(0), index(0)]
        \\    @output: f32 = output[location(0), component(0), index(0)]
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %lhs_value: f32 = load_interface @lhs
        \\            %rhs_value: f32 = load_interface @rhs
        \\            %sum: f32 = float_add %lhs_value, %rhs_value
        \\            store_interface @output, %sum
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    const lhs = ir.id.InterfaceVariableId.fromIndex(0);
    const rhs = ir.id.InterfaceVariableId.fromIndex(1);
    const output = ir.id.InterfaceVariableId.fromIndex(2);

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    runtime.resetWave(&program, Runtime.full_lane_mask, Runtime.full_lane_mask);

    for (0..Runtime.lane_count) |lane| {
        const lhs_value: f32 = @floatFromInt(lane);
        const rhs_value: f32 = @floatFromInt(lane * 2);
        try runtime.writeInputLane(&program, lane, lhs, &.{f32Bits(lhs_value)});
        try runtime.writeInputLane(&program, lane, rhs, &.{f32Bits(rhs_value)});
    }

    const outcome = try runtime.runWave(&program, .{});
    try std.testing.expectEqual(Runtime.full_lane_mask, outcome.returned_mask);
    try std.testing.expectEqual(Runtime.lane_count, @popCount(outcome.returned_mask));
    for (0..Runtime.lane_count) |lane| {
        var result: [1]u32 = undefined;
        try runtime.readOutputLane(&program, lane, output, &result);
        try std.testing.expectEqual(@as(f32, @floatFromInt(lane * 3)), bitsF32(result[0]));
    }
}

test "[interpreter] matrix arithmetic uses column-major dimensions" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    @lhs: mat2x3[f32] = input[location(0), component(0), index(0)]
        \\    @rhs: mat4x2[f32] = input[location(1), component(0), index(0)]
        \\    @scalar: f32 = input[location(2), component(0), index(0)]
        \\    @columns: vec2[f32] = input[location(3), component(0), index(0)]
        \\    @rows: vec3[f32] = input[location(4), component(0), index(0)]
        \\    @scaled: mat2x3[f32] = output[location(0), component(0), index(0)]
        \\    @matrix_vector: vec3[f32] = output[location(1), component(0), index(0)]
        \\    @vector_matrix: vec2[f32] = output[location(2), component(0), index(0)]
        \\    @matrix_matrix: mat4x3[f32] = output[location(3), component(0), index(0)]
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %lhs_value: mat2x3[f32] = load_interface @lhs
        \\            %rhs_value: mat4x2[f32] = load_interface @rhs
        \\            %scalar_value: f32 = load_interface @scalar
        \\            %columns_value: vec2[f32] = load_interface @columns
        \\            %rows_value: vec3[f32] = load_interface @rows
        \\            %scaled_value: mat2x3[f32] = matrix_times_scalar %lhs_value, %scalar_value
        \\            %matrix_vector_value: vec3[f32] = matrix_times_vector %lhs_value, %columns_value
        \\            %vector_matrix_value: vec2[f32] = vector_times_matrix %rows_value, %lhs_value
        \\            %matrix_matrix_value: mat4x3[f32] = matrix_times_matrix %lhs_value, %rhs_value
        \\            store_interface @scaled, %scaled_value
        \\            store_interface @matrix_vector, %matrix_vector_value
        \\            store_interface @vector_matrix, %vector_matrix_value
        \\            store_interface @matrix_matrix, %matrix_matrix_value
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(0), &.{ f32Bits(1), f32Bits(2), f32Bits(3), f32Bits(4), f32Bits(5), f32Bits(6) });
    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(1), &.{ f32Bits(1), f32Bits(2), f32Bits(3), f32Bits(4), f32Bits(5), f32Bits(6), f32Bits(7), f32Bits(8) });
    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(2), &.{f32Bits(2)});
    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(3), &.{ f32Bits(10), f32Bits(20) });
    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(4), &.{ f32Bits(7), f32Bits(8), f32Bits(9) });
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));

    const expected = [_][]const f32{
        &.{ 2, 4, 6, 8, 10, 12 },
        &.{ 90, 120, 150 },
        &.{ 50, 122 },
        &.{ 9, 12, 15, 19, 26, 33, 29, 40, 51, 39, 54, 69 },
    };
    for (expected, 5..) |wanted, output_index| {
        var result: [12]u32 = undefined;
        try runtime.readOutput(&program, ir.id.InterfaceVariableId.fromIndex(output_index), result[0..wanted.len]);
        for (result[0..wanted.len], wanted) |actual, value|
            try std.testing.expectEqual(value, bitsF32(actual));
    }
}

test "[interpreter] vector times scalar broadcasts" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    @vector: vec4[f32] = input[location(0), component(0), index(0)]
        \\    @scalar: f32 = input[location(1), component(0), index(0)]
        \\    @output: vec4[f32] = output[location(0), component(0), index(0)]
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %vector_value: vec4[f32] = load_interface @vector
        \\            %scalar_value: f32 = load_interface @scalar
        \\            %product: vec4[f32] = vector_times_scalar %vector_value, %scalar_value
        \\            store_interface @output, %product
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(0), &.{ f32Bits(2), f32Bits(-3), f32Bits(0.5), f32Bits(8) });
    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(1), &.{f32Bits(4)});
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));

    var result: [4]u32 = undefined;
    try runtime.readOutput(&program, ir.id.InterfaceVariableId.fromIndex(2), &result);
    const expected = [_]f32{ 8, -12, 2, 32 };
    for (result, expected) |actual, wanted|
        try std.testing.expectEqual(wanted, bitsF32(actual));
}

test "[interpreter] mixed nested constants and construction preserve raw words and scalar arithmetic" {
    var module = ir.module.Module.init(std.testing.allocator, .compute);
    defer module.deinit();
    var builder = ir.Builder.init(&module);
    const void_type = try builder.internType(.void);
    const float_type = try builder.internType(.{ .floating = .{ .bits = 32 } });
    const signed_type = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .signed } });
    const bool_type = try builder.internType(.boolean);
    const unsigned_type = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });
    const child_types = [_]ir.id.TypeId{ float_type, signed_type, bool_type };
    const child_type = try builder.internType(.{ .structure = .{ .members = &child_types } });
    const array_type = try builder.internType(.{ .array = .{ .element_type = child_type, .length = 2 } });
    const root_type = try builder.internType(.{ .structure = .{ .members = &.{ array_type, unsigned_type } } });
    const words_type = try builder.internType(.{ .array = .{ .element_type = unsigned_type, .length = 7 } });
    const arithmetic_type = try builder.internType(.{ .vector = .{ .element_type = unsigned_type, .length = 4 } });
    var inputs: [3]ir.id.InterfaceVariableId = undefined;
    for (child_types, 0..) |ty, index|
        inputs[index] = try builder.addInterfaceVariable(ty, .input, .{ .location = .{ .location = @intCast(index) } }, null);
    const constant_output = try builder.addInterfaceVariable(words_type, .output, .{ .location = .{ .location = 0 } }, null);
    const constructed_output = try builder.addInterfaceVariable(words_type, .output, .{ .location = .{ .location = 1 } }, null);
    const arithmetic_output = try builder.addInterfaceVariable(arithmetic_type, .output, .{ .location = .{ .location = 2 } }, null);

    const f0 = try builder.internConstant(float_type, .{ .float_bits = f32Bits(1.5) });
    const signed_first = try builder.internConstant(signed_type, .{ .integer_bits = 0xfffffff7 });
    const true_value = try builder.internConstant(bool_type, .{ .boolean = true });
    const f1 = try builder.internConstant(float_type, .{ .float_bits = f32Bits(-2.25) });
    const signed_second = try builder.internConstant(signed_type, .{ .integer_bits = 0xfffffff9 });
    const false_value = try builder.internConstant(bool_type, .{ .boolean = false });
    var children: [2]ir.id.ValueId = undefined;
    for ([_][3]ir.id.ValueId{ .{ f0, signed_first, true_value }, .{ f1, signed_second, false_value } }, 0..) |values, index| {
        var constants: [3]ir.id.ConstantId = undefined;
        for (values, 0..) |value, member|
            constants[member] = module.values.get(value).?.definition.constant;
        children[index] = try builder.internConstant(child_type, .{ .composite = &constants });
    }
    const array = try builder.internConstant(array_type, .{ .composite = &.{ module.values.get(children[0]).?.definition.constant, module.values.get(children[1]).?.definition.constant } });
    const high = try builder.internConstant(unsigned_type, .{ .integer_bits = 0x80000004 });
    const root = try builder.internConstant(root_type, .{ .composite = &.{ module.values.get(array).?.definition.constant, module.values.get(high).?.definition.constant } });
    const half = try builder.internConstant(float_type, .{ .float_bits = f32Bits(0.5) });
    const signed_two = try builder.internConstant(signed_type, .{ .integer_bits = 2 });
    const unsigned_two = try builder.internConstant(unsigned_type, .{ .integer_bits = 2 });
    const zero = try builder.internConstant(unsigned_type, .{ .integer_bits = 0 });
    const one = try builder.internConstant(unsigned_type, .{ .integer_bits = 1 });

    const function = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(function);
    const block = try builder.addBlock(function, "entry");
    var input_values: [3]ir.id.ValueId = undefined;
    for (child_types, inputs, 0..) |ty, input, index|
        input_values[index] = (try builder.appendInstruction(block, ty, .{ .load_interface = .{ .variable = input } }, null)).?;
    const child = (try builder.appendInstruction(block, child_type, .{ .composite_construct = .{ .elements = &input_values } }, null)).?;
    const constructed_array = (try builder.appendInstruction(block, array_type, .{ .composite_construct = .{ .elements = &.{ children[0], child } } }, null)).?;
    const constructed = (try builder.appendInstruction(block, root_type, .{ .composite_construct = .{ .elements = &.{ constructed_array, high } } }, null)).?;
    const leaf_types = [_]ir.id.TypeId{ float_type, signed_type, bool_type, float_type, signed_type, bool_type, unsigned_type };
    const paths = [_][]const u32{ &.{ 0, 0, 0 }, &.{ 0, 0, 1 }, &.{ 0, 0, 2 }, &.{ 0, 1, 0 }, &.{ 0, 1, 1 }, &.{ 0, 1, 2 }, &.{1} };
    var constructed_leaves: [7]ir.id.ValueId = undefined;
    var constructed_words: [7]ir.id.ValueId = undefined;
    for ([_]ir.id.ValueId{ root, constructed }, [_]ir.id.InterfaceVariableId{ constant_output, constructed_output }, 0..) |aggregate, output, root_index| {
        var words: [7]ir.id.ValueId = undefined;
        for (leaf_types, paths, 0..) |ty, path, index| {
            const leaf = (try builder.appendInstruction(block, ty, .{ .composite_extract = .{ .composite = aggregate, .indices = path } }, null)).?;
            words[index] = if (ty == bool_type)
                (try builder.appendInstruction(block, unsigned_type, .{ .select = .{ .condition = leaf, .true_value = one, .false_value = zero } }, null)).?
            else if (ty == unsigned_type)
                leaf
            else
                (try builder.appendInstruction(block, unsigned_type, .{ .bitcast = leaf }, null)).?;
            if (root_index == 1) constructed_leaves[index] = leaf;
        }
        if (root_index == 1) constructed_words = words;
        const snapshot = (try builder.appendInstruction(block, words_type, .{ .composite_construct = .{ .elements = &words } }, null)).?;
        _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = output, .value = snapshot } }, null);
    }
    const sum = (try builder.appendInstruction(block, float_type, .{ .binary = .{ .opcode = .float_add, .lhs = constructed_leaves[3], .rhs = half } }, null)).?;
    const signed_quotient = (try builder.appendInstruction(block, signed_type, .{ .binary = .{ .opcode = .signed_divide, .lhs = constructed_leaves[4], .rhs = signed_two } }, null)).?;
    const unsigned_quotient = (try builder.appendInstruction(block, unsigned_type, .{ .binary = .{ .opcode = .unsigned_divide, .lhs = constructed_leaves[6], .rhs = unsigned_two } }, null)).?;
    const sum_bits = (try builder.appendInstruction(block, unsigned_type, .{ .bitcast = sum }, null)).?;
    const quotient_bits = (try builder.appendInstruction(block, unsigned_type, .{ .bitcast = signed_quotient }, null)).?;
    const arithmetic_value = (try builder.appendInstruction(block, arithmetic_type, .{ .composite_construct = .{ .elements = &.{ sum_bits, quotient_bits, unsigned_quotient, constructed_words[5] } } }, null)).?;
    _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = arithmetic_output, .value = arithmetic_value } }, null);
    try builder.setTerminator(block, .return_void);
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(0), &.{f32Bits(2.5)});
    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(1), &.{0xfffffff4});
    try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(2), &.{1});
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));

    const expected = [_][7]u32{
        .{ f32Bits(1.5), 0xfffffff7, 1, f32Bits(-2.25), 0xfffffff9, 0, 0x80000004 },
        .{ f32Bits(1.5), 0xfffffff7, 1, f32Bits(2.5), 0xfffffff4, 1, 0x80000004 },
    };
    for (expected, 3..) |wanted, index| {
        const output = ir.id.InterfaceVariableId.fromIndex(index);
        try std.testing.expectEqual(@as(u8, 7), program.interfaceBinding(output).?.span.components);
        try std.testing.expectEqual(bc.ValueKind.unsigned_integer, program.interfaceBinding(output).?.span.kind);
        var words: [7]u32 = undefined;
        try runtime.readOutput(&program, output, &words);
        try std.testing.expectEqualSlices(u32, &wanted, &words);
    }
    var arithmetic: [4]u32 = undefined;
    try runtime.readOutput(&program, ir.id.InterfaceVariableId.fromIndex(5), &arithmetic);
    try std.testing.expectEqualSlices(u32, &.{ f32Bits(3), 0xfffffffa, 0x40000002, 1 }, &arithmetic);
}

test "[interpreter] mixed block parameters swap in parallel and scalar select copies every member" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    @condition: bool = input[location(0), component(0), index(0)]
        \\    @output: vec4[u32] = output[location(0), component(0), index(0)]
        \\    %f0: constant f32 = bits(0x80000000)
        \\    %i0: constant i32 = bits(0xfffffffd)
        \\    %false: constant bool = false
        \\    %u0: constant u32 = bits(0xdeadbeef)
        \\    %first: constant struct[f32, i32, bool, u32] = [#0, #1, #2, #3]
        \\    %f1: constant f32 = bits(0x3fc00000)
        \\    %i1: constant i32 = bits(0xfffffff7)
        \\    %true: constant bool = true
        \\    %u1: constant u32 = bits(0x80000004)
        \\    %zero: constant u32 = 0
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %condition: bool = load_interface @condition
        \\            %second: struct[f32, i32, bool, u32] = composite_construct %f1, %i1, %true, %u1
        \\            branch .loop(%first, %second, %zero)
        \\        .loop(%a: struct[f32, i32, bool, u32], %b: struct[f32, i32, bool, u32], %index: u32):
        \\            %continue: bool = cmp_unsigned_less %index, %one
        \\            conditional_branch %continue, .body(), .exit()
        \\        .body():
        \\            %next: u32 = integer_add %index, %one
        \\            branch .loop(%b, %a, %next)
        \\        .exit():
        \\            %selected: struct[f32, i32, bool, u32] = select %condition, %a, %b
        \\            %f: f32 = composite_extract %selected[0]
        \\            %i: i32 = composite_extract %selected[1]
        \\            %flag: bool = composite_extract %selected[2]
        \\            %u: u32 = composite_extract %selected[3]
        \\            %f_bits: u32 = bitcast %f
        \\            %i_bits: u32 = bitcast %i
        \\            %flag_bits: u32 = select %flag, %one, %zero
        \\            %words: vec4[u32] = composite_construct %f_bits, %i_bits, %flag_bits, %u
        \\            store_interface @output, %words
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    try std.testing.expect(program.scratch_count >= 8);
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();

    const expected = [_][4]u32{
        .{ 0x80000000, 0xfffffffd, 0, 0xdeadbeef },
        .{ f32Bits(1.5), 0xfffffff7, 1, 0x80000004 },
    };
    for (expected, 0..) |wanted, condition| {
        runtime.resetInvocation(&program);
        try runtime.writeInput(&program, ir.id.InterfaceVariableId.fromIndex(0), &.{@intCast(condition)});
        try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
        var words: [4]u32 = undefined;
        try runtime.readOutput(&program, ir.id.InterfaceVariableId.fromIndex(1), &words);
        try std.testing.expectEqualSlices(u32, &wanted, &words);
    }
}

test "[interpreter] inlined mixed struct return retains scalar arithmetic signedness" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    @output: vec4[u32] = output[location(0), component(0), index(0)]
        \\    %float: constant f32 = bits(0x3fc00000)
        \\    %signed: constant i32 = bits(0xfffffff7)
        \\    %flag: constant bool = true
        \\    %unsigned: constant u32 = bits(0x80000004)
        \\    %signed_two: constant i32 = 2
        \\    %unsigned_two: constant u32 = 2
        \\    %zero: constant u32 = 0
        \\    %one: constant u32 = 1
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %bundle: struct[f32, i32, bool, u32] = call @helper(%float, %signed, %flag, %unsigned)
        \\            %f: f32 = composite_extract %bundle[0]
        \\            %i: i32 = composite_extract %bundle[1]
        \\            %b: bool = composite_extract %bundle[2]
        \\            %u: u32 = composite_extract %bundle[3]
        \\            %sum: f32 = float_add %f, %float
        \\            %signed_quotient: i32 = signed_divide %i, %signed_two
        \\            %unsigned_quotient: u32 = unsigned_divide %u, %unsigned_two
        \\            %sum_bits: u32 = bitcast %sum
        \\            %signed_bits: u32 = bitcast %signed_quotient
        \\            %flag_bits: u32 = select %b, %one, %zero
        \\            %words: vec4[u32] = composite_construct %sum_bits, %signed_bits, %flag_bits, %unsigned_quotient
        \\            store_interface @output, %words
        \\            return
        \\    }
        \\    fn @helper(%f_arg: f32, %i_arg: i32, %b_arg: bool, %u_arg: u32) -> struct[f32, i32, bool, u32]
        \\    {
        \\        .entry():
        \\            %result: struct[f32, i32, bool, u32] = composite_construct %f_arg, %i_arg, %b_arg, %u_arg
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
    var words: [4]u32 = undefined;
    try runtime.readOutput(&program, ir.id.InterfaceVariableId.fromIndex(0), &words);
    try std.testing.expectEqualSlices(u32, &.{ f32Bits(3), 0xfffffffc, 1, 0x40000002 }, &words);
}
