const std = @import("std");
const shader_compiler = @import("shader_ir");
const shader_ir = shader_compiler.ir;
const device = @import("../device.zig");
const Builder = @import("../ir/Builder.zig");
const ids = @import("../ir/id.zig");
const instruction = @import("../ir/instruction.zig");
const operand = @import("../ir/operand.zig");
const printer = @import("../ir/printer.zig");
const pseudo = @import("../ir/pseudo.zig");
const program_ir = @import("../ir/program.zig");
const validator = @import("../ir/validator.zig");

pub const block_arguments = @import("block_arguments.zig");

pub const Options = struct {
    dispatch_width: device.DispatchWidth = .simd8,
};

pub const Error = std.mem.Allocator.Error || error{
    MissingEntryPoint,
    InvalidEntryPoint,
    InvalidModule,
    InvalidLoweredProgram,
    SanitizationFailed,
    UnsanitizedModule,
    UnsupportedStage,
    MissingWorkgroupSize,
    UnsupportedType,
    UnsupportedOperation,
    UnsupportedTerminator,
};

const PredicateValue = pseudo.PredicateValue;

const LoweredType = struct {
    element_type: operand.DataType,
    component_count: usize,
};

const ValueLocation = union(enum) {
    components: []const operand.Source,
    predicate: PredicateValue,
};

