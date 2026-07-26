const std = @import("std");
const ids = @import("id.zig");
const inst_ir = @import("instruction.zig");
const operand = @import("operand.zig");
const program_ir = @import("program.zig");

const indent = "    ";

pub fn write(program: *const program_ir.Program, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("; Flint program:\n");
    try writer.print(";   .stage: {t}\n", .{program.stage});
    try writer.print(";   .generation: {t}\n", .{program.device_info.generation});
    try writer.print(";   .platform: {t}\n", .{program.device_info.platform});
    try writer.print(";   .dispatch_width: {t}\n", .{program.dispatch_width});
    if (program.entry_function) |entry| {
        try writer.writeAll(";   .entry: ");
        try writeFunctionRef(program, writer, entry);
        try writer.writeByte('\n');
    }

    try writer.writeByte('\n');

    for (program.virtual_registers.entries.items, 0..) |entry, index| {
        const register = entry orelse continue;
        try writeVirtualRegisterRef(program, writer, ids.VirtualRegisterId.fromIndex(index));
        try writer.print(": vgrf {t}[{d}] = class({t}), size({d}), alignment({d}), spillable({})\n", .{
            register.element_type,
            register.lane_count,
            register.class,
            register.size_bytes,
            register.alignment_bytes,
            register.spillable,
        });
    }

    for (program.virtual_flags.entries.items, 0..) |entry, index| {
        _ = entry orelse continue;
        try writeVirtualFlagRef(program, writer, ids.VirtualFlagId.fromIndex(index));
        try writer.writeAll(": vflag\n");
    }

    for (program.functions.entries.items, 0..) |entry, function_index| {
        const function = entry orelse continue;

        try writer.writeAll("\nfn ");
        try writeFunctionRef(program, writer, ids.FunctionId.fromIndex(function_index));
        try writer.writeByte('(');
        for (function.parameters.items, 0..) |parameter, index| {
            if (index != 0)
                try writer.writeAll(", ");
            try writeVirtualRegisterRef(program, writer, parameter);
            try writer.writeAll(": ");
            if (program.virtual_registers.get(parameter)) |register|
                try writer.print("{t}", .{register.element_type})
            else
                try writer.print("<invalid-vgrf-{d}>", .{parameter.index()});
        }
        try writer.writeAll(") -> ");
        if (function.return_type) |return_type|
            try writer.print("{t}", .{return_type})
        else
            try writer.writeAll("void");
        try writer.writeAll("\n{\n");

        for (function.blocks.items) |block_id| {
            const block = program.blocks.get(block_id) orelse continue;

            try writer.writeAll(indent);
            try writeBlockRef(program, writer, block_id);
            try writer.writeAll(":\n");

            switch (block.structured_control) {
                .none => {},
                .selection => |selection| {
                    try writer.writeAll(indent ** 2 ++ "structured_selection ");
                    try writeBlockRef(program, writer, selection.merge_block);
                    try writer.writeByte('\n');
                },
                .loop => |loop| {
                    try writer.writeAll(indent ** 2 ++ "structured_loop merge(");
                    try writeBlockRef(program, writer, loop.merge_block);
                    try writer.writeAll("), continue(");
                    try writeBlockRef(program, writer, loop.continue_block);
                    try writer.writeAll(")\n");
                },
            }

            for (block.instructions.items) |instruction_id| {
                const instruction = program.instructions.get(instruction_id) orelse continue;
                try writer.writeAll(indent ** 2);
                try writeInstruction(program, writer, instruction.*);
                try writer.writeByte('\n');
            }

            if (block.terminator) |terminator| {
                try writer.writeAll(indent ** 2);
                try writeTerminator(program, writer, terminator);
                try writer.writeAll("\n\n");
            } else {
                try writer.writeAll(indent ** 2 ++ "<missing terminator>\n\n");
            }
        }

        try writer.writeAll("}\n");
    }
}

pub fn allocPrint(allocator: std.mem.Allocator, program: *const program_ir.Program) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try write(program, &output.writer);
    return output.toOwnedSlice();
}

fn writeInstruction(program: *const program_ir.Program, writer: *std.Io.Writer, instruction: inst_ir.Instruction) !void {
    try writer.print("[simd{d}] ", .{@intFromEnum(instruction.execution_size)});
    if (instruction.predicate) |predicate| {
        try writePredicate(program, writer, predicate);
        try writer.writeByte(' ');
    }
    try writeOperation(program, writer, instruction.operation);
}

