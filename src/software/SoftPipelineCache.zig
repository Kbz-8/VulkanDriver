const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");

const VkError = base.VkError;
const SoftShaderModule = @import("SoftShaderModule.zig");

const Self = @This();
pub const Interface = base.PipelineCache;

const SpecConstant = struct {
    id: u32,
    data: []u8,
};

const CacheRecord = extern struct {
    magic: [8]u8,
    version: u32,
    code_hash: u64,
    entry_hash: u64,
    spec_hash: u64,
};

const CachedShader = struct {
    module: *SoftShaderModule,
    entry: []u8,
    execution_model: spv.spv.SpvExecutionModel,
    specs: []SpecConstant,
    runtime: spv.Runtime,

    fn deinit(self: *@This(), object_allocator: std.mem.Allocator, data_allocator: std.mem.Allocator) void {
        self.module.unref(object_allocator);
        data_allocator.free(self.entry);
        for (self.specs) |spec| {
            data_allocator.free(spec.data);
        }
        if (self.specs.len != 0) {
            data_allocator.free(self.specs);
        }
        self.runtime.deinit(data_allocator);
    }
};

interface: Interface,
mutex: std.Io.Mutex,
shaders: std.ArrayList(CachedShader),

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.PipelineCacheCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);

    interface.vtable = &.{
        .destroy = destroy,
    };

    self.* = .{
        .interface = interface,
        .mutex = .init,
        .shaders = .empty,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const data_allocator = interface.owner.device_allocator.allocator();

    for (self.shaders.items) |*shader| {
        shader.deinit(allocator, data_allocator);
    }
    self.shaders.deinit(data_allocator);
    allocator.destroy(self);
}

pub fn cloneRuntime(
    self: *Self,
    allocator: std.mem.Allocator,
    module: *SoftShaderModule,
    entry: []const u8,
    execution_model: spv.spv.SpvExecutionModel,
    specialization: ?*const vk.SpecializationInfo,
    image_api: spv.Runtime.ImageAPI,
) VkError!?spv.Runtime {
    const io = self.interface.owner.io();
    self.mutex.lock(io) catch return VkError.DeviceLost;
    defer self.mutex.unlock(io);

    for (self.shaders.items) |*shader| {
        if (shader.module == module and shader.execution_model == execution_model and std.mem.eql(u8, shader.entry, entry) and specsEqual(shader.specs, specialization)) {
            var runtime = spv.Runtime.initFrom(allocator, &shader.runtime, image_api) catch return VkError.OutOfDeviceMemory;
            errdefer runtime.deinit(allocator);

            const entry_point = runtime.getEntryPointByNameAndExecutionModel(entry, execution_model) catch return VkError.Unknown;
            runtime.selectEntryPoint(entry_point) catch return VkError.Unknown;

            return runtime;
        }
    }

    return null;
}

pub fn storeRuntimeTemplate(
    self: *Self,
    object_allocator: std.mem.Allocator,
    data_allocator: std.mem.Allocator,
    module: *SoftShaderModule,
    entry: []const u8,
    execution_model: spv.spv.SpvExecutionModel,
    specialization: ?*const vk.SpecializationInfo,
    image_api: spv.Runtime.ImageAPI,
) VkError!void {
    const io = self.interface.owner.io();
    self.mutex.lock(io) catch return VkError.DeviceLost;
    defer self.mutex.unlock(io);

    for (self.shaders.items) |*shader| {
        if (shader.module == module and
            shader.execution_model == execution_model and
            std.mem.eql(u8, shader.entry, entry) and
            specsEqual(shader.specs, specialization))
        {
            return;
        }
    }

    var cached: CachedShader = .{
        .module = module,
        .entry = data_allocator.dupe(u8, entry) catch return VkError.OutOfDeviceMemory,
        .execution_model = execution_model,
        .specs = try cloneSpecs(data_allocator, specialization),
        .runtime = spv.Runtime.init(data_allocator, &module.module, image_api) catch return VkError.OutOfDeviceMemory,
    };

    var module_ref = false;
    errdefer {
        if (module_ref) cached.module.unref(object_allocator);
        data_allocator.free(cached.entry);
        for (cached.specs) |spec| {
            data_allocator.free(spec.data);
        }
        if (cached.specs.len != 0) {
            data_allocator.free(cached.specs);
        }
        cached.runtime.deinit(data_allocator);
    }

    module.ref();
    module_ref = true;
    const entry_point = cached.runtime.getEntryPointByNameAndExecutionModel(entry, execution_model) catch return VkError.Unknown;
    cached.runtime.selectEntryPoint(entry_point) catch return VkError.Unknown;
    try applySpecialization(&cached.runtime, data_allocator, specialization);
    try appendCacheRecord(&self.interface, module, entry, cached.specs);

    self.shaders.append(data_allocator, cached) catch return VkError.OutOfDeviceMemory;
}

