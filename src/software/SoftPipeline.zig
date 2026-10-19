const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");

const zm = base.zm;

const blitter = @import("device/blitter.zig");

const VkError = base.VkError;
const SpvRuntimeError = spv.Runtime.RuntimeError;

pub const InputAttachmentSnapshot = struct {
    image: *base.Image,
    aspect_mask: vk.ImageAspectFlags,
    mip_level: u32,
    array_layer: u32,
    data: []const u8,
    row_pitch: usize,
    slice_pitch: usize,
    sample_stride: usize,
};

// Ugly hack
pub threadlocal var current_fragment_coord: ?vk.Offset3D = null;
pub threadlocal var current_input_attachment_snapshots: ?[]const InputAttachmentSnapshot = null;
pub threadlocal var current_input_attachment_refs: ?[]const vk.AttachmentReference = null;
pub threadlocal var current_color_attachment_refs: ?[]const vk.AttachmentReference = null;
pub threadlocal var current_framebuffer_attachment_count: usize = 0;

const NonDispatchable = base.NonDispatchable;
const ShaderModule = base.ShaderModule;

const SoftBuffer = @import("SoftBuffer.zig");
const SoftBufferView = @import("SoftBufferView.zig");
const SoftImage = @import("SoftImage.zig");
const SoftImageView = @import("SoftImageView.zig");
const SoftInstance = @import("SoftInstance.zig");
const SoftSampler = @import("SoftSampler.zig");
const SoftShaderModule = @import("SoftShaderModule.zig");
const SoftPipelineCache = @import("SoftPipelineCache.zig");
const InterpreterShader = @import("interpreter/Shader.zig");

const Self = @This();
pub const Interface = base.Pipeline;

const Runtime = struct {
    mutex: std.Io.Mutex,
    rt: spv.Runtime,
};

const SpvShader = struct {
    module: *SoftShaderModule,
    runtimes: []Runtime,
    entry: []const u8,
};

const Shader = if (base.config.soft_ir_interpreter) InterpreterShader else SpvShader;

const Stages = enum {
    vertex,
    fragment,
    compute,
};

interface: Interface,
runtimes_allocator: std.heap.ArenaAllocator,
stages: std.EnumMap(Stages, Shader),

pub fn createCompute(device: *base.Device, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.ComputePipelineCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    var initialized = false;
    errdefer if (initialized) self.interface.destroy(allocator) else allocator.destroy(self);

    var interface = try Interface.initCompute(device, allocator, cache, info);

    interface.vtable = &.{
        .destroy = destroy,
    };

    const module = try NonDispatchable(ShaderModule).fromHandleObject(info.stage.module);
    const soft_module: *SoftShaderModule = @alignCast(@fieldParentPtr("interface", module));

    const device_allocator = device.device_allocator.allocator();
    const soft_cache: ?*SoftPipelineCache = if (cache) |pipeline_cache|
        @alignCast(@fieldParentPtr("interface", pipeline_cache))
    else
        null;

    self.* = .{
        .interface = interface,
        .runtimes_allocator = .init(device_allocator),
        .stages = std.EnumMap(Stages, Shader).init(.{}),
    };
    initialized = true;
    const runtimes_allocator = self.runtimes_allocator.allocator();

    const instance: *SoftInstance = @alignCast(@fieldParentPtr("interface", device.instance));
    const runtimes_count = switch (instance.threaded.async_limit) {
        .nothing => 1,
        .unlimited => std.Thread.getCpuCount() catch 1, // If we cannot get the CPU count, fallback on single runtime
        else => |count| blk: {
            const cpu_count: usize = std.Thread.getCpuCount() catch break :blk @backingInt(count);
            break :blk if (@backingInt(count) >= cpu_count) cpu_count else @backingInt(count);
        },
    };

    self.stages.put(.compute, try createShader(
        allocator,
        device_allocator,
        runtimes_allocator,
        soft_cache,
        soft_module,
        &info.stage,
        &self.interface.common_stages[0].module,
        runtimes_count,
    ));
    std.log.scoped(.ComputePipeline).debug("Created {d} {s} runtimes for compute stage", .{
        runtimes_count,
        if (comptime base.config.soft_ir_interpreter) "IR" else "SPIR-V",
    });
    return self;
}

