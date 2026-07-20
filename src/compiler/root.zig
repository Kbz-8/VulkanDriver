//! ## Shader compiler infrastructure.
//!
//! This module exposes the project-specific intermediate representation in
//! `ir` and the SPIR-V frontend in `spirv`.
//!
//! Together they form
//! the first stage of the compiler pipeline: SPIR-V binary modules are decoded,
//! translated into a smaller and easier-to-transform IR, validated, and then made
//! available to later optimization or code-generation passes.

const std = @import("std");

pub const ir = @import("ir/ir.zig");
pub const spirv = @import("spirv/root.zig");

const VisitorStatistics = struct {
    functions: usize = 0,
    blocks: usize = 0,
};

test "IR builder generation" {
    // shader vertex @main
    // {
    //     @color: vec4[f32] = input[location(0), component(0), index(0)]
    //     @out_color: vec4[f32] = output[location(0), component(0), index(0)]
    //     %0: constant bool = true
    //     %1: constant f32 = bits(0x3f800000)
    //
    //     fn @main() -> void
    //     {
    //         .entry():
    //             %3: vec4[f32] = load_interface @color
    //             conditional_branch %0, .pass(), .merge(%3)
    //
    //         .pass():
    //             %4: vec4[f32] = composite_construct %1, %1, %1, %1
    //             branch .merge(%4)
    //
    //         .merge(%2: vec4[f32]):
    //             store_interface @out_color, %2
    //             return
    //     }
    // }

    var module = ir.module.Module.init(std.testing.allocator, .vertex);
    defer module.deinit();
    var builder = ir.Builder.init(&module);

    const void_type = try builder.internType(.void);
    const bool_type = try builder.internType(.boolean);
    const f32_type = try builder.internType(.{ .floating = .{ .bits = 32 } });
    const duplicate_f32 = try builder.internType(.{ .floating = .{ .bits = 32 } });
    try std.testing.expectEqual(f32_type, duplicate_f32);
    const vec4_type = try builder.internType(.{ .vector = .{ .element_type = f32_type, .length = 4 } });

    const true_value = try builder.internConstant(bool_type, .{ .boolean = true });
    const one = try builder.internConstant(f32_type, .{ .float_bits = @as(u32, @bitCast(@as(f32, 1.0))) });

    const input = try builder.addInterfaceVariable(vec4_type, .input, .{ .location = .{ .location = 0 } }, "color");
    const output = try builder.addInterfaceVariable(vec4_type, .output, .{ .location = .{ .location = 0 } }, "out_color");
    const main = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(main);
    const entry = try builder.addBlock(main, "entry");
    const pass = try builder.addBlock(main, "pass");
    const merge = try builder.addBlock(main, "merge");
    const merged = try builder.addBlockParameter(merge, vec4_type, "merged");

    const loaded = (try builder.appendInstruction(entry, vec4_type, .{
        .load_interface = .{ .variable = input },
    }, "loaded")).?;
    try builder.setTerminator(entry, .{ .conditional_branch = .{
        .condition = true_value,
        .true_edge = try builder.edge(pass, &.{}),
        .false_edge = try builder.edge(merge, &.{loaded}),
    } });

    const splat = (try builder.appendInstruction(pass, vec4_type, .{
        .composite_construct = .{ .elements = &.{ one, one, one, one } },
    }, "white")).?;
    try builder.setTerminator(pass, .{ .branch = try builder.edge(merge, &.{splat}) });
    _ = try builder.appendInstruction(merge, null, .{
        .store_interface = .{ .variable = output, .value = merged },
    }, null);
    try builder.setTerminator(merge, .return_void);

    try ir.validator.validate(&module);

    var control_flow = try ir.cfg.init(std.testing.allocator, &module, main);
    defer control_flow.deinit();
    try std.testing.expectEqual(@as(usize, 2), control_flow.predecessors(merge).?.len);
    try std.testing.expect(control_flow.dominates(entry, merge));
    try std.testing.expect(!control_flow.dominates(pass, merge));

    const text = try ir.printer.allocPrint(std.testing.allocator, &module);

    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "shader vertex @main") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "@color: vec4[f32] = input[location(0), component(0), index(0)]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "@out_color: vec4[f32] = output[location(0), component(0), index(0)]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "conditional_branch %0, .pass(), .merge(%loaded)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".merge(%merged: vec4[f32])") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store_interface @out_color, %merged") != null);

    var parsed = try ir.parser.parseString(std.testing.allocator, text);
    defer parsed.deinit();
    const round_trip = try ir.printer.allocPrint(std.testing.allocator, &parsed);
    defer std.testing.allocator.free(round_trip);
    try std.testing.expectEqualStrings(text, round_trip);

    const io = std.Options.debug_io;
    const path = ".zig-cache/ir-parser-round-trip.ir";
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    {
        defer file.close(io);
        var file_buffer: [4096]u8 = @splat(0);
        var file_writer = file.writer(io, &file_buffer);
        try file_writer.interface.writeAll(text);
        try file_writer.interface.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch @panic("Caught an error while handling an error");

    var parsed_file = try ir.parser.parseFile(std.testing.allocator, io, path);
    defer parsed_file.deinit();
    const file_round_trip = try ir.printer.allocPrint(std.testing.allocator, &parsed_file);
    defer std.testing.allocator.free(file_round_trip);
    try std.testing.expectEqualStrings(text, file_round_trip);
}