const LoweringState = struct {
    lowerer: *Lowerer,
    builder: Builder,
    storage: std.mem.Allocator,
    block_map: []?ids.BlockId,
    value_locations: []?ValueLocation,
    storage_buffer_map: []?ids.StorageBufferId,

    fn lowerScalarType(self: *const LoweringState, type_id: shader_ir.id.TypeId) Error!operand.DataType {
        const ty = self.lowerer.module.types.get(type_id) orelse return Error.InvalidModule;
        return switch (ty.*) {
            .integer => |integer| if (integer.bits == 32)
                switch (integer.signedness) {
                    .unsigned => .u32,
                    .signed => .i32,
                }
            else
                Error.UnsupportedType,
            .floating => |floating| if (floating.bits == 32) .f32 else Error.UnsupportedType,
            else => Error.UnsupportedType,
        };
    }

    fn lowerType(self: *const LoweringState, type_id: shader_ir.id.TypeId) Error!LoweredType {
        const ty = self.lowerer.module.types.get(type_id) orelse return Error.InvalidModule;
        return switch (ty.*) {
            .integer, .floating => .{
                .element_type = try self.lowerScalarType(type_id),
                .component_count = 1,
            },
            .vector => |vector| if (vector.length >= 2 and vector.length <= 4)
                .{
                    .element_type = try self.lowerScalarType(vector.element_type),
                    .component_count = vector.length,
                }
            else
                Error.UnsupportedType,
            else => Error.UnsupportedType,
        };
    }

    fn isBoolean(self: *const LoweringState, type_id: shader_ir.id.TypeId) Error!bool {
        const ty = self.lowerer.module.types.get(type_id) orelse return Error.InvalidModule;
        return ty.* == .boolean;
    }

    fn mappedBlock(self: *const LoweringState, source_id: shader_ir.id.BlockId) Error!ids.BlockId {
        if (source_id.index() >= self.block_map.len)
            return Error.InvalidModule;
        return self.block_map[source_id.index()] orelse Error.InvalidModule;
    }

    fn storageBuffer(self: *LoweringState, source_id: shader_ir.id.ResourceId) Error!ids.StorageBufferId {
        if (source_id.index() >= self.storage_buffer_map.len)
            return Error.InvalidModule;
        if (self.storage_buffer_map[source_id.index()]) |existing|
            return existing;

        const resource = self.lowerer.module.resources.get(source_id) orelse return Error.InvalidModule;
        if (resource.kind != .storage_buffer)
            return Error.UnsupportedOperation;
        const buffer_id = self.builder.addStorageBuffer(.{
            .set = resource.set,
            .binding = resource.binding,
            .name = resource.name,
        }) catch |err| return mapProgramError(err);
        self.storage_buffer_map[source_id.index()] = buffer_id;
        return buffer_id;
    }

    fn putLocation(self: *LoweringState, value_id: shader_ir.id.ValueId, new_location: ValueLocation) Error!void {
        if (value_id.index() >= self.value_locations.len or self.value_locations[value_id.index()] != null)
            return Error.InvalidModule;
        self.value_locations[value_id.index()] = new_location;
    }

    fn addRegister(self: *LoweringState, data_type: operand.DataType, class: operand.RegisterClass, name: ?[]const u8) Error!ids.VirtualRegisterId {
        return self.builder.addVirtualRegister(.{
            .size_bytes = @as(u32, data_type.sizeBytes()) * @intFromEnum(self.lowerer.options.dispatch_width),
            .alignment_bytes = self.lowerer.device_info.grf_size_bytes,
            .element_type = data_type,
            .lane_count = @intFromEnum(self.lowerer.options.dispatch_width),
            .class = class,
            .name = name,
        }) catch |err| return mapProgramError(err);
    }

    fn executionSize(self: *const LoweringState) device.ExecutionSize {
        return @enumFromInt(@intFromEnum(self.lowerer.options.dispatch_width));
    }

    fn registerSource(self: *const LoweringState, register_id: ids.VirtualRegisterId, data_type: operand.DataType) operand.Source {
        return .{
            .register = .{ .virtual = register_id },
            .type = data_type,
            .region = operand.Region.contiguous(self.executionSize()),
        };
    }

    fn componentName(self: *LoweringState, name: ?[]const u8, component_index: usize, component_count: usize) Error!?[]const u8 {
        if (name == null or component_count == 1)
            return name;
        const suffixes = "xyzw";
        const formatted = try std.fmt.allocPrint(self.storage, "{s}_{c}", .{ name.?, suffixes[component_index] });
        return @as([]const u8, formatted);
    }

    fn addRegisterLocation(self: *LoweringState, value_id: shader_ir.id.ValueId, class: operand.RegisterClass) Error![]const operand.Source {
        const value = self.lowerer.module.values.get(value_id) orelse return Error.InvalidModule;
        const lowered_type = try self.lowerType(value.type);
        const result = try self.storage.alloc(operand.Source, lowered_type.component_count);
        for (result, 0..) |*component, component_index| {
            const register_id = try self.addRegister(
                lowered_type.element_type,
                class,
                try self.componentName(value.name, component_index, lowered_type.component_count),
            );
            component.* = self.registerSource(register_id, lowered_type.element_type);
        }
        try self.putLocation(value_id, .{ .components = result });
        return result;
    }

    fn location(self: *LoweringState, value_id: shader_ir.id.ValueId) Error!ValueLocation {
        if (value_id.index() >= self.value_locations.len)
            return Error.InvalidModule;

        if (self.value_locations[value_id.index()]) |existing|
            return existing;

        const value = self.lowerer.module.values.get(value_id) orelse return Error.InvalidModule;
        switch (value.definition) {
            .constant => |constant_id| {
                const constant = self.lowerer.module.constants.get(constant_id) orelse return Error.InvalidModule;
                if (constant.type != value.type)
                    return Error.InvalidModule;

                const result: ValueLocation = if (try self.isBoolean(value.type)) switch (constant.value) {
                    .boolean => |boolean| .{ .predicate = .{ .constant = boolean } },
                    else => return Error.UnsupportedType,
                } else .{
                    .components = try self.constantComponents(value.type, constant.value),
                };
                self.value_locations[value_id.index()] = result;
                return result;
            },
            .undef => {
                if (try self.isBoolean(value.type))
                    return Error.UnsupportedType;
                _ = try self.addRegisterLocation(value_id, .temporary);
                return self.value_locations[value_id.index()].?;
            },
            else => return Error.InvalidModule,
        }
    }

    fn components(self: *LoweringState, value_id: shader_ir.id.ValueId) Error![]const operand.Source {
        return switch (try self.location(value_id)) {
            .components => |values| values,
            .predicate => Error.UnsupportedType,
        };
    }

    fn source(self: *LoweringState, value_id: shader_ir.id.ValueId) Error!operand.Source {
        const values = try self.components(value_id);
        if (values.len != 1)
            return Error.UnsupportedType;
        return values[0];
    }

    fn predicate(self: *LoweringState, value_id: shader_ir.id.ValueId) Error!PredicateValue {
        return switch (try self.location(value_id)) {
            .components => Error.UnsupportedType,
            .predicate => |value| value,
        };
    }

    fn destinationFromSource(source_value: operand.Source) Error!operand.Destination {
        if (source_value.negate or source_value.absolute)
            return Error.InvalidLoweredProgram;

        return switch (source_value.register) {
            .virtual => .{
                .register = source_value.register,
                .type = source_value.type,
                .region = .{ .byte_offset = source_value.region.byte_offset },
            },
            else => Error.InvalidLoweredProgram,
        };
    }

    fn destination(self: *LoweringState, value_id: shader_ir.id.ValueId) Error!operand.Destination {
        return destinationFromSource(try self.source(value_id));
    }

    fn constantComponents(self: *LoweringState, type_id: shader_ir.id.TypeId, value: shader_ir.constant.ConstantValue) Error![]const operand.Source {
        const lowered_type = try self.lowerType(type_id);
        const result = try self.storage.alloc(operand.Source, lowered_type.component_count);
        if (lowered_type.component_count == 1) {
            result[0] = try self.constantScalarSource(type_id, value);
            return result;
        }

        const ty = self.lowerer.module.types.get(type_id) orelse return Error.InvalidModule;
        const vector = switch (ty.*) {
            .vector => |vector| vector,
            else => return Error.InvalidModule,
        };
        switch (value) {
            .composite => |elements| {
                if (elements.len != lowered_type.component_count)
                    return Error.InvalidModule;
                for (elements, result) |constant_id, *component| {
                    const element = self.lowerer.module.constants.get(constant_id) orelse return Error.InvalidModule;
                    if (element.type != vector.element_type)
                        return Error.InvalidModule;
                    component.* = try self.constantScalarSource(element.type, element.value);
                }
            },
            .null => {
                const zero: shader_ir.constant.ConstantValue = switch (lowered_type.element_type) {
                    .u32, .i32 => .{ .integer_bits = 0 },
                    .f32 => .{ .float_bits = 0 },
                    else => unreachable,
                };
                for (result) |*component|
                    component.* = try self.constantScalarSource(vector.element_type, zero);
            },
            else => return Error.UnsupportedType,
        }
        return result;
    }

    fn constantScalarSource(self: *const LoweringState, type_id: shader_ir.id.TypeId, value: shader_ir.constant.ConstantValue) Error!operand.Source {
        const data_type = try self.lowerScalarType(type_id);
        const immediate: operand.Immediate = switch (data_type) {
            .u32 => switch (value) {
                .integer_bits => |bits| .{ .u32 = @truncate(bits) },
                else => return Error.UnsupportedType,
            },
            .i32 => switch (value) {
                .integer_bits => |bits| .{ .i32 = @bitCast(@as(u32, @truncate(bits))) },
                else => return Error.UnsupportedType,
            },
            .f32 => switch (value) {
                .float_bits => |bits| .{ .f32 = @bitCast(@as(u32, @truncate(bits))) },
                else => return Error.UnsupportedType,
            },
            else => unreachable,
        };

        return .{
            .register = .{ .immediate = immediate },
            .type = data_type,
            .region = operand.Region.broadcast(),
        };
    }

    fn appendInstruction(self: *LoweringState, block_id: ids.BlockId, predicate_value: ?operand.Predicate, operation: instruction.Operation) Error!void {
        _ = self.builder.appendInstruction(block_id, self.executionSize(), predicate_value, operation) catch |err|
            return mapProgramError(err);
    }

    fn appendMove(self: *LoweringState, block_id: ids.BlockId, predicate_value: ?operand.Predicate, destination_value: operand.Destination, source_value: operand.Source) Error!void {
        try self.appendInstruction(block_id, predicate_value, .{
            .move = .{
                .destination = destination_value,
                .source = source_value,
            },
        });
    }

    fn sourceEntryFunction(self: *const LoweringState) Error!struct { shader_ir.id.FunctionId, *const shader_ir.module.Function } {
        const source_entry = self.lowerer.module.entry_point orelse return Error.MissingEntryPoint;
        const function = self.lowerer.module.functions.get(source_entry) orelse return Error.InvalidEntryPoint;
        const return_type = self.lowerer.module.types.get(function.return_type) orelse return Error.InvalidModule;
        if (return_type.* != .void or function.parameters.items.len != 0)
            return Error.InvalidEntryPoint;
        return .{ source_entry, function };
    }

    fn lowerBlocks(self: *LoweringState) Error!void {
        const source_function_id, const function = try self.sourceEntryFunction();

        for (function.blocks.items) |source_block_id| {
            const source_block = self.lowerer.module.blocks.get(source_block_id) orelse return Error.InvalidModule;
            if (source_block.parent_function != source_function_id)
                return Error.InvalidModule;
            const target_block_id = self.builder.addBlock(source_block.name) catch |err|
                return mapProgramError(err);
            if (source_block_id.index() >= self.block_map.len or self.block_map[source_block_id.index()] != null)
                return Error.InvalidModule;
            self.block_map[source_block_id.index()] = target_block_id;
        }

        const source_entry = function.entry_block orelse return Error.InvalidModule;
        self.builder.setEntryBlock(try self.mappedBlock(source_entry)) catch |err| return mapProgramError(err);
    }

    fn lowerParameters(self: *LoweringState) Error!void {
        const source_entry = try self.sourceEntryFunction();
        const function = source_entry[1];

        for (function.blocks.items) |source_block_id| {
            const source_block = self.lowerer.module.blocks.get(source_block_id) orelse return Error.InvalidModule;
            const target_block_id = try self.mappedBlock(source_block_id);

            for (source_block.parameters.items) |parameter_id| {
                const value = self.lowerer.module.values.get(parameter_id) orelse return Error.InvalidModule;
                if (try self.isBoolean(value.type)) {
                    const flag_id = self.builder.addVirtualFlag(.{ .name = value.name }) catch |err|
                        return mapProgramError(err);
                    const predicate_value: operand.Predicate = .{ .flag = .{ .virtual = flag_id } };
                    try self.putLocation(parameter_id, .{ .predicate = .{ .dynamic = predicate_value } });
                    self.builder.addBlockParameter(target_block_id, .{ .flag = flag_id }) catch |err|
                        return mapProgramError(err);
                } else {
                    const parameter_components = try self.addRegisterLocation(parameter_id, .temporary);
                    for (parameter_components) |parameter_source| {
                        const register_id = switch (parameter_source.register) {
                            .virtual => |id| id,
                            else => return Error.InvalidLoweredProgram,
                        };
                        self.builder.addBlockParameter(target_block_id, .{ .register = register_id }) catch |err|
                            return mapProgramError(err);
                    }
                }
            }
        }
    }

    fn lowerInstructions(self: *LoweringState, allocator: std.mem.Allocator) Error!void {
        const visited = try allocator.alloc(bool, self.lowerer.module.blocks.entries.items.len);
        defer allocator.free(visited);
        @memset(visited, false);

        const source_entry = try self.sourceEntryFunction();
        const function = source_entry[1];
        try self.lowerBlockInstructions(function.entry_block orelse return Error.InvalidModule, visited);

        for (function.blocks.items) |source_block_id| {
            if (!visited[source_block_id.index()])
                try self.lowerBlockInstructions(source_block_id, visited);
        }
    }

    fn lowerBlockInstructions(self: *LoweringState, source_block_id: shader_ir.id.BlockId, visited: []bool) Error!void {
        if (source_block_id.index() >= visited.len)
            return Error.InvalidModule;

        if (visited[source_block_id.index()])
            return;

        visited[source_block_id.index()] = true;

        const block = self.lowerer.module.blocks.get(source_block_id) orelse return Error.InvalidModule;
        const target_block_id = try self.mappedBlock(source_block_id);
        for (block.instructions.items) |instruction_id| {
            const source_instruction = self.lowerer.module.instructions.get(instruction_id) orelse return Error.InvalidModule;
            if (source_instruction.parent_block != source_block_id)
                return Error.InvalidModule;
            try self.lowerInstruction(target_block_id, source_instruction.*);
        }

        switch (block.terminator orelse return Error.InvalidModule) {
            .branch => |edge| try self.lowerBlockInstructions(edge.target, visited),
            .conditional_branch => |branch| {
                try self.lowerBlockInstructions(branch.true_edge.target, visited);
                try self.lowerBlockInstructions(branch.false_edge.target, visited);
            },
            else => {},
        }
    }

    fn lowerInstruction(self: *LoweringState, block_id: ids.BlockId, source_instruction: shader_ir.instruction.Instruction) Error!void {
        switch (source_instruction.operation) {
            .unary => |operation| try self.lowerUnary(block_id, source_instruction.result, operation),
            .binary => |operation| try self.lowerBinary(block_id, source_instruction.result, operation),
            .compare => |operation| try self.lowerCompare(block_id, source_instruction.result, operation),
            .select => |operation| try self.lowerSelect(block_id, source_instruction.result, operation),
            .bitcast => |value_id| try self.lowerBitcast(block_id, source_instruction.result, value_id),
            .load_interface => |operation| try self.lowerLoadInterface(block_id, source_instruction.result, operation),
            .store_interface => |operation| try self.lowerStoreInterface(block_id, source_instruction.result, operation),
            .composite_construct => |operation| try self.lowerCompositeConstruct(source_instruction.result, operation),
            .composite_extract => |operation| try self.lowerCompositeExtract(source_instruction.result, operation),
            .load_buffer => |operation| try self.lowerLoadBuffer(block_id, source_instruction.result, operation),
            .store_buffer => |operation| try self.lowerStoreBuffer(block_id, source_instruction.result, operation),
            .call => return Error.UnsanitizedModule,
        }
    }

    fn requireResult(result: ?shader_ir.id.ValueId) Error!shader_ir.id.ValueId {
        return result orelse Error.InvalidModule;
    }

    fn requireNoResult(result: ?shader_ir.id.ValueId) Error!void {
        if (result != null)
            return Error.InvalidModule;
    }

    fn lowerUnary(self: *LoweringState, block_id: ids.BlockId, result: ?shader_ir.id.ValueId, operation: shader_ir.instruction.Unary) Error!void {
        const result_id = try requireResult(result);
        if (operation.opcode == .logical_not) {
            const source_predicate = try self.predicate(operation.operand);
            const inverted: PredicateValue = switch (source_predicate) {
                .constant => |value| .{ .constant = !value },
                .dynamic => |value| .{ .dynamic = .{
                    .flag = value.flag,
                    .inverse = !value.inverse,
                } },
            };
            try self.putLocation(result_id, .{ .predicate = inverted });
            return;
        }

        const source_components = try self.components(operation.operand);
        const result_components = try self.addRegisterLocation(result_id, .temporary);
        if (source_components.len != result_components.len)
            return Error.InvalidModule;

        for (source_components, result_components) |source_component, result_component| {
            if (source_component.type != result_component.type)
                return Error.InvalidModule;
            switch (operation.opcode) {
                .negate => {
                    if (source_component.type != .i32 and source_component.type != .f32)
                        return Error.UnsupportedOperation;
                    var negated = source_component;
                    negated.negate = !negated.negate;
                    try self.appendMove(block_id, null, try destinationFromSource(result_component), negated);
                },
                .bitwise_not => {
                    const all_ones: operand.Immediate = switch (source_component.type) {
                        .u32 => .{ .u32 = std.math.maxInt(u32) },
                        .i32 => .{ .i32 = -1 },
                        else => return Error.UnsupportedOperation,
                    };
                    try self.appendInstruction(block_id, null, .{
                        .binary = .{
                            .opcode = .bitwise_xor,
                            .destination = try destinationFromSource(result_component),
                            .lhs = source_component,
                            .rhs = .{
                                .register = .{ .immediate = all_ones },
                                .type = source_component.type,
                                .region = operand.Region.broadcast(),
                            },
                        },
                    });
                },
                .logical_not => unreachable,
            }
        }
    }

    fn lowerBinary(self: *LoweringState, block_id: ids.BlockId, result: ?shader_ir.id.ValueId, operation: shader_ir.instruction.Binary) Error!void {
        const result_id = try requireResult(result);
        const lhs_components = try self.components(operation.lhs);
        const rhs_components = try self.components(operation.rhs);
        const result_components = try self.addRegisterLocation(result_id, .temporary);
        if (lhs_components.len == 0 or lhs_components.len != rhs_components.len or lhs_components.len != result_components.len)
            return Error.InvalidModule;

        const data_type = lhs_components[0].type;
        const opcode: instruction.BinaryOpcode = switch (operation.opcode) {
            .integer_add => if (data_type == .u32 or data_type == .i32) .add else return Error.UnsupportedOperation,
            .float_add => if (data_type == .f32) .add else return Error.UnsupportedOperation,
            .integer_subtract => if (data_type == .u32 or data_type == .i32) .add else return Error.UnsupportedOperation,
            .float_subtract => if (data_type == .f32) .add else return Error.UnsupportedOperation,
            .integer_multiply => if (data_type == .u32 or data_type == .i32) .multiply else return Error.UnsupportedOperation,
            .float_multiply => if (data_type == .f32) .multiply else return Error.UnsupportedOperation,
            .shift_left => if (data_type == .u32 or data_type == .i32) .shift_left else return Error.UnsupportedOperation,
            .logical_shift_right => if (data_type == .u32) .shift_right else return Error.UnsupportedOperation,
            .arithmetic_shift_right => if (data_type == .i32) .shift_right else return Error.UnsupportedOperation,
            .bitwise_and => if (data_type == .u32 or data_type == .i32) .bitwise_and else return Error.UnsupportedOperation,
            .bitwise_or => if (data_type == .u32 or data_type == .i32) .bitwise_or else return Error.UnsupportedOperation,
            .bitwise_xor => if (data_type == .u32 or data_type == .i32) .bitwise_xor else return Error.UnsupportedOperation,
            .unsigned_divide,
            .signed_divide,
            .unsigned_modulo,
            .signed_modulo,
            .float_divide,
            .float_modulo,
            .logical_and,
            .logical_or,
            => return Error.UnsupportedOperation,
        };

        for (lhs_components, rhs_components, result_components) |lhs, rhs_value, result_component| {
            if (lhs.type != data_type or rhs_value.type != data_type or result_component.type != data_type)
                return Error.InvalidModule;
            var rhs = rhs_value;
            if (operation.opcode == .integer_subtract or operation.opcode == .float_subtract)
                rhs.negate = !rhs.negate;
            try self.appendInstruction(block_id, null, .{
                .binary = .{
                    .opcode = opcode,
                    .destination = try destinationFromSource(result_component),
                    .lhs = lhs,
                    .rhs = rhs,
                },
            });
        }
    }

    fn lowerCompare(self: *LoweringState, block_id: ids.BlockId, result: ?shader_ir.id.ValueId, operation: shader_ir.instruction.Compare) Error!void {
        const result_id = try requireResult(result);
        const result_value = self.lowerer.module.values.get(result_id) orelse return Error.InvalidModule;

        if (!try self.isBoolean(result_value.type))
            return Error.InvalidModule;

        const lhs_components = try self.components(operation.lhs);
        const rhs_components = try self.components(operation.rhs);
        if (lhs_components.len != 1 or rhs_components.len != 1)
            return Error.UnsupportedOperation;
        const lhs = lhs_components[0];
        const rhs = rhs_components[0];
        if (lhs.type != rhs.type)
            return Error.InvalidModule;

        const opcode: instruction.CompareOpcode = switch (operation.opcode) {
            .equal => if (lhs.type == .u32 or lhs.type == .i32) .equal else return Error.UnsupportedOperation,
            .not_equal => if (lhs.type == .u32 or lhs.type == .i32) .not_equal else return Error.UnsupportedOperation,
            .unsigned_less => if (lhs.type == .u32) .less_than else return Error.UnsupportedOperation,
            .signed_less => if (lhs.type == .i32) .less_than else return Error.UnsupportedOperation,
            .ordered_float_equal,
            .unordered_float_equal,
            .ordered_float_not_equal,
            .unordered_float_not_equal,
            .ordered_float_less,
            .unordered_float_less,
            => return Error.UnsupportedOperation,
        };

        const flag_id = self.builder.addVirtualFlag(.{ .name = result_value.name }) catch |err|
            return mapProgramError(err);

        const predicate_value: operand.Predicate = .{ .flag = .{ .virtual = flag_id } };
        try self.putLocation(result_id, .{ .predicate = .{ .dynamic = predicate_value } });
        try self.appendInstruction(block_id, null, .{
            .compare = .{
                .opcode = opcode,
                .destination = predicate_value.flag,
                .lhs = lhs,
                .rhs = rhs,
            },
        });
    }

    fn lowerSelect(self: *LoweringState, block_id: ids.BlockId, result: ?shader_ir.id.ValueId, operation: shader_ir.instruction.Select) Error!void {
        const result_id = try requireResult(result);
        const true_components = try self.components(operation.true_value);
        const false_components = try self.components(operation.false_value);
        const result_components = try self.addRegisterLocation(result_id, .temporary);
        if (true_components.len != false_components.len or true_components.len != result_components.len)
            return Error.InvalidModule;

        const condition = try self.predicate(operation.condition);
        for (true_components, false_components, result_components) |true_value, false_value, result_component| {
            const destination_value = try destinationFromSource(result_component);
            if (true_value.type != destination_value.type or false_value.type != destination_value.type)
                return Error.InvalidModule;

            switch (condition) {
                .constant => |constant| try self.appendMove(
                    block_id,
                    null,
                    destination_value,
                    if (constant) true_value else false_value,
                ),
                .dynamic => |dynamic| {
                    try self.appendMove(block_id, .{
                        .flag = dynamic.flag,
                        .inverse = !dynamic.inverse,
                    }, destination_value, false_value);
                    try self.appendMove(block_id, dynamic, destination_value, true_value);
                },
            }
        }
    }

    fn lowerBitcast(self: *LoweringState, block_id: ids.BlockId, result: ?shader_ir.id.ValueId, source_id: shader_ir.id.ValueId) Error!void {
        const result_id = try requireResult(result);
        const result_value = self.lowerer.module.values.get(result_id) orelse return Error.InvalidModule;
        const target_type = try self.lowerType(result_value.type);
        const source_components = try self.components(source_id);
        const result_components = try self.addRegisterLocation(result_id, .temporary);
        if (source_components.len != target_type.component_count or source_components.len != result_components.len)
            return Error.UnsupportedOperation;

        for (source_components, result_components) |source_component, result_component| {
            // The source operand type selects the reinterpretation used by the
            // move; the target-typed register materializes it before any CFG edge.
            var cast_source = source_component;
            cast_source.register = switch (cast_source.register) {
                .immediate => |immediate| .{ .immediate = bitcastImmediate(immediate, target_type.element_type) },
                else => cast_source.register,
            };
            cast_source.type = target_type.element_type;
            try self.appendMove(block_id, null, try destinationFromSource(result_component), cast_source);
        }
    }

    fn lowerCompositeConstruct(self: *LoweringState, result: ?shader_ir.id.ValueId, operation: shader_ir.instruction.CompositeConstruct) Error!void {
        const result_id = try requireResult(result);
        const result_value = self.lowerer.module.values.get(result_id) orelse return Error.InvalidModule;
        const result_type = try self.lowerType(result_value.type);
        if (result_type.component_count < 2 or operation.elements.len != result_type.component_count)
            return Error.UnsupportedOperation;

        const result_components = try self.storage.alloc(operand.Source, result_type.component_count);
        for (operation.elements, result_components) |element_id, *component| {
            const element_components = try self.components(element_id);
            if (element_components.len != 1 or element_components[0].type != result_type.element_type)
                return Error.InvalidModule;
            component.* = element_components[0];
        }
        try self.putLocation(result_id, .{ .components = result_components });
    }

    fn lowerCompositeExtract(self: *LoweringState, result: ?shader_ir.id.ValueId, operation: shader_ir.instruction.CompositeExtract) Error!void {
        const result_id = try requireResult(result);
        if (operation.indices.len != 1)
            return Error.UnsupportedOperation;
        const source_components = try self.components(operation.composite);
        const component_index: usize = operation.indices[0];
        if (component_index >= source_components.len)
            return Error.InvalidModule;

        const result_value = self.lowerer.module.values.get(result_id) orelse return Error.InvalidModule;
        const result_type = try self.lowerType(result_value.type);
        if (result_type.component_count != 1 or result_type.element_type != source_components[component_index].type)
            return Error.InvalidModule;
        try self.putLocation(result_id, .{ .components = source_components[component_index .. component_index + 1] });
    }

    fn lowerLoadInterface(self: *LoweringState, block_id: ids.BlockId, result: ?shader_ir.id.ValueId, operation: shader_ir.instruction.LoadInterface) Error!void {
        const result_id = try requireResult(result);
        if (operation.element_index != null)
            return Error.UnsupportedOperation;

        const variable = self.lowerer.module.interface_variables.get(operation.variable) orelse return Error.InvalidModule;
        if (variable.direction != .input)
            return Error.InvalidModule;
        switch (variable.semantic) {
            .builtin => |builtin| if (builtin != .global_invocation_id)
                return Error.UnsupportedOperation,
            .location => return Error.UnsupportedOperation,
        }

        const result_value = self.lowerer.module.values.get(result_id) orelse return Error.InvalidModule;
        if (result_value.type != variable.type)
            return Error.InvalidModule;
        const result_components = try self.addRegisterLocation(result_id, .temporary);
        if (result_components.len != 3)
            return Error.UnsupportedOperation;
        for (result_components, 0..) |result_component, component_index| {
            if (result_component.type != .u32)
                return Error.UnsupportedOperation;
            try self.appendInstruction(block_id, null, .{
                .load_global_invocation_id = .{
                    .destination = try destinationFromSource(result_component),
                    .component = @intCast(component_index),
                },
            });
        }
    }

    fn lowerStoreInterface(self: *LoweringState, block_id: ids.BlockId, result: ?shader_ir.id.ValueId, operation: shader_ir.instruction.StoreInterface) Error!void {
        _ = self;
        _ = block_id;
        _ = operation;
        try requireNoResult(result);
        return Error.UnsupportedOperation;
    }

    fn lowerLoadBuffer(self: *LoweringState, block_id: ids.BlockId, result: ?shader_ir.id.ValueId, operation: shader_ir.instruction.LoadBuffer) Error!void {
        const result_id = try requireResult(result);
        const byte_offset = try self.source(operation.byte_offset);
        if (byte_offset.type != .u32)
            return Error.UnsupportedType;
        const buffer = try self.storageBuffer(operation.resource);
        const result_components = try self.addRegisterLocation(result_id, .temporary);
        for (result_components, 0..) |result_component, component_index| {
            try self.appendInstruction(block_id, null, .{
                .load_buffer = .{
                    .destination = try destinationFromSource(result_component),
                    .buffer = .{ .logical = buffer },
                    .byte_offset = byte_offset,
                    .immediate_offset = @intCast(component_index * result_component.type.sizeBytes()),
                },
            });
        }
    }

    fn lowerStoreBuffer(self: *LoweringState, block_id: ids.BlockId, result: ?shader_ir.id.ValueId, operation: shader_ir.instruction.StoreBuffer) Error!void {
        try requireNoResult(result);
        const byte_offset = try self.source(operation.byte_offset);
        if (byte_offset.type != .u32)
            return Error.UnsupportedType;
        const buffer = try self.storageBuffer(operation.resource);
        const source_components = try self.components(operation.value);
        for (source_components, 0..) |source_component, component_index| {
            try self.appendInstruction(block_id, null, .{
                .store_buffer = .{
                    .buffer = .{ .logical = buffer },
                    .byte_offset = byte_offset,
                    .immediate_offset = @intCast(component_index * source_component.type.sizeBytes()),
                    .source = source_component,
                },
            });
        }
    }

    fn lowerControlAndTerminators(self: *LoweringState, allocator: std.mem.Allocator) Error!void {
        const source_entry = try self.sourceEntryFunction();
        const function = source_entry[1];

        for (function.blocks.items) |source_block_id| {
            const source_block = self.lowerer.module.blocks.get(source_block_id) orelse return Error.InvalidModule;
            const target_block_id = try self.mappedBlock(source_block_id);
            const structured_control: instruction.StructuredControl = switch (source_block.structured_control) {
                .none => .none,
                .selection => |selection| .{ .selection = .{
                    .merge_block = try self.mappedBlock(selection.merge_block),
                } },
                .loop => |loop| .{ .loop = .{
                    .merge_block = try self.mappedBlock(loop.merge_block),
                    .continue_block = try self.mappedBlock(loop.continue_block),
                } },
            };
            self.builder.setStructuredControl(target_block_id, structured_control) catch |err|
                return mapProgramError(err);

            const source_terminator = source_block.terminator orelse return Error.InvalidModule;
            const target_terminator: instruction.Terminator = switch (source_terminator) {
                .branch => |edge| .{ .jump = try self.lowerEdge(allocator, edge) },
                .conditional_branch => |branch| conditional: {
                    switch (try self.predicate(branch.condition)) {
                        .constant => |condition| {
                            const edge = if (condition) branch.true_edge else branch.false_edge;
                            break :conditional .{ .jump = try self.lowerEdge(allocator, edge) };
                        },
                        .dynamic => |condition| {
                            const true_edge = try self.lowerEdge(allocator, branch.true_edge);
                            errdefer allocator.free(true_edge.arguments);
                            const false_edge = try self.lowerEdge(allocator, branch.false_edge);
                            break :conditional .{ .conditional_branch = .{
                                .predicate = condition,
                                .true_edge = true_edge,
                                .false_edge = false_edge,
                            } };
                        },
                    }
                },
                .return_void => .end_thread,
                .return_value => return Error.InvalidEntryPoint,
                .discard => return Error.UnsupportedTerminator,
                .@"unreachable" => .@"unreachable",
            };
            defer freeTerminatorArguments(allocator, target_terminator);
            self.builder.setTerminator(target_block_id, target_terminator) catch |err|
                return mapProgramError(err);
        }
    }

    fn lowerEdge(self: *LoweringState, allocator: std.mem.Allocator, edge: shader_ir.module.Edge) Error!instruction.Edge {
        const target_source_block = self.lowerer.module.blocks.get(edge.target) orelse return Error.InvalidModule;
        if (edge.arguments.len != target_source_block.parameters.items.len)
            return Error.InvalidModule;

        var arguments: std.ArrayList(pseudo.EdgeArgument) = .empty;
        defer arguments.deinit(allocator);
        for (edge.arguments) |argument_id| {
            switch (try self.location(argument_id)) {
                .components => |bundle| for (bundle) |component|
                    try arguments.append(allocator, .{ .source = component }),
                .predicate => |predicate_value| try arguments.append(allocator, .{ .predicate = predicate_value }),
            }
        }

        return .{
            .target = try self.mappedBlock(edge.target),
            .arguments = try arguments.toOwnedSlice(allocator),
        };
    }
};

