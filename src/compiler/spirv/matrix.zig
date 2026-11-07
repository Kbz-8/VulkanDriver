const ir = @import("../ir/ir.zig");
const spirv = @import("spirv.zig");
const vector_lowering = @import("vector.zig");

const MatrixShape = struct {
    column_type: ir.id.TypeId,
    scalar_type: ir.id.TypeId,
    columns: u8,
    rows: u8,
};

const Emitter = struct {
    builder: *ir.Builder,
    block: ir.id.BlockId,

    fn typeOf(self: Emitter, value: ir.id.ValueId) !ir.id.TypeId {
        return self.builder.module.typeOf(value) orelse error.InvalidInstruction;
    }

    fn vector(self: Emitter, ty: ir.id.TypeId) !ir.types.VectorType {
        const data = self.builder.module.types.get(ty) orelse return error.InvalidInstruction;
        if (data.* != .vector or data.vector.length < 2 or data.vector.length > 4)
            return error.InvalidInstruction;

        const scalar = self.builder.module.types.get(data.vector.element_type) orelse return error.InvalidInstruction;
        if (scalar.* != .floating)
            return error.InvalidInstruction;

        return data.vector;
    }

    fn matrix(self: Emitter, ty: ir.id.TypeId) !MatrixShape {
        const data = self.builder.module.types.get(ty) orelse return error.InvalidInstruction;
        if (data.* != .matrix or data.matrix.column_count < 2 or data.matrix.column_count > 4)
            return error.InvalidInstruction;

        const column = try self.vector(data.matrix.element_type);

        return .{
            .column_type = data.matrix.element_type,
            .scalar_type = column.element_type,
            .columns = data.matrix.column_count,
            .rows = column.length,
        };
    }

    fn extract(self: Emitter, ty: ir.id.TypeId, value: ir.id.ValueId, indices: []const u32) !ir.id.ValueId {
        return (try self.builder.appendInstruction(self.block, ty, .{
            .composite_extract = .{
                .composite = value,
                .indices = indices,
            },
        }, null)).?;
    }

    fn construct(self: Emitter, ty: ir.id.TypeId, elements: []const ir.id.ValueId, name: ?[]const u8) !ir.id.ValueId {
        return (try self.builder.appendInstruction(self.block, ty, .{
            .composite_construct = .{
                .elements = elements,
            },
        }, name)).?;
    }

    fn binary(self: Emitter, ty: ir.id.TypeId, opcode: ir.instruction.BinaryOpcode, lhs: ir.id.ValueId, rhs: ir.id.ValueId, name: ?[]const u8) !ir.id.ValueId {
        return (try self.builder.appendInstruction(self.block, ty, .{
            .binary = .{
                .opcode = opcode,
                .lhs = lhs,
                .rhs = rhs,
            },
        }, name)).?;
    }

    fn determinant(self: Emitter, scalar_type: ir.id.TypeId, elements: []const ir.id.ValueId, size: usize) anyerror!ir.id.ValueId {
        if (size == 1)
            return elements[0];

        var sum: ir.id.ValueId = undefined;
        for (0..size) |column| {
            const minor = try self.minorDeterminant(scalar_type, elements, size, 0, column);
            const product = try self.binary(scalar_type, .float_multiply, elements[column], minor, null);
            sum = if (column == 0)
                product
            else
                try self.binary(scalar_type, if (column % 2 == 0) .float_add else .float_subtract, sum, product, null);
        }
        return sum;
    }

    fn minorDeterminant(self: Emitter, scalar_type: ir.id.TypeId, elements: []const ir.id.ValueId, size: usize, excluded_row: usize, excluded_column: usize) anyerror!ir.id.ValueId {
        var minor: [9]ir.id.ValueId = undefined;
        var index: usize = 0;
        for (0..size) |row| {
            if (row == excluded_row)
                continue;

            for (0..size) |column| {
                if (column == excluded_column)
                    continue;

                minor[index] = elements[row * size + column];
                index += 1;
            }
        }

        return self.determinant(scalar_type, minor[0..index], size - 1);
    }

    fn matrixVector(self: Emitter, shape: MatrixShape, lhs: ir.id.ValueId, rhs: ir.id.ValueId, name: ?[]const u8) !ir.id.ValueId {
        var sum: ir.id.ValueId = undefined;
        for (0..shape.columns) |index| {
            const column = try self.extract(shape.column_type, lhs, &.{@intCast(index)});
            const factor = try self.extract(shape.scalar_type, rhs, &.{@intCast(index)});
            const product = try vector_lowering.scale(self.builder, self.block, shape.column_type, column, factor, null);

            sum = if (index == 0) product else try self.binary(
                shape.column_type,
                .float_add,
                sum,
                product,
                if (index + 1 == shape.columns) name else null,
            );
        }
        return sum;
    }
};