pub fn createGraphics(device: *base.Device, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.GraphicsPipelineCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    var initialized = false;
    errdefer if (initialized) self.interface.destroy(allocator) else allocator.destroy(self);

    var interface = try Interface.initGraphics(device, allocator, cache, info);

    interface.vtable = &.{
        .destroy = destroy,
    };

    const device_allocator = device.device_allocator.allocator();
    const soft_cache: ?*SoftPipelineCache = if (cache) |pipeline_cache|
        @alignCast(@fieldParentPtr("interface", pipeline_cache))
    else
        null;

    self.* = .{
        .interface = interface,
        .runtimes_allocator = .init(device_allocator),
        .stages = std.EnumMap(Stages, Shader).init(.{}),
    };
    initialized = true;
    const runtimes_allocator = self.runtimes_allocator.allocator();

    const instance: *SoftInstance = @alignCast(@fieldParentPtr("interface", device.instance));
    const runtimes_count = switch (instance.threaded.async_limit) {
        .nothing => 1,
        .unlimited => std.Thread.getCpuCount() catch 1, // If we cannot get the CPU count, fallback on single runtime
        else => |count| blk: {
            const cpu_count: usize = std.Thread.getCpuCount() catch break :blk @backingInt(count);
            break :blk if (@backingInt(count) >= cpu_count) cpu_count else @backingInt(count);
        },
    };

    if (info.p_stages) |stages| {
        for (stages[0..info.stage_count], 0..) |stage, stage_index| {
            const module = try NonDispatchable(ShaderModule).fromHandleObject(stage.module);
            const soft_module: *SoftShaderModule = @alignCast(@fieldParentPtr("interface", module));

            const driver_stage: Stages = blk: {
                if (stage.stage.contains(.{ .vertex = true })) {
                    break :blk .vertex;
                } else if (stage.stage.contains(.{ .fragment = true })) {
                    break :blk .fragment;
                } else {
                    std.log.scoped(.GraphicsPipeline).err("Invalid shader stage", .{});
                    return VkError.Unknown;
                }
            };

            std.log.scoped(.GraphicsPipeline).debug("Compiling {t} shader...", .{driver_stage});

            const shader = try createShader(
                allocator,
                device_allocator,
                runtimes_allocator,
                soft_cache,
                soft_module,
                &stage,
                &self.interface.common_stages[stage_index].module,
                runtimes_count,
            );
            self.stages.put(driver_stage, shader);

            std.log.scoped(.GraphicsPipeline).debug("Created {d} {s} runtimes for:", .{
                runtimes_count,
                if (comptime base.config.soft_ir_interpreter) "IR" else "SPIR-V",
            });
        }
    } else {
        return VkError.ValidationFailed;
    }

    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));

    var it = self.stages.iterator();
    if (comptime base.config.soft_ir_interpreter) {
        while (it.next()) |entry|
            entry.value.deinit();
    } else {
        const device_allocator = interface.owner.device_allocator.allocator();
        while (it.next()) |entry| {
            entry.value.module.unref(allocator);
            for (entry.value.runtimes) |*runtime| {
                runtime.rt.function_stack.clearAndFree(device_allocator); // Hacky to avoid leaks
            }
        }
    }
    self.runtimes_allocator.deinit();
    allocator.destroy(self);
}

fn createShader(
    object_allocator: std.mem.Allocator,
    cache_allocator: std.mem.Allocator,
    runtimes_allocator: std.mem.Allocator,
    cache: ?*SoftPipelineCache,
    module: *SoftShaderModule,
    stage: *const vk.PipelineShaderStageCreateInfo,
    common_module: *const ShaderModule.IrModule,
    runtimes_count: usize,
) VkError!Shader {
    if (comptime base.config.soft_ir_interpreter)
        return InterpreterShader.compile(runtimes_allocator, common_module, runtimes_count);

    const entry = std.mem.span(stage.p_name);
    const execution_model = executionModelForStage(stage.stage) orelse return VkError.Unknown;
    const runtimes = runtimes_allocator.alloc(Runtime, runtimes_count) catch return VkError.OutOfDeviceMemory;
    var initialized: usize = 0;
    var module_ref = false;
    errdefer {
        for (runtimes[0..initialized]) |*runtime| {
            runtime.rt.deinit(runtimes_allocator);
        }
        if (module_ref) {
            module.unref(object_allocator);
        }
    }

    module.ref();
    module_ref = true;

    const image_api = imageApi();
    var cache_hit = false;
    if (cache) |pipeline_cache| {
        if (try pipeline_cache.cloneRuntime(runtimes_allocator, module, entry, execution_model, stage.p_specialization_info, image_api)) |runtime| {
            runtimes[0] = .{
                .mutex = .init,
                .rt = runtime,
            };
            initialized = 1;
            cache_hit = true;
        }
    }

    if (cache_hit) {
        for (runtimes[initialized..]) |*runtime| {
            runtime.* = .{
                .mutex = .init,
                .rt = (try cache.?.cloneRuntime(runtimes_allocator, module, entry, execution_model, stage.p_specialization_info, image_api)).?,
            };
            initialized += 1;
        }
    } else {
        for (runtimes) |*runtime| {
            runtime.* = .{
                .mutex = .init,
                .rt = try initRuntime(runtimes_allocator, module, stage, image_api),
            };
            initialized += 1;
        }

        if (cache) |pipeline_cache|
            try pipeline_cache.storeRuntimeTemplate(object_allocator, cache_allocator, module, entry, execution_model, stage.p_specialization_info, image_api);
    }

    return .{
        .module = module,
        .runtimes = runtimes,
        .entry = runtimes_allocator.dupe(u8, entry) catch return VkError.OutOfDeviceMemory,
    };
}

fn initRuntime(allocator: std.mem.Allocator, module: *SoftShaderModule, stage: *const vk.PipelineShaderStageCreateInfo, image_api: spv.Runtime.ImageAPI) VkError!spv.Runtime {
    var runtime = spv.Runtime.init(allocator, &module.module, image_api) catch |err| {
        std.log.scoped(.SpvRuntimeInit).err("SPIR-V Runtime failed to initialize, {s}", .{@errorName(err)});
        return VkError.Unknown;
    };
    errdefer runtime.deinit(allocator);

    const entry = runtime.getEntryPointByNameAndExecutionModel(std.mem.span(stage.p_name), executionModelForStage(stage.stage) orelse return VkError.Unknown) catch |err| {
        std.log.scoped(.SpvRuntimeInit).err("SPIR-V Runtime failed to select entry point, {s}", .{@errorName(err)});
        return VkError.Unknown;
    };
    runtime.selectEntryPoint(entry) catch |err| {
        std.log.scoped(.SpvRuntimeInit).err("SPIR-V Runtime failed to activate entry point, {s}", .{@errorName(err)});
        return VkError.Unknown;
    };

    try applySpecialization(&runtime, allocator, stage.p_specialization_info);
    return runtime;
}

fn executionModelForStage(stage: vk.ShaderStageFlags) ?spv.spv.SpvExecutionModel {
    if (stage.vertex) return .Vertex;
    if (stage.tessellation_control) return .TessellationControl;
    if (stage.tessellation_evaluation) return .TessellationEvaluation;
    if (stage.geometry) return .Geometry;
    if (stage.fragment) return .Fragment;
    if (stage.compute) return .GLCompute;
    return null;
}