fn freeTerminatorArguments(allocator: std.mem.Allocator, terminator: instruction.Terminator) void {
    switch (terminator) {
        .jump => |edge| allocator.free(edge.arguments),
        .conditional_branch => |branch| {
            allocator.free(branch.true_edge.arguments);
            allocator.free(branch.false_edge.arguments);
        },
        else => {},
    }
}

pub const Lowerer = struct {
    module: *shader_ir.module.Module,
    device_info: device.DeviceInfo,
    options: Options,

    pub fn init(module: *shader_ir.module.Module, device_info: device.DeviceInfo, options: Options) Lowerer {
        return .{
            .module = module,
            .device_info = device_info,
            .options = options,
        };
    }

    pub fn lower(self: *Lowerer, allocator: std.mem.Allocator) Error!program_ir.Program {
        shader_ir.validator.validate(self.module) catch |err| return switch (err) {
            error.OutOfMemory => Error.OutOfMemory,
            error.MissingEntryPoint => Error.MissingEntryPoint,
            error.InvalidEntryPoint => Error.InvalidEntryPoint,
            else => Error.InvalidModule,
        };

        var transformer_manager = shader_ir.transformer_manager.Manager.init(allocator);
        defer transformer_manager.deinit();
        transformer_manager.add(shader_ir.inline_all_functions.transformer) catch return Error.OutOfMemory;

        var transformer_context: shader_ir.transformer_manager.Context = .{ .allocator = allocator };
        _ = transformer_manager.run(self.module, &transformer_context) catch |err| return switch (err) {
            Error.OutOfMemory => Error.OutOfMemory,
            else => Error.SanitizationFailed,
        };
        if (!self.module.properties.no_function_calls)
            return Error.UnsanitizedModule;

        if (self.module.stage != .compute)
            return Error.UnsupportedStage;
        const workgroup_size = self.module.execution_modes.workgroup_size orelse return Error.MissingWorkgroupSize;
        if (workgroup_size[0] == 0 or workgroup_size[1] == 0 or workgroup_size[2] == 0)
            return Error.InvalidModule;

        var program = program_ir.Program.init(allocator, workgroup_size, self.device_info, self.options.dispatch_width);
        errdefer program.deinit();

        const block_map = try allocator.alloc(?ids.BlockId, self.module.blocks.entries.items.len);
        defer allocator.free(block_map);
        @memset(block_map, null);

        const value_locations = try allocator.alloc(?ValueLocation, self.module.values.entries.items.len);
        defer allocator.free(value_locations);
        @memset(value_locations, null);

        const storage_buffer_map = try allocator.alloc(?ids.StorageBufferId, self.module.resources.entries.items.len);
        defer allocator.free(storage_buffer_map);
        @memset(storage_buffer_map, null);

        var state: LoweringState = .{
            .lowerer = self,
            .builder = Builder.init(&program),
            .storage = program.allocator(),
            .block_map = block_map,
            .value_locations = value_locations,
            .storage_buffer_map = storage_buffer_map,
        };

        try state.lowerBlocks();
        try state.lowerParameters();
        try state.lowerInstructions(allocator);
        try state.lowerControlAndTerminators(allocator);

        program.properties.common_ir_lowered = true;
        validator.validate(&program) catch return Error.InvalidLoweredProgram;
        return program;
    }
};

