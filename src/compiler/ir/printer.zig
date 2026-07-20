const std = @import("std");
const ids = @import("id.zig");
const inst_ir = @import("instruction.zig");
const module_ir = @import("module.zig");

const indent = "    ";

pub fn write(module: *const module_ir.Module, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("shader {t}", .{module.stage});

    if (module.entry_point) |entry| {
        try writer.writeByte(' ');
        try writeFunctionRef(module, writer, entry);
    }

    try writer.writeAll("\n{\n");

    for (module.interface_variables.entries.items, 0..) |entry, index| {
        const variable = entry orelse continue;

        try writer.writeAll(indent);
        try writeNamedRef(writer, variable.name, "interface", index);
        try writer.writeAll(": ");
        try writeType(module, writer, variable.type);
        try writer.print(" = {t}[", .{variable.direction});

        switch (variable.semantic) {
            .location => |location| try writer.print("location({d}), component({d}), index({d})", .{ location.location, location.component, location.index }),
            .builtin => |builtin| try writer.print("builtin({t})", .{builtin}),
        }

        try writer.writeAll("]\n");
    }

    for (module.constants.entries.items, 0..) |entry, constant_index| {
        const constant = entry orelse continue;
        const value_id = constantValueId(module, ids.ConstantId.fromIndex(constant_index)) orelse continue;

        try writer.writeAll(indent);
        try writeValueRef(module, writer, value_id);
        try writer.writeAll(": constant ");
        try writeType(module, writer, constant.type);
        try writer.writeAll(" = ");

        switch (constant.value) {
            .boolean => |value| try writer.print("{}", .{value}),
            .integer_bits => |bits| try writer.print("bits(0x{x})", .{bits}),
            .float_bits => |bits| try writer.print("bits(0x{x})", .{bits}),
            .null => try writer.writeAll("null"),
            .undef => try writer.writeAll("undef"),
            .composite => |elements| {
                try writer.writeByte('[');
                for (elements, 0..) |element, index| {
                    if (index != 0) try writer.writeAll(", ");
                    try writer.print("#{d}", .{element.index()});
                }
                try writer.writeByte(']');
            },
        }

        try writer.writeByte('\n');
    }

    for (module.functions.entries.items, 0..) |entry, function_index| {
        const function = entry orelse continue;

        try writer.writeAll("\n" ++ indent ++ "fn ");
        try writeNamedRef(writer, function.name, "fn", function_index);
        try writer.writeByte('(');
        for (function.parameters.items, 0..) |parameter, index| {
            if (index != 0)
                try writer.writeAll(", ");
            try writeValueRef(module, writer, parameter);
            try writer.writeAll(": ");
            try writeType(module, writer, function.parameter_types.items[index]);
        }
        try writer.writeAll(") -> ");
        try writeType(module, writer, function.return_type);
        try writer.writeAll("\n" ++ indent ++ "{\n");

        for (function.blocks.items) |block_id| {
            const block = module.blocks.get(block_id) orelse continue;

            try writer.writeAll(indent ** 2);
            try writeBlockRef(module, writer, block_id);
            try writer.writeByte('(');
            for (block.parameters.items, 0..) |parameter, index| {
                if (index != 0) try writer.writeAll(", ");
                try writeValueRef(module, writer, parameter);
                try writer.writeAll(": ");
                try writeType(module, writer, module.typeOf(parameter).?);
            }
            try writer.writeAll("):\n");

            for (block.instructions.items) |instruction_id| {
                const instruction = module.instructions.get(instruction_id) orelse continue;
                try writer.writeAll(indent ** 3);
                if (instruction.result) |result| {
                    try writeValueRef(module, writer, result);
                    try writer.writeAll(": ");
                    try writeType(module, writer, module.typeOf(result).?);
                    try writer.writeAll(" = ");
                }
                try writeOperation(module, writer, instruction.operation);
                try writer.writeByte('\n');
            }

            if (block.terminator) |terminator| {
                try writer.writeAll(indent ** 3);
                try writeTerminator(module, writer, terminator);
                try writer.writeAll("\n\n");
            } else {
                try writer.writeAll(indent ** 3 ++ "<missing terminator>\n\n");
            }
        }
        try writer.writeAll(indent ++ "}\n");
    }
    try writer.writeAll("}\n");
}