test "IR parse interface" {
    const source =
        \\ shader vertex @main
        \\ {
        \\     @in_color: vec4[f32] = input[location(0), component(0), index(0)]
        \\     @out_color: vec4[f32] = output[location(0), component(0), index(0)]
        \\     @position: vec4[f32] = output[builtin(position)]
        \\
        \\     fn @main() -> void
        \\     {
        \\         .entry():
        \\             return
        \\     }
        \\ }
    ;

    var module = try ir.parser.parseString(std.testing.allocator, source);
    defer module.deinit();
    const printed = try ir.printer.allocPrint(std.testing.allocator, &module);
    defer std.testing.allocator.free(printed);

    try std.testing.expect(std.mem.indexOf(u8, printed, "@in_color: vec4[f32] = input[location(0), component(0), index(0)]") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "@out_color: vec4[f32] = output[location(0), component(0), index(0)]") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "@position: vec4[f32] = output[builtin(position)]") != null);
}

test "IR parse types, operations, calls, terminators" {
    const source =
        \\ shader fragment @main
        \\ {
        \\     %0: constant bool = true
        \\     %1: constant u32 = bits(0x1)
        \\     %2: constant u32 = bits(0x2)
        \\     %3: constant f32 = bits(0x3f800000)
        \\     %4: constant array[u32, 2] = [#1, #2]
        \\     %5: constant struct[u32, u32] = [#1, #2]
        \\     %6: constant ptr[private, u32] = null
        \\     %7: constant resourceHandle[sampler] = null
        \\
        \\     fn @main() -> void
        \\     {
        \\         .entry():
        \\             %9: u32 = bitwise_not %1
        \\             %10: u32 = integer_add %9, %2
        \\             %11: bool = cmp_equal %1, %2
        \\             %12: u32 = select %11, %1, %2
        \\             %13: u32 = bitcast %12
        \\             %14: vec2[u32] = composite_construct %1, %2
        \\             %15: u32 = composite_extract %14[0]
        \\             %16: f32 = negate %3
        \\             %17: f32 = float_add %3, %16
        \\             %18: u32 = call @helper(%15)
        \\             return
        \\     }
        \\
        \\     fn @helper(%8: u32) -> u32
        \\     {
        \\         .entry():
        \\             return %8
        \\     }
        \\
        \\     fn @discarder() -> void
        \\     {
        \\         .entry():
        \\             discard
        \\     }
        \\
        \\     fn @dead() -> void
        \\     {
        \\         .entry():
        \\             unreachable
        \\     }
        \\ }
    ;

    var module = try ir.parser.parseString(std.testing.allocator, source);
    defer module.deinit();
    const printed = try ir.printer.allocPrint(std.testing.allocator, &module);
    defer std.testing.allocator.free(printed);

    var reparsed = try ir.parser.parseString(std.testing.allocator, printed);
    defer reparsed.deinit();
    const printed_again = try ir.printer.allocPrint(std.testing.allocator, &reparsed);
    defer std.testing.allocator.free(printed_again);
    try std.testing.expectEqualStrings(printed, printed_again);
    try std.testing.expect(std.mem.indexOf(u8, printed, "cmp_equal %1, %2") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "cmp.") == null);
}

test "IR parse named value IDs" {
    const source =
        \\ shader compute @main
        \\ {
        \\     %one_value: constant u32 = bits(0x1)
        \\
        \\     fn @main() -> void
        \\     {
        \\         .entry():
        \\             %sum_value: u32 = integer_add %one_value, %one_value
        \\             branch .merge(%sum_value)
        \\
        \\         .merge(%merged_value: u32):
        \\             %product_value: u32 = integer_multiply %merged_value, %one_value
        \\             return
        \\     }
        \\ }
    ;

    var module = try ir.parser.parseString(std.testing.allocator, source);
    defer module.deinit();
    const printed = try ir.printer.allocPrint(std.testing.allocator, &module);
    defer std.testing.allocator.free(printed);

    try std.testing.expect(std.mem.indexOf(u8, printed, "%one_value: constant u32 = bits(0x1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "%sum_value: u32 = integer_add %one_value, %one_value") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "branch .merge(%sum_value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, ".merge(%merged_value: u32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "%product_value: u32 = integer_multiply %merged_value, %one_value") != null);

    var reparsed = try ir.parser.parseString(std.testing.allocator, printed);
    defer reparsed.deinit();
    const printed_again = try ir.printer.allocPrint(std.testing.allocator, &reparsed);
    defer std.testing.allocator.free(printed_again);
    try std.testing.expectEqualStrings(printed, printed_again);
}

test "IR parse numeric constants" {
    const source =
        \\ shader compute @main
        \\ {
        \\     %0: constant u8 = 255
        \\     %1: constant i8 = -1
        \\     %2: constant f16 = 1.5
        \\     %3: constant f32 = -0.0
        \\     %4: constant f64 = 2.5e0
        \\
        \\     fn @main() -> void
        \\     {
        \\         .entry():
        \\             return
        \\     }
        \\ }
    ;

    var module = try ir.parser.parseString(std.testing.allocator, source);
    defer module.deinit();
    const printed = try ir.printer.allocPrint(std.testing.allocator, &module);
    defer std.testing.allocator.free(printed);

    try std.testing.expect(std.mem.indexOf(u8, printed, "%0: constant u8 = bits(0xff)") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "%1: constant i8 = bits(0xff)") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "%2: constant f16 = bits(0x3e00)") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "%3: constant f32 = bits(0x80000000)") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "%4: constant f64 = bits(0x4004000000000000)") != null);

    const out_of_range =
        \\ shader compute @main
        \\ {
        \\     %0: constant u8 = 256
        \\     fn @main() -> void
        \\     {
        \\         .entry():
        \\             return
        \\     }
        \\ }
    ;
    try std.testing.expectError(error.InvalidNumber, ir.parser.parseString(std.testing.allocator, out_of_range));
}