fn bitcastImmediate(immediate: operand.Immediate, target_type: operand.DataType) operand.Immediate {
    const bits: u32 = switch (immediate) {
        .u32 => |value| value,
        .i32 => |value| @bitCast(value),
        .f32 => |value| @bitCast(value),
    };
    return switch (target_type) {
        .u32 => .{ .u32 = bits },
        .i32 => .{ .i32 = @bitCast(bits) },
        .f32 => .{ .f32 = @bitCast(bits) },
        else => unreachable,
    };
}

fn mapProgramError(err: anyerror) Error {
    return switch (err) {
        Error.OutOfMemory => Error.OutOfMemory,
        else => Error.InvalidLoweredProgram,
    };
}

/// Convenience entry point for callers that do not need to retain a lowerer.
pub inline fn lower(allocator: std.mem.Allocator, module: *shader_ir.module.Module, device_info: device.DeviceInfo, options: Options) Error!program_ir.Program {
    var lowerer = Lowerer.init(module, device_info, options);
    return lowerer.lower(allocator);
}

const test_device: device.DeviceInfo = .{
    .generation = .gen9,
    .platform = .skylake,
    .pci_device_id = 0x1912,
    .grf_count = 128,
};

fn expectLowered(source: []const u8, expected: []const u8) !void {
    var module = try shader_ir.parser.parseString(std.testing.allocator, source);
    defer module.deinit();
    module.execution_modes.workgroup_size = .{ 1, 1, 1 };

    var program = try lower(std.testing.allocator, &module, test_device, .{});
    defer program.deinit();
    try block_arguments.run(std.testing.allocator, &program);
    try std.testing.expect(program.properties.common_ir_lowered);
    try std.testing.expect(!program.properties.instructions_selected);

    const actual = try printer.allocPrint(std.testing.allocator, &program);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectLoweredFragments(source: []const u8, expected: []const []const u8, unexpected: []const []const u8) !void {
    var module = try shader_ir.parser.parseString(std.testing.allocator, source);
    defer module.deinit();
    module.execution_modes.workgroup_size = .{ 1, 1, 1 };

    var program = try lower(std.testing.allocator, &module, test_device, .{});
    defer program.deinit();
    try block_arguments.run(std.testing.allocator, &program);
    try std.testing.expect(program.properties.common_ir_lowered);
    try std.testing.expect(!program.properties.instructions_selected);

    const actual = try printer.allocPrint(std.testing.allocator, &program);
    defer std.testing.allocator.free(actual);

    for (expected) |fragment|
        try std.testing.expect(std.mem.indexOf(u8, actual, fragment) != null);
    for (unexpected) |fragment|
        try std.testing.expect(std.mem.indexOf(u8, actual, fragment) == null);
}

fn expectLoweringError(source: []const u8, expected: Error) !void {
    var module = try shader_ir.parser.parseString(std.testing.allocator, source);
    defer module.deinit();
    module.execution_modes.workgroup_size = .{ 1, 1, 1 };

    var program = lower(std.testing.allocator, &module, test_device, .{}) catch |actual| {
        try std.testing.expectEqual(expected, actual);
        return;
    };
    defer program.deinit();
    return error.TestExpectedError;
}

test "[ir] Lower: basic shader" {
    const source =
        \\shader compute @main
        \\{
        \\    %one: constant u32 = bits(0x1)
        \\    %two: constant u32 = bits(0x2)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %sum: u32 = integer_add %one, %two
        \\            %condition: bool = cmp_unsigned_less %one, %two
        \\            conditional_branch %condition, .left(), .right()
        \\        .left():
        \\            branch .merge(%sum)
        \\        .right():
        \\            branch .merge(%two)
        \\        .merge(%value: u32):
        \\            return
        \\    }
        \\}
    ;

    const expected =
        \\; Flint compute program:
        \\;   .workgroup_size: [1, 1, 1]
        \\;   .generation: gen9
        \\;   .platform: skylake
        \\;   .dispatch_width: simd8
        \\
        \\%value: vgrf u32[8], class(temporary), size(32), alignment(32), spillable
        \\%sum: vgrf u32[8], class(temporary), size(32), alignment(32), spillable
        \\%condition: vflag
        \\
        \\.entry:
        \\    [simd8] add %sum:u32, 1:u32, 2:u32
        \\    [simd8] cmp_less_than %condition, 1:u32, 2:u32
        \\    conditional_branch (+%condition), .left, .right
        \\
        \\.left:
        \\    jump .b4
        \\
        \\.right:
        \\    jump .b5
        \\
        \\.merge:
        \\    end_thread
        \\
        \\.b4:
        \\    [simd8] parallel_copy [%value:u32 <- %sum:u32]
        \\    jump .merge
        \\
        \\.b5:
        \\    [simd8] parallel_copy [%value:u32 <- 2:u32]
        \\    jump .merge
        \\
        \\
    ;

    try expectLowered(source, expected);
}

