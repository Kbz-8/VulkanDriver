const std = @import("std");
const shader_ir = @import("shader_ir");
const Program = @import("../Program.zig");
const Runtime = @import("../Runtime.zig");
const ir = shader_ir.ir;

// Lowering probes need observable uses now that dead pure results are omitted
pub fn makeResultsObservable(module: *ir.module.Module) !void {
    var builder = ir.Builder.init(module);
    const instruction_count = module.instructions.entries.items.len;
    for (0..instruction_count) |index| {
        const instruction = (module.instructions.entries.items[index] orelse continue);
        const result = instruction.result orelse continue;
        const output = try builder.addInterfaceVariable(module.typeOf(result).?, .output, .{ .location = .{ .location = @intCast(index) } }, null);
        _ = try builder.appendInstruction(instruction.parent_block, null, .{ .store_interface = .{ .variable = output, .value = result } }, null);
    }
}

test "[interpreter] dead constants and pure instructions do not consume registers" {
    var module = ir.module.Module.init(std.testing.allocator, .compute);
    defer module.deinit();
    var builder = ir.Builder.init(&module);
    const void_type = try builder.internType(.void);
    const uint = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });
    const vec4 = try builder.internType(.{ .vector = .{ .element_type = uint, .length = 4 } });
    const constant = try builder.internConstant(vec4, .null);
    const definition = module.values.get(constant).?.definition;
    for (0..17000) |_| {
        _ = try module.values.add(module.allocator(), .{ .type = vec4, .definition = definition });
    }
    const output = try builder.addInterfaceVariable(vec4, .output, .{ .location = .{ .location = 0 } }, null);
    const function = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(function);
    const block = try builder.addBlock(function, "entry");
    _ = try builder.appendInstruction(block, vec4, .{ .binary = .{ .opcode = .integer_add, .lhs = constant, .rhs = constant } }, null);
    try builder.setTerminator(block, .return_void);
    const value_count = module.values.entries.items.len;
    const instruction_count = module.instructions.entries.items.len;
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 4), program.register_count);
    try std.testing.expectEqual(@as(usize, 0), program.initializers.len);
    try std.testing.expectEqual(@as(usize, 1), program.code.len);
    try std.testing.expect(program.interfaceBinding(output) != null);
    try std.testing.expectEqual(value_count, module.values.entries.items.len);
    try std.testing.expectEqual(instruction_count, module.instructions.entries.items.len);
}

test "[interpreter] cyclic dead loop parameters do not keep their inputs alive" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\ shader compute @main
        \\ {
        \\     @output: u32 = output[location(0), component(0), index(0)]
        \\     %zero: constant u32 = 0
        \\     %one: constant u32 = 1
        \\     %three: constant u32 = 3
        \\     %dead: constant u32 = 123
        \\     fn @main() -> void
        \\     {
        \\         .entry():
        \\             branch .loop(%zero, %dead, %dead)
        \\         .loop(%index: u32, %a: u32, %b: u32):
        \\             %condition: bool = cmp_unsigned_less %index, %three
        \\             conditional_branch %condition, .body(), .exit()
        \\         .body():
        \\             store_interface @output, %index
        \\             %next: u32 = integer_add %index, %one
        \\             %dead_next: u32 = integer_add %a, %b
        \\             branch .loop(%next, %b, %dead_next)
        \\         .exit():
        \\             return
        \\     }
        \\ }
    );
    defer module.deinit();
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 6), program.register_count);
    try std.testing.expectEqual(@as(usize, 3), program.initializers.len);
    try std.testing.expectEqual(@as(usize, 2), program.copies.len);
    try std.testing.expectEqual(@as(usize, 1), program.scratch_count);
    var runtime = try Runtime.init(std.testing.allocator, &program);
    defer runtime.deinit();
    try std.testing.expectEqual(Runtime.Outcome.returned, try runtime.run(&program, .{}));
    var output: [1]u32 = undefined;
    try runtime.readOutput(&program, ir.id.InterfaceVariableId.fromIndex(0), &output);
    try std.testing.expectEqual(@as(u32, 2), output[0]);
}

test "[interpreter] side effects without results survive value liveness" {
    var module = try ir.parser.parseString(std.testing.allocator,
        \\ shader compute @main
        \\ {
        \\     fn @main() -> void
        \\     {
        \\         .entry():
        \\             control_barrier
        \\             return
        \\     }
        \\ }
    );
    defer module.deinit();
    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 0), program.register_count);
    try std.testing.expectEqual(@as(usize, 2), program.code.len);
    try std.testing.expectEqual(@import("../bytecode.zig").Opcode.control_barrier, program.code[0].opcode);
    try std.testing.expectEqual(@import("../bytecode.zig").Opcode.return_void, program.code[1].opcode);
}

test "[interpreter] genuinely live values still exhaust the 16-bit registers" {
    var module = ir.module.Module.init(std.testing.allocator, .compute);
    defer module.deinit();
    var builder = ir.Builder.init(&module);
    const void_type = try builder.internType(.void);
    const uint = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });
    const vec4 = try builder.internType(.{ .vector = .{ .element_type = uint, .length = 4 } });
    const input = try builder.addInterfaceVariable(vec4, .input, .{ .location = .{ .location = 0 } }, null);
    const output = try builder.addInterfaceVariable(vec4, .output, .{ .location = .{ .location = 1 } }, null);
    const function = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(function);
    const block = try builder.addBlock(function, "entry");
    const values = try std.testing.allocator.alloc(ir.id.ValueId, 17000);
    defer std.testing.allocator.free(values);
    for (values) |*value| {
        value.* = (try builder.appendInstruction(block, vec4, .{ .load_interface = .{ .variable = input } }, null)).?;
    }
    for (values) |value| {
        _ = try builder.appendInstruction(block, null, .{ .store_interface = .{ .variable = output, .value = value } }, null);
    }
    try builder.setTerminator(block, .return_void);
    try std.testing.expectError(Program.CompileError.TooManyRegisters, Program.compile(std.testing.allocator, &module));
}
