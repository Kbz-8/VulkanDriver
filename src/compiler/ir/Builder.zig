const std = @import("std");
const ids = @import("id.zig");
const type_ir = @import("type.zig");
const constant_ir = @import("constant.zig");
const inst_ir = @import("instruction.zig");
const module_ir = @import("module.zig");

const Self = @This();

module: *module_ir.Module,

pub fn init(module: *module_ir.Module) Self {
    return .{ .module = module };
}

fn copyName(self: *Self, name: ?[]const u8) !?[]const u8 {
    return if (name) |text| try self.module.allocator().dupe(u8, text) else null;
}

pub fn internType(self: *Self, ty: type_ir.Type) !ids.TypeId {
    return self.module.internType(ty);
}

pub fn internConstant(self: *Self, ty: ids.TypeId, candidate: constant_ir.ConstantValue) !ids.ValueId {
    for (self.module.constants.entries.items, 0..) |entry, index| {
        const existing = entry orelse continue;

        if (existing.type == ty and constantEql(existing.value, candidate)) {
            const constant_id = ids.ConstantId.fromIndex(index);

            for (self.module.values.entries.items, 0..) |value_entry, value_index| {
                const value = value_entry orelse continue;

                if (value.definition == .constant and value.definition.constant == constant_id)
                    return ids.ValueId.fromIndex(value_index);
            }
        }
    }

    var owned = candidate;
    if (candidate == .composite)
        owned.composite = try self.module.allocator().dupe(ids.ConstantId, candidate.composite);

    const constant_id = try self.module.constants.add(self.module.allocator(), .{ .type = ty, .value = owned });
    return self.module.values.add(self.module.allocator(), .{
        .type = ty,
        .definition = .{ .constant = constant_id },
    });
}

pub fn setValueName(self: *Self, value_id: ids.ValueId, name: ?[]const u8) !void {
    const text = name orelse return;
    const value = self.module.values.getMut(value_id) orelse return error.InvalidValue;

    if (value.name == null)
        value.name = try self.copyName(text);
}

pub fn addFunction(self: *Self, return_type: ids.TypeId, name: ?[]const u8) !ids.FunctionId {
    return self.module.functions.add(self.module.allocator(), .{
        .return_type = return_type,
        .name = try self.copyName(name),
    });
}

pub fn setEntryPoint(self: *Self, function: ids.FunctionId) void {
    self.module.entry_point = function;
}

pub fn addFunctionParameter(self: *Self, function_id: ids.FunctionId, ty: ids.TypeId, name: ?[]const u8) !ids.ValueId {
    const function = self.module.functions.getMut(function_id) orelse return error.InvalidFunction;
    const index: u32 = @intCast(function.parameters.items.len);

    const value_id = try self.module.values.add(self.module.allocator(), .{
        .type = ty,
        .definition = .{ .function_parameter = .{ .function = function_id, .index = index } },
        .name = try self.copyName(name),
    });

    try function.parameter_types.append(self.module.allocator(), ty);
    try function.parameters.append(self.module.allocator(), value_id);

    return value_id;
}

pub fn addBlock(self: *Self, function_id: ids.FunctionId, name: ?[]const u8) !ids.BlockId {
    const function = self.module.functions.getMut(function_id) orelse return error.InvalidFunction;

    const block_id = try self.module.blocks.add(self.module.allocator(), .{
        .parent_function = function_id,
        .name = try self.copyName(name),
    });

    try function.blocks.append(self.module.allocator(), block_id);
    if (function.entry_block == null)
        function.entry_block = block_id;

    return block_id;
}

pub fn addBlockParameter(self: *Self, block_id: ids.BlockId, ty: ids.TypeId, name: ?[]const u8) !ids.ValueId {
    const block = self.module.blocks.getMut(block_id) orelse return error.InvalidBlock;
    const index: u32 = @intCast(block.parameters.items.len);

    const value_id = try self.module.values.add(self.module.allocator(), .{
        .type = ty,
        .definition = .{ .block_parameter = .{ .block = block_id, .index = index } },
        .name = try self.copyName(name),
    });

    try block.parameters.append(self.module.allocator(), value_id);

    return value_id;
}

pub fn appendInstruction(
    self: *Self,
    block_id: ids.BlockId,
    result_type: ?ids.TypeId,
    operation: inst_ir.Operation,
    name: ?[]const u8,
) !?ids.ValueId {
    const block = self.module.blocks.getMut(block_id) orelse return error.InvalidBlock;
    const owned_operation = try self.copyOperation(operation);

    const instruction_id = try self.module.instructions.add(self.module.allocator(), .{
        .parent_block = block_id,
        .result = null,
        .operation = owned_operation,
    });
    errdefer _ = self.module.instructions.remove(instruction_id);

    const result = if (result_type) |ty|
        try self.module.values.add(self.module.allocator(), .{
            .type = ty,
            .definition = .{ .instruction = instruction_id },
            .name = try self.copyName(name),
        })
    else
        null;

    self.module.instructions.getMut(instruction_id).?.result = result;
    try block.instructions.append(self.module.allocator(), instruction_id);

    return result;
}

