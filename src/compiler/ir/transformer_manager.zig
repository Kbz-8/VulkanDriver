const std = @import("std");
const ids = @import("id.zig");
const module_ir = @import("module.zig");
const Builder = @import("Builder.zig");
const validator = @import("validator/validator.zig");
const visitor = @import("visitor.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    validate_after_each_transformer: bool = true,
};

pub const Transformer = struct {
    name: []const u8,
    required: module_ir.Properties = .{},
    produced: module_ir.Properties = .{},
    invalidated: module_ir.Properties = .{},
    run: *const fn (module: *module_ir.Module, context: *Context) anyerror!bool,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    transformers: std.ArrayList(Transformer) = .empty,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        self.transformers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Manager, transformer: Transformer) !void {
        try self.transformers.append(self.allocator, transformer);
    }

    pub fn run(self: *Manager, module: *module_ir.Module, context: *Context) !bool {
        var changed = false;
        for (self.transformers.items) |transformer| {
            if (!satisfies(module.properties, transformer.required))
                return error.RequiredPropertyMissing;

            changed = (try transformer.run(module, context)) or changed;
            applyInvalidated(&module.properties, transformer.invalidated);
            applyProduced(&module.properties, transformer.produced);

            if (context.validate_after_each_transformer)
                try validator.validate(module);
        }
        return changed;
    }
};

fn satisfies(actual: module_ir.Properties, required: module_ir.Properties) bool {
    inline for (property_names) |name| {
        if (@field(required, name) and !@field(actual, name))
            return false;
    }
    return true;
}

fn applyProduced(properties: *module_ir.Properties, produced: module_ir.Properties) void {
    inline for (property_names) |name| {
        if (@field(produced, name))
            @field(properties, name) = true;
    }
}

fn applyInvalidated(properties: *module_ir.Properties, invalidated: module_ir.Properties) void {
    inline for (property_names) |name| {
        if (@field(invalidated, name))
            @field(properties, name) = false;
    }
}

const property_names = .{
    "valid_cfg",
    "valid_ssa",
    "structured_control_flow",
    "no_function_calls",
    "no_local_memory",
    "no_matrix_types",
    "no_large_composites",
    "explicit_resource_offsets",
};

const VisitorStatistics = struct {
    functions: usize = 0,
    blocks: usize = 0,
};

fn establishNoCalls(_: *module_ir.Module, _: *Context) !bool {
    return false;
}

fn countVisitedFunction(context: ?*anyopaque, _: ids.FunctionId, _: *const module_ir.Function) !void {
    const statistics: *VisitorStatistics = @ptrCast(@alignCast(context.?));
    statistics.functions += 1;
}

fn countVisitedBlock(context: ?*anyopaque, _: ids.BlockId, _: *const module_ir.Block) !void {
    const statistics: *VisitorStatistics = @ptrCast(@alignCast(context.?));
    statistics.blocks += 1;
}

test "Transformers manager: tracks independent IR properties" {
    // shader compute @main
    // {
    //     fn @main() -> void
    //     {
    //         .entry():
    //             return
    //     }
    // }

    var module = module_ir.Module.init(std.testing.allocator, .compute);
    defer module.deinit();

    var builder = Builder.init(&module);

    const void_type = try builder.internType(.void);

    const main = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(main);

    const entry = try builder.addBlock(main, "entry");
    try builder.setTerminator(entry, .return_void);

    module.properties.valid_cfg = true;

    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.add(.{
        .name = "establish-no-calls",
        .required = .{ .valid_cfg = true },
        .produced = .{ .no_function_calls = true },
        .run = establishNoCalls,
    });

    var context: Context = .{ .allocator = std.testing.allocator };

    try std.testing.expect(!try manager.run(&module, &context));
    try std.testing.expect(module.properties.no_function_calls);

    var statistics: VisitorStatistics = .{};

    try visitor.walk(&module, .{
        .context = &statistics,
        .visitFunction = countVisitedFunction,
        .visitBlock = countVisitedBlock,
    });

    try std.testing.expectEqual(@as(usize, 1), statistics.functions);
    try std.testing.expectEqual(@as(usize, 1), statistics.blocks);
}