test "IR parser error: unknown value" {
    const source =
        \\ shader compute @main
        \\ {
        \\     fn @main() -> void
        \\     {
        \\         .entry():
        \\             return %99
        \\     }
        \\ }
    ;
    try std.testing.expectError(error.UnknownValue, ir.parser.parseString(std.testing.allocator, source));
}

test "Validator error: wrong block argument count" {
    // shader compute @main
    // {
    //     fn @main() -> void
    //     {
    //         .entry():
    //             branch .merge()
    //
    //         .merge(%0: u32):
    //             return
    //     }
    // }

    var module = ir.module.Module.init(std.testing.allocator, .compute);
    defer module.deinit();
    var builder = ir.Builder.init(&module);

    const void_type = try builder.internType(.void);
    const u32_type = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });
    const main = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(main);
    const entry = try builder.addBlock(main, "entry");
    const merge = try builder.addBlock(main, "merge");
    _ = try builder.addBlockParameter(merge, u32_type, null);
    try builder.setTerminator(entry, .{ .branch = try builder.edge(merge, &.{}) });
    try builder.setTerminator(merge, .return_void);

    try std.testing.expectError(error.WrongBranchArgumentCount, ir.validator.validate(&module));
}

test "Central store IDs disposal" {
    var module = ir.module.Module.init(std.testing.allocator, .fragment);
    defer module.deinit();
    const first = try module.internType(.boolean);
    try std.testing.expect(module.types.remove(first));
    const second = try module.internType(.boolean);
    try std.testing.expect(first.index() != second.index());
    try std.testing.expect(module.types.get(first) == null);
}