pub fn setTerminator(self: *Self, block_id: ids.BlockId, terminator: module_ir.Terminator) !void {
    const block = self.module.blocks.getMut(block_id) orelse return error.InvalidBlock;

    if (block.terminator != null)
        return error.TerminatorAlreadySet;

    block.terminator = try self.copyTerminator(terminator);
}

pub fn addInterfaceVariable(
    self: *Self,
    ty: ids.TypeId,
    direction: module_ir.InterfaceDirection,
    semantic: module_ir.InterfaceSemantic,
    name: ?[]const u8,
) !ids.InterfaceVariableId {
    return self.module.interface_variables.add(self.module.allocator(), .{
        .type = ty,
        .direction = direction,
        .semantic = semantic,
        .name = try self.copyName(name),
    });
}

pub fn edge(self: *Self, target: ids.BlockId, arguments: []const ids.ValueId) !module_ir.Edge {
    return .{
        .target = target,
        .arguments = try self.module.allocator().dupe(ids.ValueId, arguments),
    };
}

fn copyOperation(self: *Self, operation: inst_ir.Operation) !inst_ir.Operation {
    return switch (operation) {
        .composite_construct => |op| .{
            .composite_construct = .{
                .elements = try self.module.allocator().dupe(ids.ValueId, op.elements),
            },
        },
        .composite_extract => |op| .{
            .composite_extract = .{
                .composite = op.composite,
                .indices = try self.module.allocator().dupe(u32, op.indices),
            },
        },
        .call => |op| .{
            .call = .{
                .function = op.function,
                .arguments = try self.module.allocator().dupe(ids.ValueId, op.arguments),
            },
        },
        else => operation,
    };
}

fn copyTerminator(self: *Self, terminator: module_ir.Terminator) !module_ir.Terminator {
    return switch (terminator) {
        .branch => |edge_value| .{
            .branch = try self.edge(edge_value.target, edge_value.arguments),
        },
        .conditional_branch => |branch| .{
            .conditional_branch = .{
                .condition = branch.condition,
                .true_edge = try self.edge(branch.true_edge.target, branch.true_edge.arguments),
                .false_edge = try self.edge(branch.false_edge.target, branch.false_edge.arguments),
            },
        },
        else => terminator,
    };
}

fn constantEql(a: constant_ir.ConstantValue, b: constant_ir.ConstantValue) bool {
    return switch (a) {
        .boolean => |value| b == .boolean and value == b.boolean,
        .integer_bits => |value| b == .integer_bits and value == b.integer_bits,
        .float_bits => |value| b == .float_bits and value == b.float_bits,
        .null => b == .null,
        .undef => b == .undef,
        .composite => |value| b == .composite and std.mem.eql(ids.ConstantId, value, b.composite),
    };
}

test "Builder: generation" {
    const cfg = @import("cfg.zig");
    const parser = @import("parser/parser.zig");
    const printer = @import("printer.zig");
    const validator = @import("validator/validator.zig");

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

    var module = module_ir.Module.init(std.testing.allocator, .vertex);
    defer module.deinit();
    var builder = Self.init(&module);

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

    try validator.validate(&module);

    var control_flow = try cfg.init(std.testing.allocator, &module, main);
    defer control_flow.deinit();
    try std.testing.expectEqual(@as(usize, 2), control_flow.predecessors(merge).?.len);
    try std.testing.expect(control_flow.dominates(entry, merge));
    try std.testing.expect(!control_flow.dominates(pass, merge));

    const text = try printer.allocPrint(std.testing.allocator, &module);

    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "shader vertex @main") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "@color: vec4[f32] = input[location(0), component(0), index(0)]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "@out_color: vec4[f32] = output[location(0), component(0), index(0)]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "conditional_branch %0, .pass(), .merge(%loaded)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".merge(%merged: vec4[f32])") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store_interface @out_color, %merged") != null);

    var parsed = try parser.parseString(std.testing.allocator, text);
    defer parsed.deinit();
    const round_trip = try printer.allocPrint(std.testing.allocator, &parsed);
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

    var parsed_file = try parser.parseFile(std.testing.allocator, io, path);
    defer parsed_file.deinit();
    const file_round_trip = try printer.allocPrint(std.testing.allocator, &parsed_file);
    defer std.testing.allocator.free(file_round_trip);
    try std.testing.expectEqualStrings(text, file_round_trip);
}