test "[ir] Lower: control flow" {
    const source =
        \\shader compute @main
        \\{
        \\    %one: constant u32 = bits(0x1)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            branch .producer()
        \\        .producer():
        \\            %sum: u32 = integer_add %one, %one
        \\            branch .merge()
        \\        .merge():
        \\            %doubled: u32 = integer_add %sum, %one
        \\            return
        \\    }
        \\}
    ;

    const expected =
        \\; Flint compute program:
        \\;   .workgroup_size: [1, 1, 1]
        \\;   .generation: gen9
        \\;   .platform: skylake
        \\;   .dispatch_width: simd8
        \\
        \\%sum: vgrf u32[8], class(temporary), size(32), alignment(32), spillable
        \\%doubled: vgrf u32[8], class(temporary), size(32), alignment(32), spillable
        \\
        \\.entry:
        \\    jump .producer
        \\
        \\.producer:
        \\    [simd8] add %sum:u32, 1:u32, 1:u32
        \\    jump .merge
        \\
        \\.merge:
        \\    [simd8] add %doubled:u32, %sum:u32, 1:u32
        \\    end_thread
        \\
        \\
    ;

    try expectLowered(source, expected);
}

test "[ir] Lower: function call" {
    const source =
        \\shader compute @main
        \\{
        \\    %one: constant u32 = bits(0x1)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: u32 = call @identity(%one)
        \\            return
        \\    }
        \\    fn @identity(%value: u32) -> u32
        \\    {
        \\        .entry():
        \\            return %value
        \\    }
        \\}
    ;

    const expected =
        \\; Flint compute program:
        \\;   .workgroup_size: [1, 1, 1]
        \\;   .generation: gen9
        \\;   .platform: skylake
        \\;   .dispatch_width: simd8
        \\
        \\%result: vgrf u32[8], class(temporary), size(32), alignment(32), spillable
        \\
        \\.entry:
        \\    jump .b2
        \\
        \\.b1:
        \\    end_thread
        \\
        \\.b2:
        \\    jump .b3
        \\
        \\.b3:
        \\    [simd8] parallel_copy [%result:u32 <- 1:u32]
        \\    jump .b1
        \\
        \\
    ;

    try expectLowered(source, expected);
}