test "Validator error: SSA definition does not dominate its use" {
    // shader compute @main
    // {
    //     %0: constant bool = true
    //     %1: constant u32 = bits(0x1)
    //
    //     fn @main() -> void
    //     {
    //         .entry():
    //             conditional_branch %0, .left(), .right()
    //
    //         .left():
    //             %2: u32 = integer_add %1, %1
    //             branch .merge()
    //
    //         .right():
    //             branch .merge()
    //
    //         .merge():
    //             %3: u32 = integer_multiply %2, %1
    //             return
    //     }
    // }

    var module = ir.module.Module.init(std.testing.allocator, .compute);
    defer module.deinit();
    var builder = ir.Builder.init(&module);

    const void_type = try builder.internType(.void);
    const bool_type = try builder.internType(.boolean);
    const u32_type = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });
    const condition = try builder.internConstant(bool_type, .{ .boolean = true });
    const one = try builder.internConstant(u32_type, .{ .integer_bits = 1 });
    const main = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(main);
    const entry = try builder.addBlock(main, "entry");
    const left = try builder.addBlock(main, "left");
    const right = try builder.addBlock(main, "right");
    const merge = try builder.addBlock(main, "merge");

    try builder.setTerminator(
        entry,
        .{
            .conditional_branch = .{
                .condition = condition,
                .true_edge = try builder.edge(left, &.{}),
                .false_edge = try builder.edge(right, &.{}),
            },
        },
    );

    const left_value = (try builder.appendInstruction(left, u32_type, .{
        .binary = .{
            .opcode = .integer_add,
            .lhs = one,
            .rhs = one,
        },
    }, null)).?;

    try builder.setTerminator(left, .{ .branch = try builder.edge(merge, &.{}) });
    try builder.setTerminator(right, .{ .branch = try builder.edge(merge, &.{}) });

    _ = try builder.appendInstruction(merge, u32_type, .{
        .binary = .{
            .opcode = .integer_multiply,
            .lhs = left_value,
            .rhs = one,
        },
    }, null);

    try builder.setTerminator(merge, .return_void);

    try std.testing.expectError(error.DefinitionDoesNotDominateUse, ir.validator.validate(&module));
}

test "Rewriter replace all ID uses, safely erase dead instruction" {
    // shader compute @main
    // {
    //     %0: constant u32 = bits(0x1)
    //     %1: constant u32 = bits(0x2)
    //
    //     fn @main() -> void
    //     {
    //         .entry():
    //             %2: u32 = integer_add %0, %1
    //             %3: u32 = integer_multiply %2, %1
    //             return
    //     }
    // }

    var module = ir.module.Module.init(std.testing.allocator, .compute);
    defer module.deinit();

    var builder = ir.Builder.init(&module);

    const void_type = try builder.internType(.void);
    const u32_type = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });

    const one = try builder.internConstant(u32_type, .{ .integer_bits = 1 });
    const two = try builder.internConstant(u32_type, .{ .integer_bits = 2 });

    const main = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(main);

    const entry = try builder.addBlock(main, "entry");
    const sum = (try builder.appendInstruction(entry, u32_type, .{
        .binary = .{
            .opcode = .integer_add,
            .lhs = one,
            .rhs = two,
        },
    }, null)).?;
    _ = try builder.appendInstruction(entry, u32_type, .{
        .binary = .{
            .opcode = .integer_multiply,
            .lhs = sum,
            .rhs = two,
        },
    }, null);
    try builder.setTerminator(entry, .return_void);

    try ir.validator.validate(&module);

    const sum_instruction = module.values.get(sum).?.definition.instruction;
    var rewriter = ir.Rewriter.init(&module);

    try std.testing.expectEqual(@as(usize, 1), try rewriter.replaceAllUses(sum, one));
    try rewriter.eraseInstruction(sum_instruction);

    try std.testing.expect(module.values.get(sum) == null);
    try std.testing.expect(module.instructions.get(sum_instruction) == null);

    try ir.validator.validate(&module);
}

