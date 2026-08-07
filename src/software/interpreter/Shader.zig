const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const shader_ir = @import("shader_ir");

const Program = @import("Program.zig");
const Runtime = @import("Runtime.zig");
const SoftShaderModule = @import("../SoftShaderModule.zig");

const VkError = base.VkError;
const ir = shader_ir.ir;

pub const RuntimeSlot = struct {
    mutex: std.Io.Mutex = .init,
    runtime: Runtime,
};

const Self = @This();

program: Program,
runtimes: []RuntimeSlot,
workgroup_size: ?[3]u32,

/// Compiles a stage when the current interpreter can execute its complete
/// interface. `null` deliberately selects the existing SPIR-V runtime.
pub fn compile(
    allocator: std.mem.Allocator,
    module: *SoftShaderModule,
    stage: *const vk.PipelineShaderStageCreateInfo,
    runtime_count: usize,
) VkError!?Self {
    const expected_stage = commonStage(stage.stage) orelse return null;
    if (expected_stage == .fragment)
        return null;

    const specializations = try specializationValues(allocator, stage.p_specialization_info);
    defer if (specializations.len != 0) allocator.free(specializations);

    var module_ir = module.interface.instantiateIr(allocator, .{
        .entry_point = std.mem.span(stage.p_name),
        .stage = expected_stage,
        .specializations = specializations,
    }) catch |err| {
        if (err == error.OutOfMemory)
            return VkError.OutOfDeviceMemory;
        std.log.scoped(.SoftIrInterpreter).debug("IR translation fallback: {s}", .{@errorName(err)});
        return null;
    };
    defer module_ir.deinit();

    var program = Program.compile(allocator, &module_ir) catch |err| {
        if (err == error.OutOfMemory)
            return VkError.OutOfDeviceMemory;
        std.log.scoped(.SoftIrInterpreter).debug("bytecode lowering fallback: {s}", .{@errorName(err)});
        return null;
    };
    errdefer program.deinit();

    if (!hasCompatibleInterface(&program, expected_stage) or
        (expected_stage == .compute and module_ir.execution_modes.workgroup_size == null))
    {
        std.log.scoped(.SoftIrInterpreter).debug("stage interface or execution modes require the SPIR-V runtime", .{});
        program.deinit();
        return null;
    }

    const runtimes = allocator.alloc(RuntimeSlot, runtime_count) catch return VkError.OutOfDeviceMemory;
    var initialized: usize = 0;
    errdefer {
        for (runtimes[0..initialized]) |*slot|
            slot.runtime.deinit();
        allocator.free(runtimes);
    }
    for (runtimes) |*slot| {
        slot.* = .{ .runtime = Runtime.init(allocator, &program) catch return VkError.OutOfDeviceMemory };
        initialized += 1;
    }

    std.log.scoped(.SoftIrInterpreter).debug("compiled {s} stage to {d} bytecode instructions", .{
        @tagName(expected_stage),
        program.code.len,
    });
    return .{
        .program = program,
        .runtimes = runtimes,
        .workgroup_size = module_ir.execution_modes.workgroup_size,
    };
}

pub fn deinit(self: *Self) void {
    for (self.runtimes) |*slot|
        slot.runtime.deinit();
    self.program.deinit();
    self.* = undefined;
}

fn hasCompatibleInterface(program: *const Program, stage: ir.module.Stage) bool {
    var has_position = false;
    for (program.interfaces) |optional_binding| {
        const binding = optional_binding orelse continue;
        switch (binding.semantic) {
            .location => |location| {
                if (stage == .compute or location.index != 0 or
                    @as(u16, location.component) + binding.span.components > 4)
                    return false;
            },
            .builtin => |builtin| switch (stage) {
                .vertex => switch (builtin) {
                    .vertex_index, .instance_index => if (binding.direction != .input) return false,
                    .position => {
                        if (binding.direction != .output or binding.span.kind != .floating or binding.span.components != 4)
                            return false;
                        has_position = true;
                    },
                    else => return false,
                },
                .compute => if (builtin != .global_invocation_id or binding.direction != .input or binding.span.components != 3)
                    return false,
                .fragment => return false,
            },
        }
    }
    return stage != .vertex or has_position;
}

fn specializationValues(allocator: std.mem.Allocator, info: ?*const vk.SpecializationInfo) VkError![]shader_ir.spirv.translator.SpecializationValue {
    const specialization = info orelse return &.{};
    if (specialization.map_entry_count == 0)
        return &.{};
    const entries = specialization.p_map_entries orelse return VkError.ValidationFailed;
    const data: []const u8 = if (specialization.data_size == 0)
        &.{}
    else
        @as([*]const u8, @ptrCast(@alignCast(specialization.p_data)))[0..specialization.data_size];

    const values = allocator.alloc(shader_ir.spirv.translator.SpecializationValue, specialization.map_entry_count) catch
        return VkError.OutOfDeviceMemory;
    errdefer allocator.free(values);
    for (entries[0..specialization.map_entry_count], values) |entry, *value| {
        const offset: usize = entry.offset;
        const end = std.math.add(usize, offset, entry.size) catch return VkError.ValidationFailed;
        if (end > data.len)
            return VkError.ValidationFailed;
        value.* = .{ .constant_id = entry.constant_id, .data = data[offset..end] };
    }
    return values;
}

fn commonStage(stage: vk.ShaderStageFlags) ?ir.module.Stage {
    const bits: u32 = @bitCast(stage);
    const vertex_bits: u32 = @bitCast(vk.ShaderStageFlags{ .vertex_bit = true });
    const fragment_bits: u32 = @bitCast(vk.ShaderStageFlags{ .fragment_bit = true });
    const compute_bits: u32 = @bitCast(vk.ShaderStageFlags{ .compute_bit = true });
    return if (bits == vertex_bits)
        .vertex
    else if (bits == fragment_bits)
        .fragment
    else if (bits == compute_bits)
        .compute
    else
        null;
}
