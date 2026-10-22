const std = @import("std");
const shader_ir = @import("shader_ir");
const bc = @import("bytecode.zig");

const ir = shader_ir.ir;
const ids = ir.id;
const module_ir = ir.module;
const none = std.math.maxInt(usize);
const word_bits = @bitSizeOf(usize);
const register_limit: usize = @backingInt(bc.Register.invalid_register);

const Interval = struct {
    value: usize,
    start: usize = none,
    end: usize = 0,
    defined: bool = false,

    fn touch(self: *Interval, position: usize) void {
        self.start = @min(self.start, position);
        self.end = @max(self.end, position);
    }

    fn lessThan(_: void, a: Interval, b: Interval) bool {
        return if (a.start == b.start) a.value < b.value else a.start < b.start;
    }

    fn endOrder(_: void, a: Interval, b: Interval) std.math.Order {
        return std.math.order(a.end, b.end);
    }
};

const Block = struct {
    entry: usize,
    exit: usize = 0,
    successors: [2]?usize = .{ null, null },
    uses: []usize,
    defs: []usize,
    live_in: []usize,
    live_out: []usize,
};

fn bit(index: usize) usize {
    return @as(usize, 1) << @intCast(index % word_bits);
}

const Context = struct {
    values: []const ?bc.Span,
    candidates: []const usize,
    intervals: []Interval,
    block: *Block,
    position: usize,
    invalid_value: bool = false,

    fn use(self: *Context, value: ids.ValueId) void {
        if (value.index() >= self.values.len or self.values[value.index()] == null) {
            self.invalid_value = true;
            return;
        }

        const index = self.candidates[value.index()];

        if (index == none)
            return;

        self.intervals[index].touch(self.position);
        const word = index / word_bits;

        if (self.block.defs[word] & bit(index) == 0)
            self.block.uses[word] |= bit(index);
    }

    fn define(self: *Context, value: ids.ValueId) !void {
        if (value.index() >= self.values.len)
            return error.InvalidValue;

        const index = self.candidates[value.index()];

        if (index == none)
            return;

        const interval = &self.intervals[index];

        if (interval.defined)
            return error.InvalidValue;

        interval.defined = true;
        interval.touch(self.position);
        self.block.defs[index / word_bits] |= bit(index);
    }

    fn edge(self: *Context, module: *const module_ir.Module, block_map: []const usize, incoming: module_ir.Edge) !usize {
        if (incoming.target.index() >= block_map.len)
            return error.InvalidControlFlow;

        const target_index = block_map[incoming.target.index()];
        if (target_index == none)
            return error.InvalidControlFlow;

        const target = module.blocks.get(incoming.target) orelse return error.InvalidControlFlow;

        if (target.parameters.items.len != incoming.arguments.len)
            return error.InvalidControlFlow;

        for (target.parameters.items, incoming.arguments) |parameter, argument| {
            if (parameter.index() >= self.values.len)
                return error.InvalidValue;
            if (self.values[parameter.index()] != null)
                self.use(argument);
        }
        return target_index;
    }
};

