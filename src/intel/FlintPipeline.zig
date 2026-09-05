const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const shader_ir = @import("shader_ir");
const compiler = @import("compiler/compiler.zig");
const FlintPhysicalDevice = @import("FlintPhysicalDevice.zig");

const VkError = base.VkError;

const Self = @This();
pub const Interface = base.Pipeline;

const PipelineKind = enum {
    graphics,
    compute,
};

pub const ComputeArtifact = compiler.targets.ComputeArtifact;

const CommonStage = struct {
    stage: shader_ir.ir.module.Stage,
    module: base.ShaderModule.IrModule,
    artifact: ?ComputeArtifact,

    fn deinit(self: *CommonStage, allocator: std.mem.Allocator) void {
        if (self.artifact) |*artifact|
            artifact.deinit(allocator);
        self.module.deinit();
        self.* = undefined;
    }
};

interface: Interface,
artifact_allocator: base.VulkanAllocator,
stages: []CommonStage,

pub fn createCompute(device: *base.Device, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.ComputePipelineCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    var initialized = false;
    errdefer if (initialized) self.interface.destroy(allocator) else allocator.destroy(self);

    var interface = try Interface.initCompute(device, allocator, cache, info);
    interface.vtable = &.{ .destroy = destroy };

    self.* = .{
        .interface = interface,
        .artifact_allocator = base.VulkanAllocator.from(allocator).clone(),
        .stages = &.{},
    };
    initialized = true;

    self.stages = try compileStages(self.artifact_allocator.allocator(), device.io(), &.{info.stage}, .compute, compilerDeviceInfo(device));
    if (self.computeArtifact()) |artifact|
        try validateComputePipelineLayout(self.interface.layout, &artifact.resources);
    return self;
}

pub fn createGraphics(device: *base.Device, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.GraphicsPipelineCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    var initialized = false;
    errdefer if (initialized) self.interface.destroy(allocator) else allocator.destroy(self);

    var interface = try Interface.initGraphics(device, allocator, cache, info);
    interface.vtable = &.{ .destroy = destroy };

    self.* = .{
        .interface = interface,
        .artifact_allocator = base.VulkanAllocator.from(allocator).clone(),
        .stages = &.{},
    };
    initialized = true;

    const stage_infos = if (info.p_stages) |stages|
        stages[0..info.stage_count]
    else
        return VkError.ValidationFailed;
    self.stages = try compileStages(self.artifact_allocator.allocator(), device.io(), stage_infos, .graphics, compilerDeviceInfo(device));
    return self;
}

fn compileStages(allocator: std.mem.Allocator, io: std.Io, infos: []const vk.PipelineShaderStageCreateInfo, pipeline_kind: PipelineKind, device_info: ?compiler.device.DeviceInfo) VkError![]CommonStage {
    if (infos.len == 0)
        return VkError.ValidationFailed;

    const stages = allocator.alloc(CommonStage, infos.len) catch return VkError.OutOfHostMemory;
    var initialized: usize = 0;
    errdefer {
        for (stages[0..initialized]) |*stage|
            stage.deinit(allocator);
        allocator.free(stages);
    }

    for (infos, stages) |*info, *stage| {
        stage.* = try compileStage(allocator, io, info, pipeline_kind, device_info);
        initialized += 1;
    }
    return stages;
}