fn applySpecialization(runtime: *spv.Runtime, allocator: std.mem.Allocator, specialization: ?*const vk.SpecializationInfo) VkError!void {
    const info = specialization orelse return;
    const entries = info.p_map_entries orelse return;
    const data = specializationData(info);

    for (entries[0..info.map_entry_count]) |entry| {
        runtime.addSpecializationInfo(
            allocator,
            .{
                .id = @intCast(entry.constant_id),
                .offset = @intCast(entry.offset),
                .size = @intCast(entry.size),
            },
            data,
        ) catch return VkError.OutOfDeviceMemory;
    }
    runtime.applySpecializationLayout(allocator) catch return VkError.OutOfDeviceMemory;
}

fn cloneSpecs(allocator: std.mem.Allocator, specialization: ?*const vk.SpecializationInfo) VkError![]SpecConstant {
    const info = specialization orelse return &.{};
    const entries = info.p_map_entries orelse return &.{};
    if (info.map_entry_count == 0) return &.{};

    const data = specializationData(info);
    const specs = allocator.alloc(SpecConstant, info.map_entry_count) catch return VkError.OutOfDeviceMemory;
    var initialized: usize = 0;
    errdefer {
        for (specs[0..initialized]) |spec| {
            allocator.free(spec.data);
        }
        if (specs.len != 0) {
            allocator.free(specs);
        }
    }

    for (specs, entries[0..info.map_entry_count]) |*spec, entry| {
        spec.* = .{
            .id = entry.constant_id,
            .data = allocator.dupe(u8, data[entry.offset .. entry.offset + entry.size]) catch return VkError.OutOfDeviceMemory,
        };
        initialized += 1;
    }

    return specs;
}

fn specsEqual(specs: []const SpecConstant, specialization: ?*const vk.SpecializationInfo) bool {
    const info = specialization orelse return specs.len == 0;
    const entries = info.p_map_entries orelse return specs.len == 0;
    if (specs.len != info.map_entry_count) return false;

    const data = specializationData(info);
    for (specs) |spec| {
        var found = false;
        for (entries[0..info.map_entry_count]) |entry| {
            if (spec.id != entry.constant_id) continue;
            if (!std.mem.eql(u8, spec.data, data[entry.offset .. entry.offset + entry.size])) {
                return false;
            }
            found = true;
            break;
        }
        if (!found) return false;
    }

    return true;
}

fn specializationData(info: *const vk.SpecializationInfo) []const u8 {
    return @as([*]const u8, @ptrCast(@alignCast(info.p_data)))[0..info.data_size];
}

fn appendCacheRecord(interface: *Interface, module: *SoftShaderModule, entry: []const u8, specs: []const SpecConstant) VkError!void {
    var spec_hasher = std.hash.Wyhash.init(0);
    for (specs) |spec| {
        spec_hasher.update(std.mem.asBytes(&spec.id));
        spec_hasher.update(spec.data);
    }

    const record: CacheRecord = .{
        .magic = "APESOFTC".*,
        .version = 1,
        .code_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(module.module.code)),
        .entry_hash = std.hash.Wyhash.hash(0, entry),
        .spec_hash = spec_hasher.final(),
    };

    try interface.appendPayload(std.mem.asBytes(&record));
}