test "[ir] Lower: unary/binary operations" {
    const source =
        \\shader compute @main
        \\{
        \\    %u_one: constant u32 = bits(0x1)
        \\    %u_two: constant u32 = bits(0x2)
        \\    %i_one: constant i32 = bits(0x1)
        \\    %i_two: constant i32 = bits(0x2)
        \\    %f_one: constant f32 = bits(0x3f800000)
        \\    %f_two: constant f32 = bits(0x40000000)
        \\
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %integer_negated: i32 = negate %i_one
        \\            %float_negated: f32 = negate %f_one
        \\            %inverted: u32 = bitwise_not %u_one
        \\            %integer_difference: i32 = integer_subtract %i_one, %i_two
        \\            %float_difference: f32 = float_subtract %f_one, %f_two
        \\            %integer_product: u32 = integer_multiply %u_one, %u_two
        \\            %float_product: f32 = float_multiply %f_one, %f_two
        \\            %shifted_left: u32 = shift_left %u_one, %u_two
        \\            %logical_right: u32 = logical_shift_right %u_two, %u_one
        \\            %arithmetic_right: i32 = arithmetic_shift_right %i_two, %i_one
        \\            %masked: u32 = bitwise_and %u_one, %u_two
        \\            %combined: u32 = bitwise_or %u_one, %u_two
        \\            %toggled: u32 = bitwise_xor %u_one, %u_two
        \\            return
        \\    }
        \\}
    ;

    try expectLoweredFragments(source, &.{
        "[simd8] mov %integer_negated:i32, -1:i32",
        "[simd8] mov %float_negated:f32, -1:f32",
        "[simd8] bitwise_xor %inverted:u32, 1:u32, 4294967295:u32",
        "[simd8] add %integer_difference:i32, 1:i32, -2:i32",
        "[simd8] add %float_difference:f32, 1:f32, -2:f32",
        "[simd8] multiply %integer_product:u32, 1:u32, 2:u32",
        "[simd8] multiply %float_product:f32, 1:f32, 2:f32",
        "[simd8] shift_left %shifted_left:u32, 1:u32, 2:u32",
        "[simd8] shift_right %logical_right:u32, 2:u32, 1:u32",
        "[simd8] shift_right %arithmetic_right:i32, 2:i32, 1:i32",
        "[simd8] bitwise_and %masked:u32, 1:u32, 2:u32",
        "[simd8] bitwise_or %combined:u32, 1:u32, 2:u32",
        "[simd8] bitwise_xor %toggled:u32, 1:u32, 2:u32",
    }, &.{});
}

