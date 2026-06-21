const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");

const zm = base.zm;

const blitter = @import("device/blitter.zig");

const Device = base.Device;
const VkError = base.VkError;
const SpvRuntimeError = spv.Runtime.RuntimeError;

pub threadlocal var current_fragment_coord: ?vk.Offset3D = null; // Ugly hack

const NonDispatchable = base.NonDispatchable;
const ShaderModule = base.ShaderModule;

const SoftDevice = @import("SoftDevice.zig");
const SoftBuffer = @import("SoftBuffer.zig");
const SoftBufferView = @import("SoftBufferView.zig");
const SoftImage = @import("SoftImage.zig");
const SoftImageView = @import("SoftImageView.zig");
const SoftInstance = @import("SoftInstance.zig");
const SoftSampler = @import("SoftSampler.zig");
const SoftShaderModule = @import("SoftShaderModule.zig");
const SoftPipelineCache = @import("SoftPipelineCache.zig");

const Self = @This();
pub const Interface = base.Pipeline;

const Runtime = struct {
    mutex: std.Io.Mutex,
    rt: spv.Runtime,
};

const Shader = struct {
    module: *SoftShaderModule,
    runtimes: []Runtime,
    entry: []const u8,
};

const Stages = enum {
    vertex,
    tessellation_control,
    tessellation_evaluation,
    geometry,
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

    const soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", device));
    const module = try NonDispatchable(ShaderModule).fromHandleObject(info.stage.module);
    const soft_module: *SoftShaderModule = @alignCast(@fieldParentPtr("interface", module));

    const device_allocator = soft_device.device_allocator.allocator();
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
            const cpu_count: usize = std.Thread.getCpuCount() catch break :blk @intFromEnum(count);
            break :blk if (@intFromEnum(count) >= cpu_count) cpu_count else @intFromEnum(count);
        },
    };

    self.stages.put(.compute, try createShader(allocator, device_allocator, runtimes_allocator, soft_cache, soft_module, &info.stage, runtimes_count));
    std.log.scoped(.ComputePipeline).debug("Created {d} runtimes for compute stage", .{runtimes_count});
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

    const soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", device));
    const device_allocator = soft_device.device_allocator.allocator();
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
            const cpu_count: usize = std.Thread.getCpuCount() catch break :blk @intFromEnum(count);
            break :blk if (@intFromEnum(count) >= cpu_count) cpu_count else @intFromEnum(count);
        },
    };

    if (info.p_stages) |stages| {
        for (stages[0..], 0..info.stage_count) |stage, _| {
            const module = try NonDispatchable(ShaderModule).fromHandleObject(stage.module);
            const soft_module: *SoftShaderModule = @alignCast(@fieldParentPtr("interface", module));
            const shader = try createShader(allocator, device_allocator, runtimes_allocator, soft_cache, soft_module, &stage, runtimes_count);

            std.log.scoped(.GraphicsPipeline).debug("Created {d} runtimes for:", .{runtimes_count});

            if (stage.stage.contains(.{ .vertex_bit = true })) {
                std.log.scoped(.GraphicsPipeline).debug(">   Vertex stage", .{});
                self.stages.put(.vertex, shader);
            } else if (stage.stage.contains(.{ .fragment_bit = true })) {
                std.log.scoped(.GraphicsPipeline).debug(">   Fragment stage", .{});
                self.stages.put(.fragment, shader);
            } else if (stage.stage.contains(.{ .tessellation_control_bit = true })) {
                std.log.scoped(.GraphicsPipeline).debug(">   Tessellation control stage", .{});
                self.stages.put(.tessellation_control, shader);
            } else if (stage.stage.contains(.{ .tessellation_evaluation_bit = true })) {
                std.log.scoped(.GraphicsPipeline).debug(">   Tessellation evaluation stage", .{});
                self.stages.put(.tessellation_evaluation, shader);
            } else if (stage.stage.contains(.{ .geometry_bit = true })) {
                std.log.scoped(.GraphicsPipeline).debug(">   Geometry stage", .{});
                self.stages.put(.geometry, shader);
            } else {
                std.log.scoped(.GraphicsPipeline).err(">   invalid stage", .{});
                return VkError.Unknown;
            }
        }
    } else {
        return VkError.ValidationFailed;
    }

    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    const soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", interface.owner));
    const device_allocator = soft_device.device_allocator.allocator();

    var it = self.stages.iterator();
    while (it.next()) |entry| {
        entry.value.module.unref(allocator);
        for (entry.value.runtimes) |*runtime| {
            runtime.rt.function_stack.clearAndFree(device_allocator); // Hacky to avoid leaks
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
    runtimes_count: usize,
) VkError!Shader {
    const entry = std.mem.span(stage.p_name);
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
        if (try pipeline_cache.cloneRuntime(runtimes_allocator, module, entry, stage.p_specialization_info, image_api)) |runtime| {
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
                .rt = (try cache.?.cloneRuntime(runtimes_allocator, module, entry, stage.p_specialization_info, image_api)).?,
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

        if (cache) |pipeline_cache| {
            try pipeline_cache.storeRuntimeTemplate(object_allocator, cache_allocator, module, entry, stage.p_specialization_info, image_api);
        }
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

    try applySpecialization(&runtime, allocator, stage.p_specialization_info);
    return runtime;
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
    if (aspect.depth_bit and aspect.stencil_bit) {
        return if (int_read) .{ .stencil_bit = true } else .{ .depth_bit = true };
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
    return .{ .x = coord.x + x, .y = coord.y + y, .z = coord.z + z };
}

fn readImageFloat4(context: *anyopaque, dim: spv.SpvDim, x: i32, y: i32, z: i32, lod: ?i32) SpvRuntimeError!spv.Runtime.Vec4(f32) {
    var pixel = zm.f32x4s(0.0);
    if (dim == .Buffer) {
        const buffer_view: *SoftBufferView = @ptrCast(@alignCast(context));
        const buffer: *SoftBuffer = @alignCast(@fieldParentPtr("interface", buffer_view.interface.buffer));
        const map = buffer.mapAsSliceWithOffset(u8, buffer_view.interface.offset, buffer_view.interface.range) catch return SpvRuntimeError.Unknown;
        pixel = blitter.readFloat4(map[(@as(usize, @intCast(x)) * base.format.texelSize(buffer_view.interface.format))..], buffer_view.interface.format);
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
        const array_layer = image_view.interface.subresource_range.base_array_layer + switch (image_view.interface.view_type) {
            .@"1d_array" => @as(u32, @intCast(y)),
            .@"2d_array" => @as(u32, @intCast(z)),
            .cube => cube_face,
            else => 0,
        };
        const aspect_mask = imageReadAspect(image_view, false);
        const subresource = vk.ImageSubresource{
            .aspect_mask = aspect_mask,
            .mip_level = mip_level,
            .array_layer = array_layer,
        };
        const sample_index: u32 = if (image.interface.samples.toInt() > 1) @intCast(z) else 0;
        pixel = SoftSampler.swizzleFloat4(readImageFloat4Sample(
            image,
            image_coord,
            subresource,
            base.format.fromAspect(image_view.interface.format, aspect_mask),
            sample_index,
        ) catch return SpvRuntimeError.Unknown, image_view.interface.components);
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
        const buffer_view: *SoftBufferView = @ptrCast(@alignCast(context));
        const buffer: *SoftBuffer = @alignCast(@fieldParentPtr("interface", buffer_view.interface.buffer));
        const map = buffer.mapAsSliceWithOffset(u8, buffer_view.interface.offset, buffer_view.interface.range) catch return SpvRuntimeError.Unknown;
        pixel = blitter.readInt4(map[(@as(usize, @intCast(x)) * base.format.texelSize(buffer_view.interface.format))..], buffer_view.interface.format);
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
        const array_layer = image_view.interface.subresource_range.base_array_layer + switch (image_view.interface.view_type) {
            .@"1d_array" => @as(u32, @intCast(y)),
            .@"2d_array" => @as(u32, @intCast(z)),
            .cube => cube_face,
            else => 0,
        };
        const aspect_mask = imageReadAspect(image_view, true);
        const subresource = vk.ImageSubresource{
            .aspect_mask = aspect_mask,
            .mip_level = mip_level,
            .array_layer = array_layer,
        };
        const sample_index: u32 = if (image.interface.samples.toInt() > 1) @intCast(z) else 0;
        pixel = SoftSampler.swizzleInt4(readImageInt4Sample(
            image,
            image_coord,
            subresource,
            base.format.fromAspect(image_view.interface.format, aspect_mask),
            sample_index,
        ) catch return SpvRuntimeError.Unknown, image_view.interface.components);
    }
    return .{
        .x = pixel[0],
        .y = pixel[1],
        .z = pixel[2],
        .w = pixel[3],
    };
}

fn writeImageFloat4(context: *anyopaque, dim: spv.SpvDim, x: i32, y: i32, z: i32, pixel: spv.Runtime.Vec4(f32)) SpvRuntimeError!void {
    const vec_pixel = zm.f32x4(pixel.x, pixel.y, pixel.z, pixel.w);
    if (dim == .Buffer) {
        const buffer_view: *SoftBufferView = @ptrCast(@alignCast(context));
        const buffer: *SoftBuffer = @alignCast(@fieldParentPtr("interface", buffer_view.interface.buffer));
        const map = buffer.mapAsSliceWithOffset(u8, buffer_view.interface.offset, buffer_view.interface.range) catch return SpvRuntimeError.Unknown;
        blitter.writeFloat4(vec_pixel, map[(@as(usize, @intCast(x)) * base.format.texelSize(buffer_view.interface.format))..], buffer_view.interface.format);
    } else {
        const image_view: *SoftImageView = @ptrCast(@alignCast(context));
        const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
        const cube_face: u32 = if (dim == .Cube) @intCast(z) else 0;
        image.writeFloat4(
            .{
                .x = x,
                .y = y,
                .z = if (dim == .Cube) 0 else z,
            },
            .{
                .aspect_mask = image_view.interface.subresource_range.aspect_mask,
                .mip_level = image_view.interface.subresource_range.base_mip_level,
                .array_layer = image_view.interface.subresource_range.base_array_layer + cube_face,
            },
            image_view.interface.format,
            vec_pixel,
        ) catch return SpvRuntimeError.Unknown;
    }
}

fn writeImageInt4(context: *anyopaque, dim: spv.SpvDim, x: i32, y: i32, z: i32, pixel: spv.Runtime.Vec4(u32)) SpvRuntimeError!void {
    const vec_pixel = @Vector(4, u32){ pixel.x, pixel.y, pixel.z, pixel.w };
    if (dim == .Buffer) {
        const buffer_view: *SoftBufferView = @ptrCast(@alignCast(context));
        const buffer: *SoftBuffer = @alignCast(@fieldParentPtr("interface", buffer_view.interface.buffer));
        const map = buffer.mapAsSliceWithOffset(u8, buffer_view.interface.offset, buffer_view.interface.range) catch return SpvRuntimeError.Unknown;
        blitter.writeInt4(vec_pixel, map[(@as(usize, @intCast(x)) * base.format.texelSize(buffer_view.interface.format))..], buffer_view.interface.format);
    } else {
        const image_view: *SoftImageView = @ptrCast(@alignCast(context));
        const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
        const cube_face: u32 = if (dim == .Cube) @intCast(z) else 0;
        image.writeInt4(
            .{
                .x = x,
                .y = y,
                .z = if (dim == .Cube) 0 else z,
            },
            .{
                .aspect_mask = image_view.interface.subresource_range.aspect_mask,
                .mip_level = image_view.interface.subresource_range.base_mip_level,
                .array_layer = image_view.interface.subresource_range.base_array_layer + cube_face,
            },
            image_view.interface.format,
            vec_pixel,
        ) catch return SpvRuntimeError.Unknown;
    }
}

fn sampleImageFloat4(context: *anyopaque, context2: *anyopaque, dim: spv.SpvDim, x: f32, y: f32, z: f32, lod: ?f32, offset: spv.Runtime.ImageOffset) SpvRuntimeError!spv.Runtime.Vec4(f32) {
    var pixel = zm.f32x4s(0.0);

    if (dim == .Buffer) {
        const buffer_view: *SoftBufferView = @ptrCast(@alignCast(context));
        const buffer: *SoftBuffer = @alignCast(@fieldParentPtr("interface", buffer_view.interface.buffer));
        const map = buffer.mapAsSliceWithOffset(u8, buffer_view.interface.offset, buffer_view.interface.range) catch return SpvRuntimeError.Unknown;
        _ = map;
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
        const buffer_view: *SoftBufferView = @ptrCast(@alignCast(context));
        const buffer: *SoftBuffer = @alignCast(@fieldParentPtr("interface", buffer_view.interface.buffer));
        const map = buffer.mapAsSliceWithOffset(u8, buffer_view.interface.offset, buffer_view.interface.range) catch return SpvRuntimeError.Unknown;
        _ = map;
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

fn sampleImageDref(context: *anyopaque, context2: *anyopaque, dim: spv.SpvDim, x: f32, y: f32, z: f32, dref: f32, lod: ?f32, offset: spv.Runtime.ImageOffset) SpvRuntimeError!f32 {
    if (dim == .Buffer)
        return SpvRuntimeError.UnsupportedSpirV;

    const image_view: *SoftImageView = @ptrCast(@alignCast(context));
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
    const sampler: *SoftSampler = @ptrCast(@alignCast(context2));
    return SoftSampler.sampleImageDref(image, image_view, sampler, dim, x, y, z, dref, lod, offset) catch return SpvRuntimeError.Unknown;
}

fn queryImageSize(context: *anyopaque, dim: spv.SpvDim, arrayed: bool, lod: ?i32) SpvRuntimeError!spv.Runtime.Vec4(u32) {
    if (dim == .Buffer) {
        const buffer_view: *SoftBufferView = @ptrCast(@alignCast(context));
        const range = if (buffer_view.interface.range == vk.WHOLE_SIZE)
            buffer_view.interface.buffer.size - buffer_view.interface.offset
        else
            buffer_view.interface.range;
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