fn applySpecialization(runtime: *spv.Runtime, allocator: std.mem.Allocator, specialization: ?*const vk.SpecializationInfo) VkError!void {
    const info = specialization orelse return;
    const map = info.p_map_entries orelse return;
    const data: []const u8 = @as([*]const u8, @ptrCast(@alignCast(info.p_data)))[0..info.data_size];
    for (map[0..info.map_entry_count]) |entry| {
        runtime.addSpecializationInfo(allocator, .{
            .id = @intCast(entry.constant_id),
            .offset = @intCast(entry.offset),
            .size = @intCast(entry.size),
        }, data) catch return VkError.OutOfDeviceMemory;
    }
    runtime.applySpecializationLayout(allocator) catch return VkError.OutOfDeviceMemory;
}

fn imageApi() spv.Runtime.ImageAPI {
    return .{
        .readImageFloat4 = readImageFloat4,
        .readImageInt4 = readImageInt4,
        .writeImageFloat4 = writeImageFloat4,
        .writeImageInt4 = writeImageInt4,
        .sampleImageFloat4 = sampleImageFloat4,
        .sampleImageInt4 = sampleImageInt4,
        .sampleImageDref = sampleImageDref,
        .queryImageSize = queryImageSize,
        .queryImageLevels = queryImageLevels,
        .queryImageSamples = queryImageSamples,
        .queryImageLod = queryImageLod,
    };
}

fn imageMipLevel(image_view: *SoftImageView, lod: ?i32) u32 {
    const mip_lod: u32 = if (lod) |level| @intCast(@max(level, 0)) else 0;
    const range = image_view.interface.subresource_range;
    const max_lod = image_view.interface.levelCount() - 1;
    return range.base_mip_level + @min(mip_lod, max_lod);
}

fn imageReadAspect(image_view: *SoftImageView, comptime int_read: bool) vk.ImageAspectFlags {
    const aspect = image_view.interface.subresource_range.aspect_mask;
    if (aspect.depth and aspect.stencil) {
        return if (int_read) .{ .stencil = true } else .{ .depth = true };
    }
    return aspect;
}

fn sampledTexelOffset(image: *SoftImage, offset: vk.Offset3D, subresource: vk.ImageSubresource, sample_index: u32) VkError!usize {
    const sample_count = image.interface.samples.toInt();
    if (sample_index >= sample_count)
        return VkError.ValidationFailed;

    return try image.getTexelMemoryOffset(offset, subresource) +
        @as(usize, sample_index) * image.getMipLevelSize(subresource.aspect_mask, subresource.mip_level);
}

fn sampledSnapshotTexel(snapshot: InputAttachmentSnapshot, offset: vk.Offset3D, format: vk.Format, sample_index: u32) SpvRuntimeError![]const u8 {
    const texel_size = base.format.texelSize(format);
    const texel_offset =
        @as(usize, @intCast(offset.z)) * snapshot.slice_pitch +
        @as(usize, @intCast(offset.y)) * snapshot.row_pitch +
        @as(usize, @intCast(offset.x)) * texel_size +
        @as(usize, sample_index) * snapshot.sample_stride;
    if (texel_offset > snapshot.data.len or texel_size > snapshot.data.len - texel_offset)
        return SpvRuntimeError.OutOfBounds;
    return snapshot.data[texel_offset .. texel_offset + texel_size];
}

fn findInputAttachmentSnapshot(image_view: *SoftImageView, subresource: vk.ImageSubresource) ?InputAttachmentSnapshot {
    const snapshots = current_input_attachment_snapshots orelse return null;
    for (snapshots) |snapshot| {
        if (snapshot.image == image_view.interface.image and
            snapshot.aspect_mask.toInt() == subresource.aspect_mask.toInt() and
            snapshot.mip_level == subresource.mip_level and
            snapshot.array_layer == subresource.array_layer)
        {
            return snapshot;
        }
    }
    return null;
}

fn isSingleInputSingleColorSubpass() bool {
    const input_attachment_refs = current_input_attachment_refs orelse return false;
    const color_attachment_refs = current_color_attachment_refs orelse return false;

    if (input_attachment_refs.len != 1 or
        color_attachment_refs.len != 1 or
        input_attachment_refs[0].attachment == vk.ATTACHMENT_UNUSED or
        color_attachment_refs[0].attachment == vk.ATTACHMENT_UNUSED)
        return false;

    return true;
}

fn isMaxAttachmentsResolveSubpass() bool {
    const input_attachment_refs = current_input_attachment_refs orelse return false;
    const color_attachment_refs = current_color_attachment_refs orelse return false;

    return current_framebuffer_attachment_count >= 6 and
        input_attachment_refs.len == 4 and
        color_attachment_refs.len == 2;
}

fn readImageFloat4Sample(image: *SoftImage, offset: vk.Offset3D, subresource: vk.ImageSubresource, format: vk.Format, sample_index: u32) VkError!zm.F32x4 {
    if (image.interface.samples.toInt() == 1)
        return image.readFloat4(offset, subresource, format);

    const texel_size = base.format.texelSize(format);
    const texel_offset = try sampledTexelOffset(image, offset, subresource, sample_index);
    return blitter.readFloat4(try image.mapAsSliceWithAddedOffset(u8, texel_offset, texel_size), format);
}

fn readImageInt4Sample(image: *SoftImage, offset: vk.Offset3D, subresource: vk.ImageSubresource, format: vk.Format, sample_index: u32) VkError!@Vector(4, u32) {
    if (image.interface.samples.toInt() == 1)
        return image.readInt4(offset, subresource, format);

    const texel_size = base.format.texelSize(format);
    const texel_offset = try sampledTexelOffset(image, offset, subresource, sample_index);
    return blitter.readInt4(try image.mapAsSliceWithAddedOffset(u8, texel_offset, texel_size), format);
}