pub fn run(allocator: std.mem.Allocator, module: *const module_ir.Module, function: *const module_ir.Function, values: []?bc.Span, first_free: usize) !usize {
    if (first_free > register_limit)
        return error.TooManyRegisters;

    if (values.len != module.values.entries.items.len)
        return error.InvalidValue;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const scratch = arena.allocator();

    const candidates = try scratch.alloc(usize, values.len);
    @memset(candidates, none);
    var intervals: std.ArrayList(Interval) = .empty;

    for (values, 0..) |entry, index| {
        const span = entry orelse continue;
        const value = module.values.entries.items[index] orelse return error.InvalidValue;

        if (span.components == 0)
            return error.InvalidValue;

        if (span.base != .invalid_register) {
            if (@as(usize, @backingInt(span.base)) + span.components > first_free)
                return error.InvalidValue;
            continue;
        }

        switch (value.definition) {
            .instruction, .block_parameter => {},
            else => return error.InvalidValue,
        }

        candidates[index] = intervals.items.len;
        try intervals.append(scratch, .{ .value = index });
    }

    const block_map = try scratch.alloc(usize, module.blocks.entries.items.len);
    @memset(block_map, none);

    const blocks = try scratch.alloc(Block, function.blocks.items.len);

    for (function.blocks.items, 0..) |block_id, index| {
        if (block_id.index() >= block_map.len or block_map[block_id.index()] != none)
            return error.InvalidControlFlow;
        block_map[block_id.index()] = index;
    }

    const words = intervals.items.len / word_bits + @intFromBool(intervals.items.len % word_bits != 0);
    const row_size = std.math.mul(usize, words, 4) catch return error.OutOfMemory;
    const matrix_size = std.math.mul(usize, blocks.len, row_size) catch return error.OutOfMemory;
    const matrix = try scratch.alloc(usize, matrix_size);

    @memset(matrix, 0);

    var position: usize = 0;
    for (function.blocks.items, blocks, 0..) |block_id, *info, index| {
        const block = module.blocks.get(block_id) orelse return error.InvalidControlFlow;
        const row = matrix[index * row_size ..][0..row_size];

        info.* = .{
            .entry = position,
            .uses = row[0..words],
            .defs = row[words .. 2 * words],
            .live_in = row[2 * words .. 3 * words],
            .live_out = row[3 * words .. 4 * words],
        };

        var context: Context = .{
            .values = values,
            .candidates = candidates,
            .intervals = intervals.items,
            .block = info,
            .position = position,
        };

        for (block.parameters.items) |parameter|
            try context.define(parameter);

        for (block.instructions.items) |instruction_id| {
            position = std.math.add(usize, position, 1) catch return error.TooManyInstructions;
            context.position = position;

            const instruction = module.instructions.get(instruction_id) orelse return error.InvalidOperation;
            var retained = instruction.operation.hasSideEffects();

            if (instruction.result) |result| {
                if (result.index() >= values.len)
                    return error.InvalidValue;
                retained = retained or values[result.index()] != null;
            }

            if (!retained)
                continue;

            instruction.operation.visitValueUses(&context, Context.use);

            if (instruction.result) |result|
                try context.define(result);
        }

        position = std.math.add(usize, position, 1) catch return error.TooManyInstructions;
        context.position = position;
        info.exit = position;

        switch (block.terminator orelse return error.InvalidControlFlow) {
            .branch => |edge| info.successors[0] = try context.edge(module, block_map, edge),
            .conditional_branch => |branch| {
                context.use(branch.condition);
                info.successors[0] = try context.edge(module, block_map, branch.true_edge);
                info.successors[1] = try context.edge(module, block_map, branch.false_edge);
            },
            .return_value => |value| context.use(value),
            .return_void, .discard, .@"unreachable" => {},
        }

        if (context.invalid_value)
            return error.InvalidValue;

        position = std.math.add(usize, position, 1) catch return error.TooManyInstructions;
    }

    var changed = true;
    while (changed) {
        changed = false;

        var index = blocks.len;
        while (index != 0) {
            index -= 1;

            const block = &blocks[index];
            for (0..words) |word| {
                var live_out: usize = 0;
                for (block.successors) |successor| {
                    if (successor) |target|
                        live_out |= blocks[target].live_in[word];
                }

                const live_in = block.uses[word] | (live_out & ~block.defs[word]);
                changed = changed or live_in != block.live_in[word] or live_out != block.live_out[word];

                block.live_in[word] = live_in;
                block.live_out[word] = live_out;
            }
        }
    }

    for (blocks) |block| {
        for (block.live_in, block.live_out, 0..) |live_in, live_out, word| {
            var pending = live_in | live_out;
            while (pending != 0) {
                const index = word * word_bits + @as(usize, @intCast(@ctz(pending)));
                if (live_in & bit(index) != 0)
                    intervals.items[index].touch(block.entry);

                if (live_out & bit(index) != 0)
                    intervals.items[index].touch(block.exit);

                pending &= pending - 1;
            }
        }
    }

    for (intervals.items) |interval| {
        if (!interval.defined)
            return error.InvalidValue;
    }

    std.mem.sort(Interval, intervals.items, {}, Interval.lessThan);

    var active = std.PriorityQueue(Interval, void, Interval.endOrder).initContext({});
    try active.ensureTotalCapacity(scratch, intervals.items.len);

    var free: std.ArrayList(Range) = .empty;

    const range_capacity = std.math.add(usize, intervals.items.len, 1) catch return error.OutOfMemory;

    try free.ensureTotalCapacity(scratch, range_capacity);

    if (first_free < register_limit)
        free.appendAssumeCapacity(.{ .base = first_free, .len = register_limit - first_free });

    var high_water = first_free;
    for (intervals.items) |interval| {
        while (active.peek()) |previous| {
            // A single IR instruction can lower to many bytecode instructions
            if (previous.end >= interval.start)
                break;

            _ = active.pop();
            const span = values[previous.value].?;
            release(&free, .{ .base = @backingInt(span.base), .len = span.components });
        }

        const span = &values[interval.value].?;
        var best: ?usize = null;

        for (free.items, 0..) |range, index| {
            if (range.len >= span.components and (best == null or range.len < free.items[best.?].len))
                best = index;
        }

        const index = best orelse return error.TooManyRegisters;
        const base = free.items[index].base;

        free.items[index].base += span.components;
        free.items[index].len -= span.components;

        if (free.items[index].len == 0)
            _ = free.orderedRemove(index);

        span.base = @fromBackingInt(@intCast(base));
        high_water = @max(high_water, base + span.components);

        try active.push(scratch, interval);
    }
    return high_water;
}

const Range = struct { base: usize, len: usize };

fn release(free: *std.ArrayList(Range), range: Range) void {
    var index: usize = 0;
    while (index < free.items.len and free.items[index].base < range.base) : (index += 1) {}

    free.insertAssumeCapacity(index, range);

    if (index != 0 and free.items[index - 1].base + free.items[index - 1].len == free.items[index].base) {
        free.items[index - 1].len += free.items[index].len;
        _ = free.orderedRemove(index);
        index -= 1;
    }

    if (index + 1 < free.items.len and free.items[index].base + free.items[index].len == free.items[index + 1].base) {
        free.items[index].len += free.items[index + 1].len;
        _ = free.orderedRemove(index + 1);
    }
}