fn writeOperation(program: *const program_ir.Program, writer: *std.Io.Writer, operation: inst_ir.Operation) !void {
    switch (operation) {
        .load_input => |op| {
            try writeDestination(program, writer, op.destination);
            try writer.writeAll(" = load_input ");
            try writeInterfaceSemantic(writer, op.semantic);
        },
        .store_output => |op| {
            try writer.writeAll("store_output ");
            try writeInterfaceSemantic(writer, op.semantic);
            try writer.writeAll(", ");
            try writeSource(program, writer, op.source);
        },
        .move => |op| {
            try writeDestination(program, writer, op.destination);
            try writer.writeAll(" = move ");
            try writeSource(program, writer, op.source);
        },
        .binary => |op| {
            try writeDestination(program, writer, op.destination);
            try writer.print(" = {t} ", .{op.opcode});
            try writeSource(program, writer, op.lhs);
            try writer.writeAll(", ");
            try writeSource(program, writer, op.rhs);
        },
        .compare => |op| {
            try writeFlagRef(program, writer, op.destination);
            try writer.print(" = cmp_{t} ", .{op.opcode});
            try writeSource(program, writer, op.lhs);
            try writer.writeAll(", ");
            try writeSource(program, writer, op.rhs);
        },
        .call => |op| {
            if (op.destination) |destination| {
                try writeDestination(program, writer, destination);
                try writer.writeAll(" = ");
            }
            try writer.writeAll("call ");
            try writeFunctionRef(program, writer, op.function);
            try writer.writeByte('(');
            for (op.arguments, 0..) |argument, index| {
                if (index != 0)
                    try writer.writeAll(", ");
                try writeSource(program, writer, argument);
            }
            try writer.writeByte(')');
        },
        .send => |op| {
            if (op.response) |response| {
                try writeRegisterSpan(program, writer, response);
                try writer.writeAll(" = ");
            }
            try writer.writeAll("send ");
            try writeMessage(writer, op.message);
            try writer.writeAll(", payload(");
            try writeRegisterSpan(program, writer, op.payload);
            try writer.writeByte(')');
        },
    }
}

fn writeTerminator(program: *const program_ir.Program, writer: *std.Io.Writer, terminator: inst_ir.Terminator) !void {
    switch (terminator) {
        .jump => |target| {
            try writer.writeAll("jump ");
            try writeBlockRef(program, writer, target);
        },
        .conditional_branch => |branch| {
            try writer.writeAll("conditional_branch ");
            try writePredicate(program, writer, branch.predicate);
            try writer.writeAll(", ");
            try writeBlockRef(program, writer, branch.true_block);
            try writer.writeAll(", ");
            try writeBlockRef(program, writer, branch.false_block);
        },
        .return_void => try writer.writeAll("return"),
        .return_value => |value| {
            try writer.writeAll("return ");
            try writeSource(program, writer, value);
        },
        .end_thread => try writer.writeAll("end_thread"),
        .@"unreachable" => try writer.writeAll("unreachable"),
    }
}

fn writeSource(program: *const program_ir.Program, writer: *std.Io.Writer, source: operand.Source) !void {
    if (source.negate)
        try writer.writeByte('-');
    if (source.absolute)
        try writer.writeAll("abs(");

    switch (source.register) {
        .immediate => |immediate| try writeImmediate(writer, immediate),
        else => {
            try writeRegisterAtOffset(program, writer, source.register, source.region.byte_offset);
            try writer.print("<{d};{d},{d}>", .{
                source.region.vertical_stride,
                source.region.width,
                source.region.horizontal_stride,
            });
        },
    }
    try writer.print(":{t}", .{source.type});

    if (source.absolute)
        try writer.writeByte(')');
}

fn writeDestination(program: *const program_ir.Program, writer: *std.Io.Writer, destination: operand.Destination) !void {
    try writeRegisterAtOffset(program, writer, destination.register, destination.region.byte_offset);
    try writer.print("<{d}>:{t}", .{ destination.region.horizontal_stride, destination.type });
}

fn writeRegisterAtOffset(
    program: *const program_ir.Program,
    writer: *std.Io.Writer,
    register: operand.RegisterRef,
    byte_offset: u16,
) !void {
    switch (register) {
        .virtual => |virtual| {
            try writeVirtualRegisterRef(program, writer, virtual);
            try writer.print(".{d}", .{byte_offset});
        },
        .physical_grf => |physical| try writer.print("r{d}.{d}", .{
            physical.number,
            @as(u16, physical.byte_offset) + byte_offset,
        }),
        .architecture => |architecture| {
            try writeArchitectureRegister(writer, architecture);
            try writer.print(".{d}", .{byte_offset});
        },
        .immediate => |immediate| try writeImmediate(writer, immediate),
        .null => try writer.writeAll("null"),
    }
}

