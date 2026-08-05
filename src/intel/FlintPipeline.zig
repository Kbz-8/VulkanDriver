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

const CommonStage = struct {
    stage: shader_ir.ir.module.Stage,
    module: base.ShaderModule.IrModule,
    program: ?compiler.Program,

    fn deinit(self: *CommonStage) void {
        if (self.program) |*program|
            program.deinit();
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

    self.stages = try compileStages(self.artifact_allocator.allocator(), &.{info.stage}, .compute, compilerDeviceInfo(device));
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
    self.stages = try compileStages(self.artifact_allocator.allocator(), stage_infos, .graphics, compilerDeviceInfo(device));
    return self;
}

fn compileStages(allocator: std.mem.Allocator, infos: []const vk.PipelineShaderStageCreateInfo, pipeline_kind: PipelineKind, device_info: ?compiler.device.DeviceInfo) VkError![]CommonStage {
    if (infos.len == 0)
        return VkError.ValidationFailed;

    const stages = allocator.alloc(CommonStage, infos.len) catch return VkError.OutOfHostMemory;
    var initialized: usize = 0;
    errdefer {
        for (stages[0..initialized]) |*stage|
            stage.deinit();
        allocator.free(stages);
    }

    for (infos, stages) |*info, *stage| {
        stage.* = try compileStage(allocator, info, pipeline_kind, device_info);
        initialized += 1;
    }
    return stages;
}

fn compileStage(allocator: std.mem.Allocator, info: *const vk.PipelineShaderStageCreateInfo, pipeline_kind: PipelineKind, device_info: ?compiler.device.DeviceInfo) VkError!CommonStage {
    const specializations = try specializationValues(allocator, info.p_specialization_info);
    defer if (specializations.len != 0) allocator.free(specializations);

    const expected_stage = commonStage(info.stage) orelse return VkError.ValidationFailed;
    switch (pipeline_kind) {
        .compute => if (expected_stage != .compute) return VkError.ValidationFailed,
        .graphics => if (expected_stage == .compute) return VkError.ValidationFailed,
    }

    const shader_module = base.NonDispatchable(base.ShaderModule).fromHandleObject(info.module) catch |err| return err;
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

    var program = try lowerToFlint(allocator, &module, device_info);
    errdefer if (program) |*value| value.deinit();

    return .{
        .stage = expected_stage,
        .module = module,
        .program = program,
    };
}

fn lowerToFlint(allocator: std.mem.Allocator, module: *base.ShaderModule.IrModule, device_info: ?compiler.device.DeviceInfo) VkError!?compiler.Program {
    const target = device_info orelse return null;
    return compiler.lower.lower(allocator, module, target, .{}) catch |err| switch (err) {
        error.OutOfMemory => VkError.OutOfHostMemory,
        error.UnsupportedGeneration,
        error.UnsupportedStage,
        error.UnsupportedDispatchWidth,
        error.UnsupportedType,
        error.UnsupportedOperation,
        error.UnsupportedTerminator,
        => null,
        else => {
            std.log.scoped(.FlintPipeline).err("Flint shader lowering failed: {s}", .{@errorName(err)});
            return VkError.ValidationFailed;
        },
    };
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
        stage.deinit();
    if (stages.len != 0)
        allocator.free(stages);
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    deinitStages(self.artifact_allocator.allocator(), self.stages);
    allocator.destroy(self);
}