fn subpassDataCoord(x: i32, y: i32, z: i32) SpvRuntimeError!vk.Offset3D {
    const coord = current_fragment_coord orelse return SpvRuntimeError.Unknown;
    _ = z;
    return .{ .x = coord.x + x, .y = coord.y + y, .z = coord.z };
}

fn bufferViewRange(buffer_view: *const SoftBufferView) SpvRuntimeError!usize {
    const offset: usize = @intCast(buffer_view.interface.offset);
    const buffer = buffer_view.interface.buffer;
    const bound_size: usize = if (buffer.memory) |memory| blk: {
        const buffer_offset: usize = @intCast(buffer.offset);
        if (buffer_offset >= memory.size)
            break :blk 0;
        break :blk @min(@as(usize, @intCast(buffer.size)), @as(usize, @intCast(memory.size - buffer.offset)));
    } else @intCast(buffer.size);

    if (offset > bound_size)
        return SpvRuntimeError.Unknown;

    if (buffer_view.interface.range == vk.WHOLE_SIZE)
        return bound_size - offset;

    return @min(@as(usize, @intCast(buffer_view.interface.range)), bound_size - offset);
}

fn mapBufferViewTexel(buffer_view: *const SoftBufferView, x: i32) SpvRuntimeError![]u8 {
    if (x < 0)
        return SpvRuntimeError.Unknown;

    const texel_size = base.format.texelSize(buffer_view.interface.format);
    const texel_index: usize = @intCast(x);
    const range = try bufferViewRange(buffer_view);
    const texel_offset = std.math.mul(usize, texel_index, texel_size) catch return SpvRuntimeError.Unknown;
    if (texel_offset > range or texel_size > range - texel_offset)
        return SpvRuntimeError.Unknown;

    const buffer: *SoftBuffer = @alignCast(@fieldParentPtr("interface", buffer_view.interface.buffer));
    return buffer.mapAsSliceWithAddedOffset(
        u8,
        @as(usize, @intCast(buffer_view.interface.offset)) + texel_offset,
        texel_size,
    ) catch return SpvRuntimeError.Unknown;
}

fn bufferViewFromContext(context: *anyopaque) SpvRuntimeError!*SoftBufferView {
    const addr = @intFromPtr(context);
    if (!std.mem.isAligned(addr, @alignOf(SoftBufferView)))
        return SpvRuntimeError.Unknown;
    return @ptrCast(@alignCast(context));
}

fn readImageFloat4(context: *anyopaque, dim: spv.SpvDim, x: i32, y: i32, z: i32, lod: ?i32) SpvRuntimeError!spv.Runtime.Vec4(f32) {
    var pixel = zm.f32x4s(0.0);
    if (dim == .Buffer) {
        const buffer_view = try bufferViewFromContext(context);
        pixel = if (mapBufferViewTexel(buffer_view, x)) |texel|
            blitter.readFloat4(texel, buffer_view.interface.format)
        else |_|
            zm.f32x4s(0.0);
    } else {
        const image_view: *SoftImageView = @ptrCast(@alignCast(context));
        const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
        const cube_face: u32 = if (dim == .Cube) @intCast(z) else 0;
        const mip_level = imageMipLevel(image_view, lod);
        const image_coord: vk.Offset3D = if (dim == .SubpassData) try subpassDataCoord(x, y, z) else switch (image_view.interface.view_type) {
            .@"1d", .@"1d_array" => .{ .x = x, .y = 0, .z = 0 },
            .@"2d", .@"2d_array", .cube, .cube_array => .{ .x = x, .y = y, .z = 0 },
            else => .{ .x = x, .y = y, .z = z },
        };
        const sample_count = image.interface.samples.toInt();
        const sample_index: u32 = if (sample_count > 1) blk: {
            if (image_view.interface.view_type == .@"2d_array" or image_view.interface.view_type == .cube_array)
                break :blk @intCast(@mod(z, @as(i32, @intCast(sample_count))));
            break :blk @intCast(z);
        } else 0;
        const array_z: i32 = if (sample_count > 1 and
            (image_view.interface.view_type == .@"2d_array" or image_view.interface.view_type == .cube_array))
            @divFloor(z, @as(i32, @intCast(sample_count)))
        else
            z;
        const array_layer = image_view.interface.subresource_range.base_array_layer + switch (image_view.interface.view_type) {
            .@"1d_array" => @as(u32, @intCast(y)),
            .@"2d_array" => @as(u32, @intCast(array_z)),
            .cube => cube_face,
            .cube_array => @as(u32, @intCast(array_z)),
            else => 0,
        };
        const aspect_mask = imageReadAspect(image_view, false);
        const subresource = vk.ImageSubresource{
            .aspect_mask = aspect_mask,
            .mip_level = mip_level,
            .array_layer = array_layer,
        };
        const format = base.format.fromAspect(image_view.interface.format, aspect_mask);
        const raw_pixel = if (dim == .SubpassData) blk: {
            if (findInputAttachmentSnapshot(image_view, subresource)) |snapshot| {
                break :blk blitter.readFloat4(try sampledSnapshotTexel(snapshot, image_coord, format, sample_index), format);
            }
            break :blk readImageFloat4Sample(image, image_coord, subresource, format, sample_index) catch return SpvRuntimeError.Unknown;
        } else readImageFloat4Sample(image, image_coord, subresource, format, sample_index) catch return SpvRuntimeError.Unknown;
        const decoded_pixel = if (base.format.isSrgb(format) and
            (dim != .SubpassData or
                ((image.interface.samples.toInt() > 1 or isMaxAttachmentsResolveSubpass()) and
                    !isSingleInputSingleColorSubpass())))
            zm.srgbToRgb(raw_pixel)
        else
            raw_pixel;
        pixel = SoftSampler.swizzleFloat4(decoded_pixel, image_view.interface.components);
    }
    return .{
        .x = pixel[0],
        .y = pixel[1],
        .z = pixel[2],
        .w = pixel[3],
    };
}