fn writeArchitectureRegister(writer: *std.Io.Writer, register: operand.ArchitectureRegister) !void {
    switch (register) {
        .flag => |index| try writer.print("f{d}", .{index}),
        .address => |index| try writer.print("a{d}", .{index}),
        .accumulator => |index| try writer.print("acc{d}", .{index}),
        .notification => |index| try writer.print("n{d}", .{index}),
        .instruction_pointer => try writer.writeAll("ip"),
    }
}

fn writeImmediate(writer: *std.Io.Writer, immediate: operand.Immediate) !void {
    switch (immediate) {
        .u32 => |value| try writer.print("{d}", .{value}),
        .i32 => |value| try writer.print("{d}", .{value}),
        .f32 => |value| try writer.print("{d}", .{value}),
    }
}

fn writePredicate(program: *const program_ir.Program, writer: *std.Io.Writer, predicate: operand.Predicate) !void {
    try writer.writeAll(if (predicate.inverse) "(-" else "(+");
    try writeFlagRef(program, writer, predicate.flag);
    try writer.writeByte(')');
}

fn writeFlagRef(program: *const program_ir.Program, writer: *std.Io.Writer, flag: operand.FlagRef) !void {
    switch (flag) {
        .virtual => |virtual| try writeVirtualFlagRef(program, writer, virtual),
        .physical => |physical| try writer.print("f{d}.{d}", .{ physical.register, physical.subregister }),
    }
}

fn writeRegisterSpan(program: *const program_ir.Program, writer: *std.Io.Writer, span: operand.RegisterSpan) !void {
    try writeRegisterAtOffset(program, writer, span.base, 0);
    try writer.print("[{d}]", .{span.register_count});
}

fn writeInterfaceSemantic(writer: *std.Io.Writer, semantic: inst_ir.InterfaceSemantic) !void {
    switch (semantic) {
        .location => |location| try writer.print("location({d}), component({d})", .{ location.location, location.component }),
        .builtin => |builtin| try writer.print("builtin({t}), component({d})", .{ builtin.builtin, builtin.component }),
    }
}

fn writeMessage(writer: *std.Io.Writer, message: inst_ir.Message) !void {
    switch (message) {
        .urb_write => |urb| {
            try writer.print("urb_write[offset({d}), channels(", .{urb.offset});
            try writeChannelMask(writer, urb.channels);
            try writer.writeByte(')');
            if (urb.end_of_thread)
                try writer.writeAll(", end_of_thread");
            try writer.writeByte(']');
        },
    }
}

fn writeChannelMask(writer: *std.Io.Writer, mask: inst_ir.ChannelMask) !void {
    if (mask.x) try writer.writeByte('x');
    if (mask.y) try writer.writeByte('y');
    if (mask.z) try writer.writeByte('z');
    if (mask.w) try writer.writeByte('w');
}

fn writeVirtualRegisterRef(program: *const program_ir.Program, writer: *std.Io.Writer, register_id: ids.VirtualRegisterId) !void {
    const register = program.virtual_registers.get(register_id);
    try writeNamedRef(writer, if (register) |value| value.name else null, "v", register_id.index(), '%');
}

fn writeVirtualFlagRef(program: *const program_ir.Program, writer: *std.Io.Writer, flag_id: ids.VirtualFlagId) !void {
    const flag = program.virtual_flags.get(flag_id);
    try writeNamedRef(writer, if (flag) |value| value.name else null, "f", flag_id.index(), '%');
}

fn writeBlockRef(program: *const program_ir.Program, writer: *std.Io.Writer, block_id: ids.BlockId) !void {
    const block = program.blocks.get(block_id);
    try writeNamedRef(writer, if (block) |value| value.name else null, "b", block_id.index(), '.');
}

fn writeFunctionRef(program: *const program_ir.Program, writer: *std.Io.Writer, function_id: ids.FunctionId) !void {
    const function = program.functions.get(function_id);
    try writeNamedRef(writer, if (function) |value| value.name else null, "fn", function_id.index(), '@');
}

fn writeNamedRef(writer: *std.Io.Writer, name: ?[]const u8, fallback: []const u8, index: usize, prefix: u8) !void {
    try writer.writeByte(prefix);
    if (name) |text| {
        if (isValidName(text)) {
            try writer.writeAll(text);
            return;
        }
    }
    try writer.print("{s}{d}", .{ fallback, index });
}

fn isValidName(name: []const u8) bool {
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_'))
        return false;

    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_')
            return false;
    }
    return true;
}