fn compileStage(allocator: std.mem.Allocator, io: std.Io, info: *const vk.PipelineShaderStageCreateInfo, pipeline_kind: PipelineKind, device_info: ?compiler.device.DeviceInfo) VkError!CommonStage {
    const specializations = try specializationValues(allocator, info.p_specialization_info);
    defer if (specializations.len != 0) allocator.free(specializations);

    const expected_stage = commonStage(info.stage) orelse return VkError.ValidationFailed;
    switch (pipeline_kind) {
        .compute => if (expected_stage != .compute) return VkError.ValidationFailed,
        .graphics => if (expected_stage == .compute) return VkError.ValidationFailed,
    }

    const shader_module = try base.NonDispatchable(base.ShaderModule).fromHandleObject(info.module);
    var module = shader_module.instantiateIr(allocator, .{
        .entry_point = std.mem.span(info.p_name),
        .stage = expected_stage,
        .specializations = specializations,
    }) catch |err| {
        std.log.scoped(.FlintPipeline).err("common shader translation failed: {s}", .{@errorName(err)});
        return switch (err) {
            error.OutOfMemory => VkError.OutOfHostMemory,
            else => VkError.ValidationFailed,
        };
    };
    errdefer module.deinit();

    std.debug.assert(module.stage == expected_stage);
    if (base.config.flint_dump_common_ir)
        dumpCommonIr(allocator, io, std.mem.span(info.p_name), &module);

    var artifact = try lowerToFlint(allocator, &module, device_info);
    errdefer if (artifact) |*value| value.deinit(allocator);
    if (base.config.flint_dump_ir) {
        if (artifact) |*value|
            dumpFlintIr(allocator, io, std.mem.span(info.p_name), &value.program);
    }

    return .{
        .stage = expected_stage,
        .module = module,
        .artifact = artifact,
    };
}