pub fn inverse(builder: *ir.Builder, block: ir.id.BlockId, result_type: ir.id.TypeId, operand: ir.id.ValueId, name: ?[]const u8) !ir.id.ValueId {
    const emit = Emitter{
        .builder = builder,
        .block = block,
    };
    const shape = try emit.matrix(result_type);

    if (try emit.typeOf(operand) != result_type or shape.columns != shape.rows)
        return error.InvalidInstruction;

    switch (builder.module.types.get(shape.scalar_type).?.floating.bits) {
        16, 32, 64 => {},
        else => return error.UnsupportedType,
    }

    const size = shape.columns;
    var elements: [16]ir.id.ValueId = undefined;
    for (0..size) |row| {
        for (0..size) |column|
            elements[row * size + column] = try emit.extract(shape.scalar_type, operand, &.{ @intCast(column), @intCast(row) });
    }

    var adjugate: [4][4]ir.id.ValueId = undefined;
    for (0..size) |column| {
        for (0..size) |row| {
            const minor = try emit.minorDeterminant(shape.scalar_type, elements[0 .. size * size], size, column, row);
            adjugate[column][row] = if ((column + row) % 2 == 0)
                minor
            else
                (try builder.appendInstruction(block, shape.scalar_type, .{
                    .unary = .{
                        .opcode = .negate,
                        .operand = minor,
                    },
                }, null)).?;
        }
    }

    var determinant: ir.id.ValueId = undefined;
    for (0..size) |column| {
        const product = try emit.binary(shape.scalar_type, .float_multiply, elements[column], adjugate[0][column], null);
        determinant = if (column == 0)
            product
        else
            try emit.binary(shape.scalar_type, .float_add, determinant, product, null);
    }

    var columns: [4]ir.id.ValueId = undefined;
    for (columns[0..size], 0..) |*column, column_index| {
        var entries: [4]ir.id.ValueId = undefined;
        for (entries[0..size], 0..) |*entry, row_index|
            entry.* = try emit.binary(shape.scalar_type, .float_divide, adjugate[column_index][row_index], determinant, null);

        column.* = try emit.construct(shape.column_type, entries[0..size], null);
    }

    return emit.construct(result_type, columns[0..size], name);
}

pub fn lower(
    builder: *ir.Builder,
    block: ir.id.BlockId,
    opcode: spirv.Opcode,
    result_type: ir.id.TypeId,
    lhs: ir.id.ValueId,
    rhs: ?ir.id.ValueId,
    name: ?[]const u8,
) !ir.id.ValueId {
    const emit = Emitter{ .builder = builder, .block = block };
    const lhs_type = try emit.typeOf(lhs);

    switch (opcode) {
        .transpose => {
            const source = try emit.matrix(lhs_type);
            const result = try emit.matrix(result_type);

            if (source.columns != result.rows or source.rows != result.columns or source.scalar_type != result.scalar_type)
                return error.InvalidInstruction;

            var columns: [4]ir.id.ValueId = undefined;
            for (columns[0..result.columns], 0..) |*column, column_index| {
                var elements: [4]ir.id.ValueId = undefined;
                for (elements[0..result.rows], 0..) |*element, row_index|
                    element.* = try emit.extract(result.scalar_type, lhs, &.{ @intCast(row_index), @intCast(column_index) });

                column.* = try emit.construct(result.column_type, elements[0..result.rows], null);
            }

            return emit.construct(result_type, columns[0..result.columns], name);
        },
        .matrix_times_vector => {
            const matrix = try emit.matrix(lhs_type);
            const vector = try emit.vector(try emit.typeOf(rhs.?));

            if (result_type != matrix.column_type or vector.length != matrix.columns or vector.element_type != matrix.scalar_type)
                return error.InvalidInstruction;

            return emit.matrixVector(matrix, lhs, rhs.?, name);
        },
        .vector_times_matrix => {
            const vector = try emit.vector(lhs_type);
            const matrix = try emit.matrix(try emit.typeOf(rhs.?));
            const result = try emit.vector(result_type);

            if (lhs_type != matrix.column_type or result.length != matrix.columns or result.element_type != vector.element_type)
                return error.InvalidInstruction;

            var elements: [4]ir.id.ValueId = undefined;
            for (elements[0..result.length], 0..) |*element, index| {
                const column = try emit.extract(matrix.column_type, rhs.?, &.{@intCast(index)});
                element.* = try emit.binary(matrix.scalar_type, .dot, lhs, column, null);
            }

            return emit.construct(result_type, elements[0..result.length], name);
        },
        .matrix_times_matrix => {
            const left = try emit.matrix(lhs_type);
            const right = try emit.matrix(try emit.typeOf(rhs.?));
            const result = try emit.matrix(result_type);

            if (left.columns != right.rows or result.columns != right.columns or
                result.column_type != left.column_type or left.scalar_type != right.scalar_type)
                return error.InvalidInstruction;

            var columns: [4]ir.id.ValueId = undefined;
            for (columns[0..result.columns], 0..) |*column, index| {
                const right_column = try emit.extract(right.column_type, rhs.?, &.{@intCast(index)});
                column.* = try emit.matrixVector(left, lhs, right_column, null);
            }

            return emit.construct(result_type, columns[0..result.columns], name);
        },
        .matrix_times_scalar => {
            const matrix = try emit.matrix(lhs_type);
            if (result_type != lhs_type or try emit.typeOf(rhs.?) != matrix.scalar_type)
                return error.InvalidInstruction;

            var columns: [4]ir.id.ValueId = undefined;
            for (columns[0..matrix.columns], 0..) |*column, index| {
                const source_column = try emit.extract(matrix.column_type, lhs, &.{@intCast(index)});
                column.* = try vector_lowering.scale(builder, block, matrix.column_type, source_column, rhs.?, null);
            }

            return emit.construct(result_type, columns[0..matrix.columns], name);
        },
        .outer_product => {
            const left = try emit.vector(lhs_type);
            const right = try emit.vector(try emit.typeOf(rhs.?));
            const result = try emit.matrix(result_type);

            if (lhs_type != result.column_type or right.length != result.columns or left.element_type != right.element_type)
                return error.InvalidInstruction;

            var columns: [4]ir.id.ValueId = undefined;
            for (columns[0..result.columns], 0..) |*column, index| {
                const factor = try emit.extract(result.scalar_type, rhs.?, &.{@intCast(index)});
                column.* = try vector_lowering.scale(builder, block, result.column_type, lhs, factor, null);
            }

            return emit.construct(result_type, columns[0..result.columns], name);
        },
        else => unreachable,
    }
}