test "[ir] Lower: selects and bitcasts" {
    const source =
        \\shader compute @main
        \\{
        \\    %always: constant bool = true
        \\    %one: constant u32 = bits(0x1)
        \\    %two: constant u32 = bits(0x2)
        \\    %float_one: constant f32 = bits(0x3f800000)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %condition: bool = cmp_unsigned_less %one, %two
        \\            %dynamic_choice: u32 = select %condition, %one, %two
        \\            %inverted_condition: bool = logical_not %condition
        \\            %inverted_choice: u32 = select %inverted_condition, %one, %two
        \\            %constant_choice: u32 = select %always, %one, %two
        \\            %one_bits: u32 = bitcast %float_one
        \\            %constant_sum: u32 = integer_add %one_bits, %one
        \\            %negative: f32 = negate %float_one
        \\            %negative_bits: u32 = bitcast %negative
        \\            %register_sum: u32 = integer_add %negative_bits, %one
        \\            return
        \\    }
        \\}
    ;

    try expectLoweredFragments(source, &.{
        "[simd8] cmp_less_than %condition, 1:u32, 2:u32",
        "[simd8] (-%condition) mov %dynamic_choice:u32, 2:u32",
        "[simd8] (+%condition) mov %dynamic_choice:u32, 1:u32",
        "[simd8] (+%condition) mov %inverted_choice:u32, 2:u32",
        "[simd8] (-%condition) mov %inverted_choice:u32, 1:u32",
        "[simd8] mov %constant_choice:u32, 1:u32",
        "[simd8] mov %one_bits:u32, 1065353216:u32",
        "[simd8] add %constant_sum:u32, %one_bits:u32, 1:u32",
        "[simd8] mov %negative:f32, -1:f32",
        "[simd8] mov %negative_bits:u32, %negative:u32",
        "[simd8] add %register_sum:u32, %negative_bits:u32, 1:u32",
    }, &.{});
}