test "Rewriter add block parameter and sync branch calls" {
    // shader compute @main
    // {
    //     %0: constant u32 = bits(0x1)
    //
    //     fn @main() -> void
    //     {
    //         .entry():
    //             branch .merge()
    //
    //         .merge():
    //             return
    //
    //         .alternate():
    //             return
    //     }
    // }

    var module = ir.module.Module.init(std.testing.allocator, .compute);
    defer module.deinit();

    var builder = ir.Builder.init(&module);

    const void_type = try builder.internType(.void);
    const u32_type = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });

    const one = try builder.internConstant(u32_type, .{ .integer_bits = 1 });

    const main = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(main);

    const entry = try builder.addBlock(main, "entry");
    const merge = try builder.addBlock(main, "merge");
    const alternate = try builder.addBlock(main, "alternate");

    try builder.setTerminator(entry, .{ .branch = try builder.edge(merge, &.{}) });
    try builder.setTerminator(merge, .return_void);
    try builder.setTerminator(alternate, .return_void);

    var rewriter = ir.Rewriter.init(&module);

    const parameter = try rewriter.addBlockParameter(merge, u32_type, "incoming", &.{
        .{
            .predecessor = entry,
            .value = one,
        },
    });
    const merge_edge = module.blocks.get(entry).?.terminator.?.branch;
    try std.testing.expectEqualSlices(ir.id.ValueId, &.{one}, merge_edge.arguments);

    _ = try builder.appendInstruction(merge, u32_type, .{
        .binary = .{
            .opcode = .integer_add,
            .lhs = parameter,
            .rhs = one,
        },
    }, null);
    try ir.validator.validate(&module);

    try rewriter.removeBlockParameter(merge, 0, one);

    try std.testing.expectEqual(@as(usize, 0), module.blocks.get(merge).?.parameters.items.len);
    try std.testing.expectEqual(@as(usize, 0), module.blocks.get(entry).?.terminator.?.branch.arguments.len);

    try ir.validator.validate(&module);

    try std.testing.expectEqual(@as(usize, 1), try rewriter.redirectEdges(entry, merge, alternate, &.{}));
    try std.testing.expectEqual(alternate, module.blocks.get(entry).?.terminator.?.branch.target);

    try ir.validator.validate(&module);
}

fn establishNoCalls(_: *ir.module.Module, _: *ir.pass_manager.Context) !bool {
    return false;
}

fn countVisitedFunction(context: ?*anyopaque, _: ir.id.FunctionId, _: *const ir.module.Function) !void {
    const statistics: *VisitorStatistics = @ptrCast(@alignCast(context.?));
    statistics.functions += 1;
}

fn countVisitedBlock(context: ?*anyopaque, _: ir.id.BlockId, _: *const ir.module.Block) !void {
    const statistics: *VisitorStatistics = @ptrCast(@alignCast(context.?));
    statistics.blocks += 1;
}