pub fn allocPrint(allocator: std.mem.Allocator, module: *const module_ir.Module) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try write(module, &output.writer);
    return output.toOwnedSlice();
}

fn writeType(module: *const module_ir.Module, writer: *std.Io.Writer, type_id: ids.TypeId) !void {
    const ty = module.types.get(type_id) orelse {
        try writer.print("<invalid-type-{d}>", .{type_id.index()});
        return;
    };

    switch (ty.*) {
        .void => try writer.writeAll("void"),
        .boolean => try writer.writeAll("bool"),
        .integer => |integer| try writer.print("{s}{d}", .{ if (integer.signedness == .signed) "i" else "u", integer.bits }),
        .floating => |float| try writer.print("f{d}", .{float.bits}),
        .vector => |vector| {
            try writer.print("vec{d}[", .{vector.length});
            try writeType(module, writer, vector.element_type);
            try writer.writeByte(']');
        },
        .array => |array| {
            try writer.writeAll("array[");
            try writeType(module, writer, array.element_type);
            try writer.print(", {d}]", .{array.length});
        },
        .structure => |structure| {
            try writer.writeAll("struct[");
            for (structure.members, 0..) |member, index| {
                if (index != 0) try writer.writeAll(", ");
                try writeType(module, writer, member);
            }
            try writer.writeByte(']');
        },
        .pointer => |pointer| {
            try writer.print("ptr[{t}, ", .{pointer.address_space});
            try writeType(module, writer, pointer.pointee_type);
            try writer.writeByte(']');
        },
        .resource_handle => |handle| try writer.print("resourceHandle[{t}]", .{handle.kind}),
    }
}

fn writeOperation(module: *const module_ir.Module, writer: *std.Io.Writer, operation: inst_ir.Operation) !void {
    switch (operation) {
        .unary => |op| {
            try writer.print("{t} ", .{op.opcode});
            try writeValueRef(module, writer, op.operand);
        },
        .binary => |op| {
            try writer.print("{t} ", .{op.opcode});
            try writeValueRef(module, writer, op.lhs);
            try writer.writeAll(", ");
            try writeValueRef(module, writer, op.rhs);
        },
        .compare => |op| {
            try writer.print("cmp_{t} ", .{op.opcode});
            try writeValueRef(module, writer, op.lhs);
            try writer.writeAll(", ");
            try writeValueRef(module, writer, op.rhs);
        },
        .select => |op| {
            try writer.writeAll("select ");
            try writeValueRef(module, writer, op.condition);
            try writer.writeAll(", ");
            try writeValueRef(module, writer, op.true_value);
            try writer.writeAll(", ");
            try writeValueRef(module, writer, op.false_value);
        },
        .bitcast => |value| {
            try writer.writeAll("bitcast ");
            try writeValueRef(module, writer, value);
        },
        .composite_construct => |op| {
            try writer.writeAll("composite_construct ");
            try writeValueList(module, writer, op.elements);
        },
        .composite_extract => |op| {
            try writer.writeAll("composite_extract ");
            try writeValueRef(module, writer, op.composite);
            for (op.indices) |index| try writer.print("[{d}]", .{index});
        },
        .load_interface => |op| {
            try writer.writeAll("load_interface ");
            const variable = module.interface_variables.get(op.variable);
            try writeNamedRef(writer, if (variable) |v| v.name else null, "interface", op.variable.index());
        },
        .store_interface => |op| {
            try writer.writeAll("store_interface ");
            const variable = module.interface_variables.get(op.variable);
            try writeNamedRef(writer, if (variable) |v| v.name else null, "interface", op.variable.index());
            try writer.writeAll(", ");
            try writeValueRef(module, writer, op.value);
        },
        .call => |op| {
            try writer.writeAll("call ");
            try writeFunctionRef(module, writer, op.function);
            try writer.writeByte('(');
            try writeValueList(module, writer, op.arguments);
            try writer.writeByte(')');
        },
    }
}

