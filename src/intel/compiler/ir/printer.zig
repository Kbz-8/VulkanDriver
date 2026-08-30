const std = @import("std");
const device = @import("../device.zig");
const ids = @import("id.zig");
const inst_ir = @import("instruction.zig");
const operand = @import("operand.zig");
const program_ir = @import("program.zig");
const pseudo = @import("pseudo.zig");

const indent = "    ";

pub fn write(program: *const program_ir.Program, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("; Flint compute program:\n");
    try writer.print(";   .workgroup_size: [{d}, {d}, {d}]\n", .{ program.workgroup_size[0], program.workgroup_size[1], program.workgroup_size[2] });
    try writer.print(";   .generation: {t}\n", .{program.device_info.generation});
    try writer.print(";   .platform: {t}\n", .{program.device_info.platform});
    try writer.print(";   .dispatch_width: {t}\n\n", .{program.dispatch_width});

    for (program.storage_buffers.entries.items, 0..) |entry, index| {
        const buffer = entry orelse continue;
        try writeStorageBufferRef(program, writer, ids.StorageBufferId.fromIndex(index));
        try writer.print(" = storage_buffer[set({d}), binding({d})]\n", .{ buffer.set, buffer.binding });
    }
    if (program.storage_buffers.entries.items.len != 0)
        try writer.writeByte('\n');

    for (program.virtual_registers.entries.items, 0..) |entry, index| {
        const register = entry orelse continue;
        try writeVirtualRegisterRef(program, writer, ids.VirtualRegisterId.fromIndex(index));
        try writer.print(": vgrf {t}[{d}], class({t}), size({d}), alignment({d}){s}\n", .{
            register.element_type,
            register.lane_count,
            register.class,
            register.size_bytes,
            register.alignment_bytes,
            if (register.spillable) ", spillable" else "",
        });
    }

    for (program.virtual_flags.entries.items, 0..) |entry, index| {
        _ = entry orelse continue;
        try writeVirtualFlagRef(program, writer, ids.VirtualFlagId.fromIndex(index));
        try writer.writeAll(": vflag\n");
    }

    try writer.writeByte('\n');

    for (program.blocks.entries.items, 0..) |entry, block_index| {
        const block = entry orelse continue;
        const block_id = ids.BlockId.fromIndex(block_index);

        try writeBlockRef(program, writer, block_id);
        if (block.parameters.items.len != 0) {
            try writer.writeByte('(');
            for (block.parameters.items, 0..) |parameter, index| {
                if (index != 0)
                    try writer.writeAll(", ");
                try writeBlockParameter(program, writer, parameter);
            }
            try writer.writeByte(')');
        }
        try writer.writeAll(":\n");

        switch (block.structured_control) {
            .none => {},
            .selection => |selection| {
                try writer.writeAll(indent ++ "structured_selection ");
                try writeBlockRef(program, writer, selection.merge_block);
                try writer.writeByte('\n');
            },
            .loop => |loop| {
                try writer.writeAll(indent ++ "structured_loop merge(");
                try writeBlockRef(program, writer, loop.merge_block);
                try writer.writeAll("), continue(");
                try writeBlockRef(program, writer, loop.continue_block);
                try writer.writeAll(")\n");
            },
        }

        for (block.instructions.items) |instruction_id| {
            const instruction = program.instructions.get(instruction_id) orelse continue;
            try writer.writeAll(indent);
            try writeInstruction(program, writer, instruction.*);
            try writer.writeByte('\n');
        }

        if (block.terminator) |terminator| {
            try writer.writeAll(indent);
            try writeTerminator(program, writer, terminator);
            try writer.writeAll("\n\n");
        } else {
            try writer.writeAll(indent ++ "<missing terminator>\n\n");
        }
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
    try writeOperation(program, writer, instruction.execution_size, instruction.operation);
}

fn writeOperation(program: *const program_ir.Program, writer: *std.Io.Writer, execution_size: device.ExecutionSize, operation: inst_ir.Operation) !void {
    switch (operation) {
        .load_global_invocation_id => |op| {
            try writer.writeAll("load_global_invocation_id ");
            try writeDestination(program, writer, execution_size, op.destination);
            try writer.print(", component({d})", .{op.component});
        },
        .load_buffer => |op| {
            try writer.writeAll("load_buffer ");
            try writeDestination(program, writer, execution_size, op.destination);
            try writer.writeAll(", ");
            try writeBufferReference(program, writer, op.buffer);
            try writer.writeAll(", ");
            try writeSource(program, writer, execution_size, op.byte_offset);
            if (op.immediate_offset != 0)
                try writer.print(", offset({d})", .{op.immediate_offset});
        },
        .store_buffer => |op| {
            try writer.writeAll("store_buffer ");
            try writeBufferReference(program, writer, op.buffer);
            try writer.writeAll(", ");
            try writeSource(program, writer, execution_size, op.byte_offset);
            if (op.immediate_offset != 0)
                try writer.print(", offset({d})", .{op.immediate_offset});
            try writer.writeAll(", ");
            try writeSource(program, writer, execution_size, op.source);
        },
        .array_length => |op| {
            try writer.writeAll("array_length ");
            try writeDestination(program, writer, execution_size, op.destination);
            try writer.writeAll(", ");
            try writeBufferReference(program, writer, op.buffer);
            try writer.writeAll(", ");
            try writeSource(program, writer, execution_size, op.byte_offset);
            try writer.print(", stride({d})", .{op.stride});
        },
        .surface_read => |op| {
            try writer.writeAll("surface_read ");
            try writeDestination(program, writer, execution_size, op.destination);
            try writer.print(", bti({d}), ", .{op.binding_table});
            try writeSource(program, writer, execution_size, op.address);
            if (op.immediate_offset != 0)
                try writer.print(", offset({d})", .{op.immediate_offset});
        },
        .surface_write => |op| {
            try writer.print("surface_write bti({d}), ", .{op.binding_table});
            try writeSource(program, writer, execution_size, op.address);
            if (op.immediate_offset != 0)
                try writer.print(", offset({d})", .{op.immediate_offset});
            try writer.writeAll(", ");
            try writeSource(program, writer, execution_size, op.data);
        },
        .surface_message => |op| {
            try writer.print("surface_message {t} bti({d}), payload(", .{ op.kind, op.binding_table });
            try writeRegister(program, writer, op.payload.base);
            try writer.print(", {d})", .{op.payload.register_count});
            if (op.response) |response| {
                try writer.writeAll(", response(");
                try writeRegister(program, writer, response.base);
                try writer.print(", {d})", .{response.register_count});
            }
            try writer.print(", type({t})", .{op.data_type});
        },
        .move => |op| {
            try writer.writeAll("mov ");
            try writeDestination(program, writer, execution_size, op.destination);
            try writer.writeAll(", ");
            try writeSource(program, writer, execution_size, op.source);
        },
        .binary => |op| {
            try writer.print("{t} ", .{op.opcode});
            try writeDestination(program, writer, execution_size, op.destination);
            try writer.writeAll(", ");
            try writeSource(program, writer, execution_size, op.lhs);
            try writer.writeAll(", ");
            try writeSource(program, writer, execution_size, op.rhs);
        },
        .compare => |op| {
            try writer.print("cmp_{t} ", .{op.opcode});
            try writeFlagRef(program, writer, op.destination);
            try writer.writeAll(", ");
            try writeSource(program, writer, execution_size, op.lhs);
            try writer.writeAll(", ");
            try writeSource(program, writer, execution_size, op.rhs);
        },
        .math => |op| {
            try writer.print("{t} ", .{op.opcode});
            try writeDestination(program, writer, execution_size, op.destination);
            try writer.writeAll(", ");
            try writeSource(program, writer, execution_size, op.lhs);
            try writer.writeAll(", ");
            try writeSource(program, writer, execution_size, op.rhs);
        },
        .parallel_copy => |op| try writeParallelCopy(program, writer, execution_size, op),
    }
}

fn writeParallelCopy(program: *const program_ir.Program, writer: *std.Io.Writer, execution_size: device.ExecutionSize, copy: pseudo.ParallelCopy) !void {
    try writer.writeAll("parallel_copy [");
    var needs_separator = false;

    for (copy.register_copies) |item| {
        if (needs_separator)
            try writer.writeAll(", ");
        try writeDestination(program, writer, execution_size, item.destination);
        try writer.writeAll(" <- ");
        try writeSource(program, writer, execution_size, item.source);
        needs_separator = true;
    }

    for (copy.flag_copies) |item| {
        if (needs_separator)
            try writer.writeAll(", ");
        try writeVirtualFlagRef(program, writer, item.destination);
        try writer.writeAll(" <- ");
        switch (item.source) {
            .constant => |value| try writer.writeAll(if (value) "true" else "false"),
            .dynamic => |predicate| try writePredicate(program, writer, predicate),
        }
        needs_separator = true;
    }

    try writer.writeByte(']');
}

fn writeTerminator(program: *const program_ir.Program, writer: *std.Io.Writer, terminator: inst_ir.Terminator) !void {
    switch (terminator) {
        .jump => |edge| {
            try writer.writeAll("jump ");
            try writeEdge(program, writer, edge);
        },
        .conditional_branch => |branch| {
            try writer.writeAll("conditional_branch ");
            try writePredicate(program, writer, branch.predicate);
            try writer.writeAll(", ");
            try writeEdge(program, writer, branch.true_edge);
            try writer.writeAll(", ");
            try writeEdge(program, writer, branch.false_edge);
        },
        .end_thread => try writer.writeAll("end_thread"),
        .@"unreachable" => try writer.writeAll("unreachable"),
    }
}

fn writeBlockParameter(program: *const program_ir.Program, writer: *std.Io.Writer, parameter: pseudo.BlockParameter) !void {
    switch (parameter) {
        .register => |register_id| try writeVirtualRegisterRef(program, writer, register_id),
        .flag => |flag_id| try writeVirtualFlagRef(program, writer, flag_id),
    }
}

fn writeEdge(program: *const program_ir.Program, writer: *std.Io.Writer, edge: inst_ir.Edge) !void {
    try writeBlockRef(program, writer, edge.target);
    if (edge.arguments.len == 0)
        return;

    const execution_size: device.ExecutionSize = @enumFromInt(@intFromEnum(program.dispatch_width));
    try writer.writeByte('(');
    for (edge.arguments, 0..) |argument, index| {
        if (index != 0)
            try writer.writeAll(", ");
        switch (argument) {
            .source => |source| try writeSource(program, writer, execution_size, source),
            .predicate => |predicate_value| switch (predicate_value) {
                .constant => |value| try writer.writeAll(if (value) "true" else "false"),
                .dynamic => |predicate| try writePredicate(program, writer, predicate),
            },
        }
    }
    try writer.writeByte(')');
}

fn writeSource(program: *const program_ir.Program, writer: *std.Io.Writer, execution_size: device.ExecutionSize, source: operand.Source) !void {
    if (source.negate)
        try writer.writeByte('-');
    if (source.absolute)
        try writer.writeAll("abs(");

    try writeRegister(program, writer, source.register);
    try writer.print(":{t}", .{source.type});
    if (source.register != .immediate)
        try writeSourceRegion(writer, execution_size, source.register, source.region);

    if (source.absolute)
        try writer.writeByte(')');
}

fn writeDestination(program: *const program_ir.Program, writer: *std.Io.Writer, execution_size: device.ExecutionSize, destination: operand.Destination) !void {
    _ = execution_size;
    try writeRegister(program, writer, destination.register);
    try writer.print(":{t}", .{destination.type});
    try writeDestinationRegion(writer, destination.register, destination.region);
}

fn writeSourceRegion(writer: *std.Io.Writer, execution_size: device.ExecutionSize, register: operand.RegisterRef, region: operand.Region) !void {
    const byte_offset = registerByteOffset(register) + region.byte_offset;
    const execution_width: u8 = @intFromEnum(execution_size);
    const is_default = region.vertical_stride == execution_width and
        region.width == execution_width and
        region.horizontal_stride == 1;
    const is_broadcast = region.vertical_stride == 0 and
        region.width == 1 and
        region.horizontal_stride == 0;

    if (byte_offset == 0 and is_default)
        return;

    try writer.writeByte('[');
    if (byte_offset != 0)
        try writer.print("byte={d}", .{byte_offset});

    if (is_broadcast) {
        if (byte_offset != 0)
            try writer.writeAll(", ");
        try writer.writeAll("broadcast");
    } else if (!is_default) {
        if (byte_offset != 0)
            try writer.writeAll(", ");
        try writer.print("vstride={d}, width={d}, hstride={d}", .{
            region.vertical_stride,
            region.width,
            region.horizontal_stride,
        });
    }
    try writer.writeByte(']');
}

fn writeDestinationRegion(writer: *std.Io.Writer, register: operand.RegisterRef, region: operand.DestinationRegion) !void {
    const byte_offset = registerByteOffset(register) + region.byte_offset;
    if (byte_offset == 0 and region.horizontal_stride == 1)
        return;

    try writer.writeByte('[');
    if (byte_offset != 0)
        try writer.print("byte={d}", .{byte_offset});
    if (region.horizontal_stride != 1) {
        if (byte_offset != 0)
            try writer.writeAll(", ");
        try writer.print("hstride={d}", .{region.horizontal_stride});
    }
    try writer.writeByte(']');
}

fn registerByteOffset(register: operand.RegisterRef) u16 {
    return switch (register) {
        .physical_grf => |physical| physical.byte_offset,
        else => 0,
    };
}

fn writeRegister(program: *const program_ir.Program, writer: *std.Io.Writer, register: operand.RegisterRef) !void {
    switch (register) {
        .virtual => |virtual| try writeVirtualRegisterRef(program, writer, virtual),
        .physical_grf => |physical| try writer.print("r{d}", .{physical.number}),
        .architecture => |architecture| try writeArchitectureRegister(writer, architecture),
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

fn writeBufferReference(program: *const program_ir.Program, writer: *std.Io.Writer, reference: inst_ir.BufferReference) !void {
    switch (reference) {
        .logical => |buffer| try writeStorageBufferRef(program, writer, buffer),
        .binding_table => |index| try writer.print("bti({d})", .{index}),
    }
}

fn writeStorageBufferRef(program: *const program_ir.Program, writer: *std.Io.Writer, buffer_id: ids.StorageBufferId) !void {
    const buffer = program.storage_buffers.get(buffer_id);
    try writeNamedRef(writer, if (buffer) |value| value.name else null, "buffer", buffer_id.index(), '@');
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
