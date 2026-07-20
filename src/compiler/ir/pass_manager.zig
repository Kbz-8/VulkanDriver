const std = @import("std");
const module_ir = @import("module.zig");
const validator = @import("validator/validator.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    validate_after_each_pass: bool = true,
};

pub const Pass = struct {
    name: []const u8,
    required: module_ir.Properties = .{},
    produced: module_ir.Properties = .{},
    invalidated: module_ir.Properties = .{},
    run: *const fn (module: *module_ir.Module, context: *Context) anyerror!bool,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    passes: std.ArrayList(Pass) = .empty,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        self.passes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Manager, pass: Pass) !void {
        try self.passes.append(self.allocator, pass);
    }

    pub fn run(self: *Manager, module: *module_ir.Module, context: *Context) !bool {
        var changed = false;
        for (self.passes.items) |pass| {
            if (!satisfies(module.properties, pass.required))
                return error.RequiredPropertyMissing;

            changed = (try pass.run(module, context)) or changed;
            applyInvalidated(&module.properties, pass.invalidated);
            applyProduced(&module.properties, pass.produced);

            if (context.validate_after_each_pass)
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