fn writeTerminator(module: *const module_ir.Module, writer: *std.Io.Writer, terminator: module_ir.Terminator) !void {
    switch (terminator) {
        .branch => |edge| {
            try writer.writeAll("branch ");
            try writeEdge(module, writer, edge);
        },
        .conditional_branch => |branch| {
            try writer.writeAll("conditional_branch ");
            try writeValueRef(module, writer, branch.condition);
            try writer.writeAll(", ");
            try writeEdge(module, writer, branch.true_edge);
            try writer.writeAll(", ");
            try writeEdge(module, writer, branch.false_edge);
        },
        .return_void => try writer.writeAll("return"),
        .return_value => |value| {
            try writer.writeAll("return ");
            try writeValueRef(module, writer, value);
        },
        .discard => try writer.writeAll("discard"),
        .@"unreachable" => try writer.writeAll("unreachable"),
    }
}

fn writeEdge(module: *const module_ir.Module, writer: *std.Io.Writer, edge: module_ir.Edge) !void {
    try writeBlockRef(module, writer, edge.target);
    try writer.writeByte('(');
    try writeValueList(module, writer, edge.arguments);
    try writer.writeByte(')');
}

fn writeValueList(module: *const module_ir.Module, writer: *std.Io.Writer, value_ids: []const ids.ValueId) !void {
    for (value_ids, 0..) |value, index| {
        if (index != 0)
            try writer.writeAll(", ");
        try writeValueRef(module, writer, value);
    }
}

fn writeValueRef(module: *const module_ir.Module, writer: *std.Io.Writer, value_id: ids.ValueId) !void {
    try writer.writeByte('%');

    const value = module.values.get(value_id);
    if (value) |data| {
        if (data.name) |name| {
            if (isValidName(name) and isUniqueValueName(module, value_id, name)) {
                try writer.writeAll(name);
                return;
            }
        }
    }

    try writer.print("{d}", .{value_id.index()});
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

fn isUniqueValueName(module: *const module_ir.Module, value_id: ids.ValueId, name: []const u8) bool {
    for (module.values.entries.items, 0..) |entry, index| {
        if (index == value_id.index())
            continue;

        const other = entry orelse continue;
        if (other.name) |other_name| {
            if (std.mem.eql(u8, name, other_name))
                return false;
        }
    }
    return true;
}

fn writeBlockRef(module: *const module_ir.Module, writer: *std.Io.Writer, block: ids.BlockId) !void {
    const value = module.blocks.get(block);
    try writeNamedRef(writer, if (value) |b| b.name else null, "b", block.index());
}

fn writeFunctionRef(module: *const module_ir.Module, writer: *std.Io.Writer, function: ids.FunctionId) !void {
    const value = module.functions.get(function);
    try writeNamedRef(writer, if (value) |f| f.name else null, "fn", function.index());
}

fn writeNamedRef(writer: *std.Io.Writer, name: ?[]const u8, fallback: []const u8, index: usize) !void {
    try writer.writeByte(if (std.mem.eql(u8, fallback, "b")) '.' else '@');
    if (name) |text| {
        if (isValidName(text)) {
            try writer.writeAll(text);
            return;
        }
    }
    try writer.print("{s}{d}", .{ fallback, index });
}

fn constantValueId(module: *const module_ir.Module, constant_id: ids.ConstantId) ?ids.ValueId {
    for (module.values.entries.items, 0..) |entry, index| {
        const value = entry orelse continue;
        if (value.definition == .constant and value.definition.constant == constant_id)
            return ids.ValueId.fromIndex(index);
    }

    return null;
}