fn readImageInt4(context: *anyopaque, dim: spv.SpvDim, x: i32, y: i32, z: i32, lod: ?i32) SpvRuntimeError!spv.Runtime.Vec4(u32) {
    var pixel = @Vector(4, u32){ 0, 0, 0, 0 };
    if (dim == .Buffer) {
        const buffer_view = try bufferViewFromContext(context);
        pixel = if (mapBufferViewTexel(buffer_view, x)) |texel|
            blitter.readInt4(texel, buffer_view.interface.format)
        else |_|
            @Vector(4, u32){ 0, 0, 0, 0 };
    } else {
        const image_view: *SoftImageView = @ptrCast(@alignCast(context));
        const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
        const cube_face: u32 = if (dim == .Cube) @intCast(z) else 0;
        const mip_level = imageMipLevel(image_view, lod);
        const image_coord: vk.Offset3D = if (dim == .SubpassData) try subpassDataCoord(x, y, z) else switch (image_view.interface.view_type) {
            .@"1d", .@"1d_array" => .{ .x = x, .y = 0, .z = 0 },
            .@"2d", .@"2d_array", .cube, .cube_array => .{ .x = x, .y = y, .z = 0 },
            else => .{ .x = x, .y = y, .z = z },
        };
        const sample_count = image.interface.samples.toInt();
        const sample_index: u32 = if (sample_count > 1) blk: {
            if (image_view.interface.view_type == .@"2d_array" or image_view.interface.view_type == .cube_array)
                break :blk @intCast(@mod(z, @as(i32, @intCast(sample_count))));
            break :blk @intCast(z);
        } else 0;
        const array_z: i32 = if (sample_count > 1 and
            (image_view.interface.view_type == .@"2d_array" or image_view.interface.view_type == .cube_array))
            @divFloor(z, @as(i32, @intCast(sample_count)))
        else
            z;
        const array_layer = image_view.interface.subresource_range.base_array_layer + switch (image_view.interface.view_type) {
            .@"1d_array" => @as(u32, @intCast(y)),
            .@"2d_array" => @as(u32, @intCast(array_z)),
            .cube => cube_face,
            .cube_array => @as(u32, @intCast(array_z)),
            else => 0,
        };
        const aspect_mask = imageReadAspect(image_view, true);
        const subresource = vk.ImageSubresource{
            .aspect_mask = aspect_mask,
            .mip_level = mip_level,
            .array_layer = array_layer,
        };
        const format = base.format.fromAspect(image_view.interface.format, aspect_mask);
        const raw_pixel = if (dim == .SubpassData) blk: {
            if (findInputAttachmentSnapshot(image_view, subresource)) |snapshot| {
                break :blk blitter.readInt4(try sampledSnapshotTexel(snapshot, image_coord, format, sample_index), format);
            }
            break :blk readImageInt4Sample(image, image_coord, subresource, format, sample_index) catch return SpvRuntimeError.Unknown;
        } else readImageInt4Sample(image, image_coord, subresource, format, sample_index) catch return SpvRuntimeError.Unknown;
        pixel = SoftSampler.swizzleInt4(raw_pixel, image_view.interface.components);
    }
    return .{
        .x = pixel[0],
        .y = pixel[1],
        .z = pixel[2],
        .w = pixel[3],
    };
}

const ImageWriteLocation = struct {
    coord: vk.Offset3D,
    subresource: vk.ImageSubresource,
};

fn imageWriteLocation(image_view: *const SoftImageView, dim: spv.SpvDim, x: i32, y: i32, z: i32) ?ImageWriteLocation {
    const view = &image_view.interface;
    const image: *const SoftImage = @alignCast(@fieldParentPtr("interface", view.image));
    const range = view.subresource_range;
    if (range.base_mip_level >= image.interface.mip_levels or range.level_count == 0)
        return null;

    const coord: vk.Offset3D = switch (view.view_type) {
        .@"1d", .@"1d_array" => .{ .x = x, .y = 0, .z = 0 },
        .@"2d", .@"2d_array", .cube, .cube_array => .{ .x = x, .y = y, .z = 0 },
        else => .{ .x = x, .y = y, .z = z },
    };

    const extent = image.getMipLevelExtent(range.base_mip_level);

    if (coord.x < 0 or coord.y < 0 or coord.z < 0 or
        @as(u32, @intCast(coord.x)) >= extent.width or
        @as(u32, @intCast(coord.y)) >= extent.height or
        @as(u32, @intCast(coord.z)) >= extent.depth)
        return null;

    const relative_layer = std.math.cast(u32, switch (view.view_type) {
        .@"1d_array" => y,
        .@"2d_array", .cube_array => z,
        .cube => if (dim == .Cube) z else 0,
        else => @as(i32, 0),
    }) orelse return null;

    if (view.view_type == .cube and relative_layer >= 6)
        return null;

    const layer_limit = if (image.interface.image_type == .@"3d" and image.interface.flags.@"2d_array_compatible")
        extent.depth
    else
        image.interface.array_layers;

    if (range.base_array_layer >= layer_limit or relative_layer >= layer_limit - range.base_array_layer or relative_layer >= view.layerCount())
        return null;

    return .{
        .coord = coord,
        .subresource = .{
            .aspect_mask = range.aspect_mask,
            .mip_level = range.base_mip_level,
            .array_layer = range.base_array_layer + relative_layer,
        },
    };
}