test "Pass manager track independent IR properties" {
    // shader compute @main
    // {
    //     fn @main() -> void
    //     {
    //         .entry():
    //             return
    //     }
    // }

    var module = ir.module.Module.init(std.testing.allocator, .compute);
    defer module.deinit();

    var builder = ir.Builder.init(&module);

    const void_type = try builder.internType(.void);

    const main = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(main);

    const entry = try builder.addBlock(main, "entry");
    try builder.setTerminator(entry, .return_void);

    module.properties.valid_cfg = true;

    var manager = ir.pass_manager.Manager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.add(.{
        .name = "establish-no-calls",
        .required = .{ .valid_cfg = true },
        .produced = .{ .no_function_calls = true },
        .run = establishNoCalls,
    });

    var context: ir.pass_manager.Context = .{ .allocator = std.testing.allocator };

    try std.testing.expect(!try manager.run(&module, &context));
    try std.testing.expect(module.properties.no_function_calls);

    var statistics: VisitorStatistics = .{};

    try ir.visitor.walk(&module, .{
        .context = &statistics,
        .visitFunction = countVisitedFunction,
        .visitBlock = countVisitedBlock,
    });

    try std.testing.expectEqual(@as(usize, 1), statistics.functions);
    try std.testing.expectEqual(@as(usize, 1), statistics.blocks);
}

test "SPIR-V parser error: zero-word instruction" {
    const words = [_]u32{
        spirv.spec.magic_number,
        0x0001_0000,
        0,
        2,
        0,
        instructionWord(.nop, 0),
    };
    try std.testing.expectError(error.ZeroWordInstruction, spirv.Parser.init(&words));

    const truncated = [_]u32{
        spirv.spec.magic_number,
        0x0001_0000,
        0,
        2,
        0,
        instructionWord(.i_add, 5),
        1,
    };
    try std.testing.expectError(error.TruncatedInstruction, spirv.Parser.init(&truncated));
}

test "SPIR-V structured branches and OpPhi to block parameters" {
    const assembly =
        \\ OpCapability Shader
        \\ OpMemoryModel Logical GLSL450
        \\ OpEntryPoint GLCompute %main "main"
        \\ OpExecutionMode %main LocalSize 1 1 1
        \\ OpName %main "main"
        \\ OpName %entry "entry"
        \\ OpName %true "true"
        \\ OpName %one "one"
        \\ OpName %then "then"
        \\ OpName %then_value "then_value"
        \\ OpName %else "else"
        \\ OpName %else_value "else_value"
        \\ OpName %merge "merge"
        \\ OpName %merged "merged"
        \\ OpName %product "product"
        \\
        \\ %void = OpTypeVoid
        \\ %bool = OpTypeBool
        \\ %uint = OpTypeInt 32 0
        \\ %fn_void = OpTypeFunction %void
        \\ %true = OpConstantTrue %bool
        \\ %one = OpConstant %uint 1
        \\
        \\ %main = OpFunction %void None %fn_void
        \\     %entry = OpLabel
        \\     OpSelectionMerge %merge None
        \\     OpBranchConditional %true %then %else
        \\     %then = OpLabel
        \\     %then_value = OpIAdd %uint %one %one
        \\     OpBranch %merge
        \\     %else = OpLabel
        \\     %else_value = OpISub %uint %one %one
        \\     OpBranch %merge
        \\     %merge = OpLabel
        \\     %merged = OpPhi %uint %then_value %then %else_value %else
        \\     %product = OpIMul %uint %merged %one
        \\     OpReturn
        \\ OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try spirv.translator.translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();

    try std.testing.expectEqual(ir.module.Stage.compute, module.stage);
    try std.testing.expectEqual([3]u32{ 1, 1, 1 }, module.execution_modes.workgroup_size.?);
    try std.testing.expect(module.properties.valid_cfg);
    try std.testing.expect(module.properties.valid_ssa);

    const function = module.functions.get(module.entry_point.?).?;
    try std.testing.expectEqual(@as(usize, 4), function.blocks.items.len);
    const entry = module.blocks.get(function.blocks.items[0]).?;
    try std.testing.expect(entry.structured_control == .selection);
    const merge = module.blocks.get(function.blocks.items[3]).?;
    try std.testing.expectEqual(@as(usize, 1), merge.parameters.items.len);
    try std.testing.expectEqual(@as(usize, 1), merge.instructions.items.len);
    const multiply = module.instructions.get(merge.instructions.items[0]).?;
    try std.testing.expectEqual(ir.instruction.BinaryOpcode.integer_multiply, multiply.operation.binary.opcode);

    const text = try ir.printer.allocPrint(std.testing.allocator, &module);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "%one: constant u32 = bits(0x1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "%true: constant bool = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "conditional_branch %true, .then(), .else()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "%then_value: u32 = integer_add %one, %one") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "branch .merge(%then_value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "%else_value: u32 = integer_subtract %one, %one") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".merge(%merged: u32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "%product: u32 = integer_multiply %merged, %one") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "integerMultiply") == null);

    var parsed = try ir.parser.parseString(std.testing.allocator, text);
    defer parsed.deinit();
    const round_trip = try ir.printer.allocPrint(std.testing.allocator, &parsed);
    defer std.testing.allocator.free(round_trip);
    try std.testing.expectEqualStrings(text, round_trip);
}