test "[ir] Lower: global invocation ID" {
    const source =
        \\shader compute @main
        \\{
        \\    @global_id: vec3[u32] = input[builtin(global_invocation_id)]
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %id: vec3[u32] = load_interface @global_id
        \\            %x: u32 = composite_extract %id[0]
        \\            return
        \\    }
        \\}
    ;

    try expectLoweredFragments(source, &.{
        "%id_x: vgrf u32[8], class(temporary)",
        "%id_z: vgrf u32[8], class(temporary)",
        "[simd8] load_global_invocation_id %id_x:u32, component(0)",
        "[simd8] load_global_invocation_id %id_y:u32, component(1)",
        "[simd8] load_global_invocation_id %id_z:u32, component(2)",
    }, &.{});
}

test "[ir] Lower: vector storage-buffer operations" {
    const source =
        \\shader compute @main
        \\{
        \\    @source: vec4[u32] = storage_buffer[set(0), binding(1)]
        \\    @destination: vec4[u32] = storage_buffer[set(0), binding(2)]
        \\    %offset: constant u32 = 16
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %value: vec4[u32] = load_buffer @source, %offset
        \\            store_buffer @destination, %offset, %value
        \\            return
        \\    }
        \\}
    ;

    try expectLoweredFragments(source, &.{
        "@source = storage_buffer[set(0), binding(1)]",
        "@destination = storage_buffer[set(0), binding(2)]",
        "[simd8] load_buffer %value_x:u32, @source, 16:u32",
        "[simd8] load_buffer %value_y:u32, @source, 16:u32, offset(4)",
        "[simd8] load_buffer %value_w:u32, @source, 16:u32, offset(12)",
        "[simd8] store_buffer @destination, 16:u32, %value_x:u32",
        "[simd8] store_buffer @destination, 16:u32, offset(12), %value_w:u32",
    }, &.{});
}

test "[ir] Lower: vector block parameter" {
    const source =
        \\shader compute @main
        \\{
        \\    %one: constant u32 = bits(0x1)
        \\    %two: constant u32 = bits(0x2)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %pair: vec2[u32] = composite_construct %one, %two
        \\            branch .merge(%pair)
        \\        .merge(%merged: vec2[u32]):
        \\            %first: u32 = composite_extract %merged[0]
        \\            return
        \\    }
        \\}
    ;

    try expectLoweredFragments(source, &.{
        "%merged_x: vgrf u32[8]",
        "%merged_y: vgrf u32[8]",
        "parallel_copy [%merged_x:u32 <- 1:u32, %merged_y:u32 <- 2:u32]",
    }, &.{
        ".merge(",
    });
}

test "[ir] Lower: reject non-compute interfaces" {
    try expectLoweringError(
        \\shader compute @main
        \\{
        \\    @input: u32 = input[location(0), component(0), index(0)]
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %value: u32 = load_interface @input
        \\            return
        \\    }
        \\}
    , Error.UnsupportedOperation);
}

test "[ir] Lower: constant conditional branch" {
    const source =
        \\shader compute @main
        \\{
        \\    %always: constant bool = true
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            conditional_branch %always, .taken(), .untaken()
        \\        .taken():
        \\            return
        \\        .untaken():
        \\            return
        \\    }
        \\}
    ;

    try expectLoweredFragments(source, &.{
        ".entry:\n    jump .taken",
        ".taken:\n    end_thread",
        ".untaken:\n    end_thread",
    }, &.{
        "conditional_branch",
        "vflag",
    });
}

test "[ir] Lower: boolean block parameter" {
    const source =
        \\shader compute @main
        \\{
        \\    %one: constant u32 = bits(0x1)
        \\    %two: constant u32 = bits(0x2)
        \\    %never: constant bool = false
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %condition: bool = cmp_unsigned_less %one, %two
        \\            conditional_branch %condition, .left(), .right()
        \\        .left():
        \\            branch .merge(%condition)
        \\        .right():
        \\            branch .merge(%never)
        \\        .merge(%merged: bool):
        \\            conditional_branch %merged, .taken(), .not_taken()
        \\        .taken():
        \\            return
        \\        .not_taken():
        \\            return
        \\    }
        \\}
    ;

    try expectLoweredFragments(source, &.{
        "%condition: vflag",
        "%merged: vflag",
        "parallel_copy [%merged <- (+%condition)]",
        "parallel_copy [%merged <- false]",
        ".merge:\n    conditional_branch (+%merged), .taken, .not_taken",
    }, &.{});
}

test "[ir] Lower: unsupported operations" {
    try expectLoweringError(
        \\shader compute @main
        \\{
        \\    %one: constant u32 = bits(0x1)
        \\    %two: constant u32 = bits(0x2)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %quotient: u32 = unsigned_divide %one, %two
        \\            return
        \\    }
        \\}
    , Error.UnsupportedOperation);

    try expectLoweringError(
        \\shader compute @main
        \\{
        \\    %one: constant u32 = bits(0x1)
        \\    %two: constant u32 = bits(0x2)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %wide: vec5[u32] = composite_construct %one, %two, %one, %two, %one
        \\            return
        \\    }
        \\}
    , Error.UnsupportedType);

    try expectLoweringError(
        \\shader compute @main
        \\{
        \\    %one: constant u16 = bits(0x1)
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %sum: u16 = integer_add %one, %one
        \\            return
        \\    }
        \\}
    , Error.UnsupportedType);
}

test "[ir] Lower: unreachable terminator" {
    const source =
        \\shader compute @main
        \\{
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            unreachable
        \\    }
        \\}
    ;

    try expectLoweredFragments(source, &.{
        ".entry:\n    unreachable",
    }, &.{});
}

test "[ir] Lower: common lowering is generation and dispatch-width agnostic" {
    var module = try shader_ir.parser.parseString(std.testing.allocator,
        \\shader compute @main
        \\{
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();
    module.execution_modes.workgroup_size = .{ 1, 1, 1 };

    var other_target = test_device;
    other_target.generation = .gen11;
    other_target.grf_size_bytes = 64;
    other_target.supports_simd16 = true;
    var program = try lower(std.testing.allocator, &module, other_target, .{ .dispatch_width = .simd16 });
    defer program.deinit();

    try std.testing.expectEqual(device.Generation.gen11, program.device_info.generation);
    try std.testing.expectEqual(device.DispatchWidth.simd16, program.dispatch_width);
    try validator.validate(&program);
}