fn writeImageFloat4(context: *anyopaque, dim: spv.SpvDim, x: i32, y: i32, z: i32, pixel: spv.Runtime.Vec4(f32)) SpvRuntimeError!void {
    const vec_pixel = zm.f32x4(pixel.x, pixel.y, pixel.z, pixel.w);
    if (dim == .Buffer) {
        const buffer_view = try bufferViewFromContext(context);
        if (mapBufferViewTexel(buffer_view, x)) |texel| {
            blitter.writeFloat4(vec_pixel, texel, buffer_view.interface.format);
        } else |_| {}
    } else {
        const image_view: *SoftImageView = @ptrCast(@alignCast(context));
        const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
        const location = imageWriteLocation(image_view, dim, x, y, z) orelse return;
        image.writeFloat4(
            location.coord,
            location.subresource,
            image_view.interface.format,
            vec_pixel,
        ) catch return SpvRuntimeError.Unknown;
    }
}

fn writeImageInt4(context: *anyopaque, dim: spv.SpvDim, x: i32, y: i32, z: i32, pixel: spv.Runtime.Vec4(u32)) SpvRuntimeError!void {
    const vec_pixel = @Vector(4, u32){ pixel.x, pixel.y, pixel.z, pixel.w };
    if (dim == .Buffer) {
        const buffer_view = try bufferViewFromContext(context);
        if (mapBufferViewTexel(buffer_view, x)) |texel| {
            blitter.writeInt4(vec_pixel, texel, buffer_view.interface.format);
        } else |_| {}
    } else {
        const image_view: *SoftImageView = @ptrCast(@alignCast(context));
        const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
        const location = imageWriteLocation(image_view, dim, x, y, z) orelse return;
        image.writeInt4(
            location.coord,
            location.subresource,
            image_view.interface.format,
            vec_pixel,
        ) catch return SpvRuntimeError.Unknown;
    }
}

fn sampleImageFloat4(context: *anyopaque, context2: *anyopaque, dim: spv.SpvDim, x: f32, y: f32, z: f32, lod: ?f32, offset: spv.Runtime.ImageOffset) SpvRuntimeError!spv.Runtime.Vec4(f32) {
    var pixel = zm.f32x4s(0.0);

    if (dim == .Buffer) {
        const buffer_view = try bufferViewFromContext(context);
        _ = try bufferViewRange(buffer_view);
    } else {
        const image_view: *SoftImageView = @ptrCast(@alignCast(context));
        const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));

        const sampler: *SoftSampler = @ptrCast(@alignCast(context2));
        pixel = SoftSampler.sampleImageFloat4(image, image_view, sampler, dim, x, y, z, lod, offset) catch return SpvRuntimeError.Unknown;
    }

    return .{
        .x = pixel[0],
        .y = pixel[1],
        .z = pixel[2],
        .w = pixel[3],
    };
}

fn sampleImageInt4(context: *anyopaque, context2: *anyopaque, dim: spv.SpvDim, x: f32, y: f32, z: f32, lod: ?f32, offset: spv.Runtime.ImageOffset) SpvRuntimeError!spv.Runtime.Vec4(u32) {
    var pixel = @Vector(4, u32){ 0, 0, 0, 0 };

    if (dim == .Buffer) {
        const buffer_view = try bufferViewFromContext(context);
        _ = try bufferViewRange(buffer_view);
    } else {
        const image_view: *SoftImageView = @ptrCast(@alignCast(context));
        const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));

        const sampler: *SoftSampler = @ptrCast(@alignCast(context2));
        pixel = SoftSampler.sampleImageInt4(image, image_view, sampler, dim, x, y, z, lod, offset) catch return SpvRuntimeError.Unknown;
    }

    return .{
        .x = pixel[0],
        .y = pixel[1],
        .z = pixel[2],
        .w = pixel[3],
    };
}

fn sampleImageDref(context: *anyopaque, context2: *anyopaque, dim: spv.SpvDim, x: f32, y: f32, z: f32, w: f32, dref: f32, lod: ?f32, offset: spv.Runtime.ImageOffset) SpvRuntimeError!f32 {
    if (dim == .Buffer)
        return SpvRuntimeError.UnsupportedSpirV;

    const image_view: *SoftImageView = @ptrCast(@alignCast(context));
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
    const sampler: *SoftSampler = @ptrCast(@alignCast(context2));
    return SoftSampler.sampleImageDref(image, image_view, sampler, dim, x, y, z, w, dref, lod, offset) catch return SpvRuntimeError.Unknown;
}

fn queryImageSize(context: *anyopaque, dim: spv.SpvDim, arrayed: bool, lod: ?i32) SpvRuntimeError!spv.Runtime.Vec4(u32) {
    if (dim == .Buffer) {
        const buffer_view = try bufferViewFromContext(context);
        const range = try bufferViewRange(buffer_view);
        return .{
            .x = @intCast(@divTrunc(range, base.format.texelSize(buffer_view.interface.format))),
            .y = 0,
            .z = 0,
            .w = 0,
        };
    }

    const image_view: *SoftImageView = @ptrCast(@alignCast(context));
    const range = image_view.interface.subresource_range;
    const mip_lod: u32 = if (lod) |level| @intCast(@max(level, 0)) else 0;
    const max_lod = image_view.interface.levelCount() - 1;
    const mip_level = range.base_mip_level + @min(mip_lod, max_lod);
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
    const extent = image.getMipLevelExtent(mip_level);
    const layers = image_view.interface.layerCount();
    return switch (dim) {
        .@"1D" => if (arrayed)
            .{ .x = extent.width, .y = layers, .z = 0, .w = 0 }
        else
            .{ .x = extent.width, .y = 0, .z = 0, .w = 0 },
        .@"2D", .Cube, .Rect => if (arrayed)
            .{ .x = extent.width, .y = extent.height, .z = layers, .w = 0 }
        else
            .{ .x = extent.width, .y = extent.height, .z = 0, .w = 0 },
        .@"3D" => .{ .x = extent.width, .y = extent.height, .z = extent.depth, .w = 0 },
        else => .{ .x = extent.width, .y = extent.height, .z = layers, .w = 0 },
    };
}

fn queryImageSamples(context: *anyopaque) SpvRuntimeError!u32 {
    const image_view: *SoftImageView = @ptrCast(@alignCast(context));
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
    return @intCast(image.interface.samples.toInt());
}