test "SPIR-V decorated vertex interfaces and load-store operations" {
    const assembly =
        \\ OpCapability Shader
        \\ OpMemoryModel Logical GLSL450
        \\ OpEntryPoint Vertex %main "main" %in_color %out_color
        \\ OpName %in_color "in_color"
        \\ OpName %out_color "out_color"
        \\ OpDecorate %in_color Location 0
        \\ OpDecorate %out_color Location 0
        \\
        \\ %void = OpTypeVoid
        \\ %float = OpTypeFloat 32
        \\ %vec4 = OpTypeVector %float 4
        \\ %input_vec4 = OpTypePointer Input %vec4
        \\ %output_vec4 = OpTypePointer Output %vec4
        \\ %fn_void = OpTypeFunction %void
        \\ %in_color = OpVariable %input_vec4 Input
        \\ %out_color = OpVariable %output_vec4 Output
        \\
        \\ %main = OpFunction %void None %fn_void
        \\     %entry = OpLabel
        \\     %color = OpLoad %vec4 %in_color
        \\     OpStore %out_color %color
        \\     OpReturn
        \\ OpFunctionEnd
    ;
    const words = try assembleSpirv(std.testing.allocator, assembly);
    defer std.testing.allocator.free(words);

    var module = try spirv.translator.translate(std.testing.allocator, words, .{ .entry_point = "main" });
    defer module.deinit();
    try std.testing.expectEqual(ir.module.Stage.vertex, module.stage);
    try std.testing.expectEqual(@as(usize, 2), module.interface_variables.entries.items.len);

    const text = try ir.printer.allocPrint(std.testing.allocator, &module);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "load_interface @in_color") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store_interface @out_color") != null);
}

fn instructionWord(opcode: spirv.spec.Opcode, word_count: u16) u32 {
    return (@as(u32, word_count) << 16) | @intFromEnum(opcode);
}

fn assembleSpirv(allocator: std.mem.Allocator, assembly: []const u8) ![]u32 {
    var io_backend: std.Io.Threaded = .init(allocator, .{});
    defer io_backend.deinit();
    const io = io_backend.io();

    var child = try std.process.spawn(io, .{
        .argv = &.{ "spirv-as", "--target-env", "spv1.0", "-o", "-", "-" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    {
        const stdin = child.stdin.?;
        var stdin_writer = stdin.writer(io, &.{});
        try stdin_writer.interface.writeAll(assembly);
        try stdin_writer.interface.flush();
        stdin.close(io);
        child.stdin = null;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buffer);
    const binary = try stdout_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    defer allocator.free(binary);

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buffer);
    const stderr = try stderr_reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(stderr);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.log.err("spirv-as failed:\n{s}", .{stderr});
            return error.SpirvAssemblyFailed;
        },
        else => {
            std.log.err("spirv-as terminated unexpectedly:\n{s}", .{stderr});
            return error.SpirvAssemblyFailed;
        },
    }

    if (binary.len % @sizeOf(u32) != 0) return error.InvalidSpirvBinaryLength;
    const words = try allocator.alloc(u32, binary.len / @sizeOf(u32));
    errdefer allocator.free(words);
    for (words, 0..) |*word, index| {
        const offset = index * @sizeOf(u32);
        word.* = std.mem.readInt(u32, binary[offset..][0..4], .little);
    }
    return words;
}