fn dumpCommonIr(allocator: std.mem.Allocator, io: std.Io, entry_point: []const u8, module: *const base.ShaderModule.IrModule) void {
    const text = shader_ir.ir.printer.allocPrint(allocator, module) catch |err| {
        std.log.scoped(.FlintPipeline).err("could not print backend-agnostic IR: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(text);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    stdout_writer.print("\n=== backend-agnostic IR: {s} ===\n{s}\n", .{ entry_point, text }) catch @panic("Debug printing failed");
    stdout_writer.flush() catch @panic("Debug printing failed");
}

fn dumpFlintIr(allocator: std.mem.Allocator, io: std.Io, entry_point: []const u8, program: *const compiler.program.Program) void {
    const text = compiler.printer.allocPrint(allocator, program) catch |err| {
        std.log.scoped(.FlintPipeline).err("could not print Flint IR: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(text);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    stdout_writer.print("\n=== Flint IR: {s} ===\n{s}\n", .{ entry_point, text }) catch @panic("Debug printing failed");
    stdout_writer.flush() catch @panic("Debug printing failed");
}

fn lowerToFlint(allocator: std.mem.Allocator, module: *base.ShaderModule.IrModule, device_info: ?compiler.device.DeviceInfo) VkError!?ComputeArtifact {
    const target = device_info orelse return null;
    return compiler.targets.compileCompute(allocator, module, target, .{}) catch |err| switch (err) {
        error.OutOfMemory => return VkError.OutOfHostMemory,
        else => {
            std.log.scoped(.FlintPipeline).err("compute compilation failed: {s}", .{@errorName(err)});
            return VkError.ValidationFailed;
        },
    };
}

fn validateComputePipelineLayout(layout: *const base.PipelineLayout, resources: *const compiler.targets.ComputeResourceLayout) VkError!void {
    for (resources.bindings) |resource| {
        if (resource.set >= layout.set_count)
            return VkError.ValidationFailed;

        const set_layout = layout.set_layouts[resource.set] orelse return VkError.ValidationFailed;

        if (resource.binding >= set_layout.bindings.len)
            return VkError.ValidationFailed;

        const binding = set_layout.bindings[resource.binding];

        if (binding.descriptor_type != .storage_buffer or binding.array_size == 0)
            return VkError.ValidationFailed;
    }
}

fn compilerDeviceInfo(device: *const base.Device) ?compiler.device.DeviceInfo {
    const physical_device: *const FlintPhysicalDevice = @alignCast(@fieldParentPtr("interface", device.physical_device));
    return physical_device.compiler_info;
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
        return VkError.OutOfHostMemory;
    errdefer allocator.free(values);

    for (entries[0..specialization.map_entry_count], values) |entry, *value| {
        const offset: usize = entry.offset;
        const end = std.math.add(usize, offset, entry.size) catch return VkError.ValidationFailed;
        if (end > data.len)
            return VkError.ValidationFailed;
        value.* = .{
            .constant_id = entry.constant_id,
            .data = data[offset..end],
        };
    }
    return values;
}

fn commonStage(stage: vk.ShaderStageFlags) ?shader_ir.ir.module.Stage {
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

fn deinitStages(allocator: std.mem.Allocator, stages: []CommonStage) void {
    for (stages) |*stage|
        stage.deinit(allocator);
    if (stages.len != 0)
        allocator.free(stages);
}

pub fn computeArtifact(self: *const Self) ?*const ComputeArtifact {
    if (self.interface.bind_point != .compute or self.stages.len != 1 or self.stages[0].stage != .compute)
        return null;
    return if (self.stages[0].artifact) |*artifact| artifact else null;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    deinitStages(self.artifact_allocator.allocator(), self.stages);
    allocator.destroy(self);
}

test "Flint pipeline: lower common compute IR" {
    const device_info: compiler.device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };
    var module = shader_ir.ir.module.Module.init(std.testing.allocator, .compute);
    defer module.deinit();
    module.execution_modes.workgroup_size = .{ 1, 1, 1 };
    var builder = shader_ir.ir.Builder.init(&module);

    const void_type = try builder.internType(.void);
    const u32_type = try builder.internType(.{ .integer = .{ .bits = 32, .signedness = .unsigned } });
    const vec3_type = try builder.internType(.{ .vector = .{ .element_type = u32_type, .length = 3 } });
    const global_id = try builder.addInterfaceVariable(vec3_type, .input, .{ .builtin = .global_invocation_id }, "global_id");
    const storage = try builder.addResource(u32_type, .storage_buffer, 0, 2, "storage");
    const zero = try builder.internConstant(u32_type, .{ .integer_bits = 0 });
    const main = try builder.addFunction(void_type, "main");
    builder.setEntryPoint(main);
    const entry = try builder.addBlock(main, "entry");
    const id = (try builder.appendInstruction(entry, vec3_type, .{
        .load_interface = .{ .variable = global_id },
    }, "id")).?;
    const x = (try builder.appendInstruction(entry, u32_type, .{
        .composite_extract = .{ .composite = id, .indices = &.{0} },
    }, "x")).?;
    _ = try builder.appendInstruction(entry, null, .{
        .store_buffer = .{ .resource = storage, .byte_offset = zero, .value = x },
    }, null);
    try builder.setTerminator(entry, .return_void);

    var artifact = (try lowerToFlint(std.testing.allocator, &module, device_info)).?;
    defer artifact.deinit(std.testing.allocator);
    const program = &artifact.program;

    try std.testing.expect(program.properties.common_ir_lowered);
    try std.testing.expect(program.properties.compute_abi_lowered);
    try std.testing.expectEqual(@as(u16, 1), program.program_data.payload_grf_count);
    try std.testing.expectEqual(@as(u16, 0), program.payload.header_grf.?.number);
    try std.testing.expect(program.properties.block_parameters_lowered);
    try std.testing.expect(program.properties.system_values_lowered);
    try std.testing.expect(program.properties.resources_lowered);
    try std.testing.expect(program.properties.messages_lowered);
    try std.testing.expect(program.properties.message_addresses_lowered);
    try std.testing.expect(program.properties.message_payloads_lowered);
    try std.testing.expect(program.properties.registers_allocated);
    try std.testing.expect(!program.properties.instructions_selected);
    try std.testing.expectEqual([3]u32{ 1, 1, 1 }, program.workgroup_size);
    try std.testing.expectEqual(@as(usize, 1), program.storage_buffers.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), artifact.resources.bindings.len);
    try std.testing.expectEqual(@as(u8, 0), artifact.resources.bindings[0].binding_table_index);
    try compiler.targets.validate(program);

    const text = try compiler.printer.allocPrint(std.testing.allocator, program);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "load_global_invocation_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "r0:u32[byte=4, broadcast]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "surface_message write bti(0)") != null);
}