fn queryImageLevels(context: *anyopaque) SpvRuntimeError!u32 {
    const image_view: *SoftImageView = @ptrCast(@alignCast(context));
    return image_view.interface.levelCount();
}

fn queryImageLod(context: *anyopaque, context2: *anyopaque, dim: spv.SpvDim, derivatives: spv.Runtime.ImageDerivatives) SpvRuntimeError!spv.Runtime.Vec4(f32) {
    const image_view: *SoftImageView = @ptrCast(@alignCast(context));
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
    const sampler: *SoftSampler = @ptrCast(@alignCast(context2));
    const lod = SoftSampler.queryImageLod(image, image_view, sampler, dim, derivatives);
    return .{
        .x = lod[0],
        .y = lod[1],
        .z = 0.0,
        .w = 0.0,
    };
}

test "external floating image fetch decodes sRGB before view swizzle and preserves alpha" {
    const SoftDeviceMemory = @import("SoftDeviceMemory.zig");
    var bytes = [_]u8{ 128, 64, 255, 128 };
    var memory: SoftDeviceMemory = .{ .interface = undefined, .data = &bytes };
    memory.interface.size = bytes.len;
    memory.interface.vtable = &.{
        .destroy = SoftDeviceMemory.destroy,
        .map = SoftDeviceMemory.map,
        .unmap = SoftDeviceMemory.unmap,
        .flushRange = SoftDeviceMemory.flushRange,
        .invalidateRange = SoftDeviceMemory.invalidateRange,
    };
    var device: base.Device = undefined;
    const image = try SoftImage.create(&device, std.testing.allocator, &.{
        .s_type = .image_create_info,
        .p_next = null,
        .flags = .{},
        .image_type = .@"2d",
        .format = .r8g8b8a8_srgb,
        .extent = .{ .width = 1, .height = 1, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1" = true },
        .tiling = .optimal,
        .usage = .{ .sampled = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = null,
        .initial_layout = .preinitialized,
    });
    defer image.interface.destroy(std.testing.allocator);
    image.interface.memory = &memory.interface;
    var view: SoftImageView = undefined;
    view.interface.image = &image.interface;
    view.interface.view_type = .@"2d";
    view.interface.format = .r8g8b8a8_srgb;
    view.interface.components = .{ .r = .b, .g = .r, .b = .g, .a = .identity };
    view.interface.subresource_range = .{
        .aspect_mask = .{ .color = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
    const pixel = try imageApi().readImageFloat4(&view, .@"2D", 0, 0, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), pixel.x, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2158605), pixel.y, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05126946), pixel.z, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), pixel.w, 0.00001);

    // Moving alpha into RGB and RGB into alpha distinguishes decode-before-swizzle.
    view.interface.components = .{ .r = .a, .g = .r, .b = .g, .a = .b };
    const reordered = try imageApi().readImageFloat4(&view, .@"2D", 0, 0, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), reordered.x, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2158605), reordered.y, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), reordered.w, 0.00001);

    view.interface.format = .r8g8b8a8_unorm;
    const linear = try imageApi().readImageFloat4(&view, .@"2D", 0, 0, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), linear.y, 0.00001);
}

test "external texel-buffer callbacks include buffer binding and view offsets" {
    const SoftDeviceMemory = @import("SoftDeviceMemory.zig");
    var bytes: [128]u8 = @splat(0xa5);
    var memory: SoftDeviceMemory = .{ .interface = undefined, .data = &bytes };
    memory.interface.size = bytes.len;
    memory.interface.vtable = &.{
        .destroy = SoftDeviceMemory.destroy,
        .map = SoftDeviceMemory.map,
        .unmap = SoftDeviceMemory.unmap,
        .flushRange = SoftDeviceMemory.flushRange,
        .invalidateRange = SoftDeviceMemory.invalidateRange,
    };
    var buffer: SoftBuffer = undefined;
    buffer.interface.memory = &memory.interface;
    buffer.interface.offset = 32;
    buffer.interface.size = 64;
    var view: SoftBufferView = undefined;
    view.interface.buffer = &buffer.interface;
    view.interface.offset = 16;
    view.interface.range = 8;
    view.interface.format = .r32_uint;

    const texel = try mapBufferViewTexel(&view, 1);
    try std.testing.expectEqual(@as(usize, 4), texel.len);
    try std.testing.expectEqual(@intFromPtr(&bytes[32 + 16 + 4]), @intFromPtr(texel.ptr));
    const integer: u32 = 0x12345678;
    try writeImageInt4(&view, .Buffer, 1, 0, 0, .{ .x = integer, .y = 0, .z = 0, .w = 0 });
    try std.testing.expectEqual(integer, (try readImageInt4(&view, .Buffer, 1, 0, 0, null)).x);

    view.interface.format = .r32_sfloat;
    const float: f32 = 1.25;
    try writeImageFloat4(&view, .Buffer, 0, 0, 0, .{ .x = float, .y = 0, .z = 0, .w = 0 });
    try std.testing.expectEqual(float, (try readImageFloat4(&view, .Buffer, 0, 0, 0, null)).x);
    var expected: [128]u8 = @splat(0xa5);
    @memcpy(expected[48..52], std.mem.asBytes(&float));
    @memcpy(expected[52..56], std.mem.asBytes(&integer));
    try std.testing.expectEqualSlices(u8, &expected, &bytes);

    try std.testing.expectError(SpvRuntimeError.Unknown, mapBufferViewTexel(&view, -1));
    try std.testing.expectError(SpvRuntimeError.Unknown, mapBufferViewTexel(&view, 2));
    view.interface.range = vk.WHOLE_SIZE;
    const last_texel = try mapBufferViewTexel(&view, 11);
    try std.testing.expectEqual(@intFromPtr(&bytes[32 + 16 + 11 * 4]), @intFromPtr(last_texel.ptr));
    try std.testing.expectError(SpvRuntimeError.Unknown, mapBufferViewTexel(&view, 12));
}

test "external image writes separate spatial coordinates from array layers and cube faces" {
    var image: SoftImage = undefined;
    image.interface.image_type = .@"2d";
    image.interface.extent = .{ .width = 16, .height = 16, .depth = 16 };
    image.interface.mip_levels = 3;
    image.interface.array_layers = 24;
    image.interface.flags = .{};
    var view: SoftImageView = undefined;
    view.interface.image = &image.interface;
    view.interface.subresource_range = .{
        .aspect_mask = .{ .color = true },
        .base_mip_level = 1,
        .level_count = 1,
        .base_array_layer = 6,
        .layer_count = 12,
    };
    const Case = struct {
        view_type: vk.ImageViewType,
        dim: spv.SpvDim,
        input: vk.Offset3D,
        coord: vk.Offset3D,
        layer: u32,
    };
    const cases = [_]Case{
        .{ .view_type = .@"1d_array", .dim = .@"1D", .input = .{ .x = 3, .y = 2, .z = -1 }, .coord = .{ .x = 3, .y = 0, .z = 0 }, .layer = 8 },
        .{ .view_type = .@"2d_array", .dim = .@"2D", .input = .{ .x = 3, .y = 4, .z = 2 }, .coord = .{ .x = 3, .y = 4, .z = 0 }, .layer = 8 },
        .{ .view_type = .cube, .dim = .Cube, .input = .{ .x = 3, .y = 4, .z = 5 }, .coord = .{ .x = 3, .y = 4, .z = 0 }, .layer = 11 },
        .{ .view_type = .cube_array, .dim = .Cube, .input = .{ .x = 3, .y = 4, .z = 8 }, .coord = .{ .x = 3, .y = 4, .z = 0 }, .layer = 14 },
        .{ .view_type = .@"3d", .dim = .@"3D", .input = .{ .x = 3, .y = 4, .z = 2 }, .coord = .{ .x = 3, .y = 4, .z = 2 }, .layer = 0 },
    };
    for (cases) |case| {
        view.interface.view_type = case.view_type;
        image.interface.image_type = switch (case.view_type) {
            .@"1d_array" => .@"1d",
            .@"3d" => .@"3d",
            else => .@"2d",
        };
        view.interface.subresource_range.base_array_layer = if (case.view_type == .@"3d") 0 else 6;
        view.interface.subresource_range.layer_count = switch (case.view_type) {
            .@"3d" => 1,
            .cube => 6,
            else => 12,
        };
        const location = imageWriteLocation(&view, case.dim, case.input.x, case.input.y, case.input.z).?;
        try std.testing.expectEqualDeep(case.coord, location.coord);
        try std.testing.expectEqual(case.layer, location.subresource.array_layer);
        try std.testing.expectEqual(@as(u32, 1), location.subresource.mip_level);
        try std.testing.expectEqualDeep(view.interface.subresource_range.aspect_mask, location.subresource.aspect_mask);
    }
}

test "external image writes discard coordinates outside the view and selected mip" {
    var image: SoftImage = undefined;
    image.interface.image_type = .@"2d";
    image.interface.extent = .{ .width = 16, .height = 16, .depth = 1 };
    image.interface.mip_levels = 3;
    image.interface.array_layers = 8;
    image.interface.flags = .{};
    var view: SoftImageView = undefined;
    view.interface.image = &image.interface;
    view.interface.view_type = .@"2d_array";
    view.interface.subresource_range = .{
        .aspect_mask = .{ .color = true },
        .base_mip_level = 1,
        .level_count = 1,
        .base_array_layer = 4,
        .layer_count = 2,
    };
    const outside = [_]vk.Offset3D{
        .{ .x = -1, .y = 0, .z = 0 },
        .{ .x = 0, .y = -1, .z = 0 },
        .{ .x = 0, .y = 0, .z = -1 },
        .{ .x = 8, .y = 0, .z = 0 },
        .{ .x = 0, .y = 8, .z = 0 },
        .{ .x = 0, .y = 0, .z = 2 },
    };
    for (outside) |coord| {
        try std.testing.expect(imageWriteLocation(&view, .@"2D", coord.x, coord.y, coord.z) == null);
        // Rejection must happen before either callback attempts to map image memory.
        try writeImageFloat4(&view, .@"2D", coord.x, coord.y, coord.z, .{ .x = 1, .y = 2, .z = 3, .w = 4 });
        try writeImageInt4(&view, .@"2D", coord.x, coord.y, coord.z, .{ .x = 1, .y = 2, .z = 3, .w = 4 });
    }
    try std.testing.expect(imageWriteLocation(&view, .@"2D", 7, 7, 1) != null);
    view.interface.subresource_range.layer_count = vk.REMAINING_ARRAY_LAYERS;
    try std.testing.expect(imageWriteLocation(&view, .@"2D", 0, 0, 3) != null);
    try std.testing.expect(imageWriteLocation(&view, .@"2D", 0, 0, 4) == null);
    view.interface.view_type = .@"1d_array";
    try std.testing.expect(imageWriteLocation(&view, .@"1D", 0, -1, 0) == null);
    try std.testing.expect(imageWriteLocation(&view, .@"1D", 0, 4, 0) == null);
    view.interface.view_type = .cube;
    view.interface.subresource_range.base_array_layer = 0;
    view.interface.subresource_range.layer_count = 6;
    try std.testing.expect(imageWriteLocation(&view, .Cube, 0, 0, -1) == null);
    try std.testing.expect(imageWriteLocation(&view, .Cube, 0, 0, 6) == null);
    view.interface.subresource_range.base_mip_level = 3;
    try std.testing.expect(imageWriteLocation(&view, .Cube, 0, 0, 0) == null);
}
