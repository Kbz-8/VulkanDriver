const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");

const zm = base.zm;

const blitter = @import("device/blitter.zig");

const Device = base.Device;
const VkError = base.VkError;
const SpvRuntimeError = spv.Runtime.RuntimeError;

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
    errdefer allocator.destroy(self);

    var interface = try Interface.initCompute(device, allocator, cache, info);

    interface.vtable = &.{
        .destroy = destroy,
    };

    const soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", device));
    const module = try NonDispatchable(ShaderModule).fromHandleObject(info.stage.module);
    const soft_module: *SoftShaderModule = @alignCast(@fieldParentPtr("interface", module));

    const device_allocator = soft_device.device_allocator.allocator();

    self.* = .{
        .interface = interface,
        .runtimes_allocator = .init(device_allocator),
        .stages = std.EnumMap(Stages, Shader).init(.{}),
    };
    errdefer self.runtimes_allocator.deinit();
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

    self.stages.put(.compute, blk: {
        var shader: Shader = undefined;
        soft_module.ref();
        shader.module = soft_module;

        const runtimes = runtimes_allocator.alloc(Runtime, runtimes_count) catch return VkError.OutOfDeviceMemory;

        for (runtimes) |*runtime| {
            runtime.mutex = .init;
            runtime.rt = spv.Runtime.init(
                runtimes_allocator,
                &soft_module.module,
                .{
                    .readImageFloat4 = readImageFloat4,
                    .readImageInt4 = readImageInt4,
                    .writeImageFloat4 = writeImageFloat4,
                    .writeImageInt4 = writeImageInt4,
                    .sampleImageFloat4 = sampleImageFloat4,
                    .queryImageSize = queryImageSize,
                },
            ) catch |err| {
                std.log.scoped(.SpvRuntimeInit).err("SPIR-V Runtime failed to initialize, {s}", .{@errorName(err)});
                return VkError.Unknown;
            };
            if (info.stage.p_specialization_info) |specialization| {
                if (specialization.p_map_entries) |map| {
                    const data: []const u8 = @as([*]const u8, @ptrCast(@alignCast(specialization.p_data)))[0..specialization.data_size];
                    for (map[0..], 0..specialization.map_entry_count) |entry, _| {
                        runtime.rt.addSpecializationInfo(
                            runtimes_allocator,
                            .{
                                .id = @intCast(entry.constant_id),
                                .offset = @intCast(entry.offset),
                                .size = @intCast(entry.size),
                            },
                            data,
                        ) catch return VkError.OutOfDeviceMemory;
                    }
                }
            }
        }

        shader.runtimes = runtimes;
        shader.entry = runtimes_allocator.dupe(u8, std.mem.span(info.stage.p_name)) catch return VkError.OutOfDeviceMemory;

        std.log.scoped(.ComputePipeline).debug("Created {d} runtimes for compute stage", .{runtimes_count});
        break :blk shader;
    });
    return self;
}

pub fn createGraphics(device: *base.Device, allocator: std.mem.Allocator, cache: ?*base.PipelineCache, info: *const vk.GraphicsPipelineCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.initGraphics(device, allocator, cache, info);

    interface.vtable = &.{
        .destroy = destroy,
    };

    const soft_device: *SoftDevice = @alignCast(@fieldParentPtr("interface", device));
    const device_allocator = soft_device.device_allocator.allocator();

    self.* = .{
        .interface = interface,
        .runtimes_allocator = .init(device_allocator),
        .stages = std.EnumMap(Stages, Shader).init(.{}),
    };
    errdefer self.runtimes_allocator.deinit();
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
            var shader: Shader = undefined;

            const module = try NonDispatchable(ShaderModule).fromHandleObject(stage.module);
            const soft_module: *SoftShaderModule = @alignCast(@fieldParentPtr("interface", module));
            soft_module.ref();
            shader.module = soft_module;

            const runtimes = runtimes_allocator.alloc(Runtime, runtimes_count) catch return VkError.OutOfHostMemory;

            for (runtimes) |*runtime| {
                runtime.mutex = .init;
                runtime.rt = spv.Runtime.init(
                    runtimes_allocator,
                    &soft_module.module,
                    .{
                        .readImageFloat4 = readImageFloat4,
                        .readImageInt4 = readImageInt4,
                        .writeImageFloat4 = writeImageFloat4,
                        .writeImageInt4 = writeImageInt4,
                        .sampleImageFloat4 = sampleImageFloat4,
                        .queryImageSize = queryImageSize,
                    },
                ) catch |err| {
                    std.log.scoped(.SpvRuntimeInit).err("SPIR-V Runtime failed to initialize, {s}", .{@errorName(err)});
                    return VkError.Unknown;
                };
                if (stage.p_specialization_info) |specialization| {
                    if (specialization.p_map_entries) |map| {
                        const data: []const u8 = @as([*]const u8, @ptrCast(@alignCast(specialization.p_data)))[0..specialization.data_size];
                        for (map[0..], 0..specialization.map_entry_count) |entry, _| {
                            runtime.rt.addSpecializationInfo(runtimes_allocator, .{
                                .id = @intCast(entry.constant_id),
                                .offset = @intCast(entry.offset),
                                .size = @intCast(entry.size),
                            }, data) catch return VkError.OutOfHostMemory;
                        }
                    }
                }
            }

            shader.runtimes = runtimes;
            shader.entry = runtimes_allocator.dupe(u8, std.mem.span(stage.p_name)) catch return VkError.OutOfHostMemory;

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

fn readImageFloat4(context: *anyopaque, dim: spv.SpvDim, x: i32, y: i32, z: i32) SpvRuntimeError!spv.Runtime.Vec4(f32) {
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
        pixel = image.readFloat4(
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
        ) catch return SpvRuntimeError.Unknown;
    }
    return .{
        .x = pixel[0],
        .y = pixel[1],
        .z = pixel[2],
        .w = pixel[3],
    };
}

fn readImageInt4(context: *anyopaque, dim: spv.SpvDim, x: i32, y: i32, z: i32) SpvRuntimeError!spv.Runtime.Vec4(u32) {
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
        pixel = image.readInt4(
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
        ) catch return SpvRuntimeError.Unknown;
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

const CubeCoordinate = struct {
    face: u32,
    u: f32,
    v: f32,
    w: f32 = 0.0,
};

fn resolveCubeCoordinate(x: f32, y: f32, z: f32) CubeCoordinate {
    const ax = @abs(x);
    const ay = @abs(y);
    const az = @abs(z);

    var face: u32 = 0;
    var sc: f32 = 0.0;
    var tc: f32 = 0.0;
    var ma: f32 = 1.0;

    if (ax >= ay and ax >= az) {
        ma = ax;
        if (x >= 0.0) {
            face = 0;
            sc = -z;
            tc = -y;
        } else {
            face = 1;
            sc = z;
            tc = -y;
        }
    } else if (ay >= ax and ay >= az) {
        ma = ay;
        if (y >= 0.0) {
            face = 2;
            sc = x;
            tc = z;
        } else {
            face = 3;
            sc = x;
            tc = -z;
        }
    } else {
        ma = az;
        if (z >= 0.0) {
            face = 4;
            sc = x;
            tc = -y;
        } else {
            face = 5;
            sc = -x;
            tc = -y;
        }
    }

    const inv_ma = if (ma == 0.0) 0.0 else 1.0 / ma;
    return .{
        .face = face,
        .u = (sc * inv_ma + 1.0) * 0.5,
        .v = (tc * inv_ma + 1.0) * 0.5,
    };
}

fn cubeDirection(face: u32, u: f32, v: f32) struct { x: f32, y: f32, z: f32 } {
    const sc = u * 2.0 - 1.0;
    const tc = v * 2.0 - 1.0;

    return switch (face) {
        0 => .{ .x = 1.0, .y = -tc, .z = -sc },
        1 => .{ .x = -1.0, .y = -tc, .z = sc },
        2 => .{ .x = sc, .y = 1.0, .z = tc },
        3 => .{ .x = sc, .y = -1.0, .z = -tc },
        4 => .{ .x = sc, .y = -tc, .z = 1.0 },
        5 => .{ .x = -sc, .y = -tc, .z = -1.0 },
        else => .{ .x = 0.0, .y = 0.0, .z = 0.0 },
    };
}

fn readSampledFloat4(
    image: *SoftImage,
    image_view: *SoftImageView,
    sampler: *SoftSampler,
    dim: spv.SpvDim,
    coord: CubeCoordinate,
    ix: i32,
    iy: i32,
    iz: i32,
) VkError!zm.F32x4 {
    const range = image_view.interface.subresource_range;
    const extent = image.getMipLevelExtent(range.base_mip_level);
    const width_f: f32 = @floatFromInt(extent.width);
    const height_f: f32 = @floatFromInt(extent.height);

    const texel = if (dim == .Cube) blk: {
        const dir = cubeDirection(
            coord.face,
            (@as(f32, @floatFromInt(ix)) + 0.5) / width_f,
            (@as(f32, @floatFromInt(iy)) + 0.5) / height_f,
        );
        break :blk resolveCubeCoordinate(dir.x, dir.y, dir.z);
    } else coord;

    const z: i32, const layer: u32 = switch (image_view.interface.view_type) {
        .@"1d_array" => .{ 0, range.base_array_layer + @as(u32, @intCast(sampleAddress(@intFromFloat(coord.v), viewLayerCount(image, range), .clamp_to_edge))) },
        .@"2d_array", .cube_array => .{ 0, range.base_array_layer + @as(u32, @intCast(sampleAddress(@intFromFloat(coord.w), viewLayerCount(image, range), .clamp_to_edge))) },
        .@"3d" => .{ sampleAddressOrBorder(iz, extent.depth, sampler.interface.address_mode_w) orelse return samplerBorderColor(sampler), range.base_array_layer },
        .cube => .{ 0, range.base_array_layer + texel.face },
        else => .{ 0, range.base_array_layer },
    };

    const sx = if (dim == .Cube)
        std.math.clamp(@as(i32, @intFromFloat(texel.u * width_f)), 0, @as(i32, @intCast(extent.width)) - 1)
    else
        sampleAddressOrBorder(ix, extent.width, sampler.interface.address_mode_u) orelse return samplerBorderColor(sampler);
    const sy = if (dim == .Cube)
        std.math.clamp(@as(i32, @intFromFloat(texel.v * height_f)), 0, @as(i32, @intCast(extent.height)) - 1)
    else
        sampleAddressOrBorder(iy, extent.height, sampler.interface.address_mode_v) orelse return samplerBorderColor(sampler);

    const result = try image.readFloat4(
        .{
            .x = sx,
            .y = sy,
            .z = z,
        },
        .{
            .aspect_mask = range.aspect_mask,
            .mip_level = range.base_mip_level,
            .array_layer = layer,
        },
        image_view.interface.format,
    );
    return result;
}

fn sampleAddress(coord: i32, extent: u32, mode: vk.SamplerAddressMode) i32 {
    return sampleAddressOrBorder(coord, extent, mode).?;
}

fn sampleAddressOrBorder(coord: i32, extent: u32, mode: vk.SamplerAddressMode) ?i32 {
    const extent_i: i32 = @intCast(extent);
    return switch (mode) {
        .repeat => @mod(coord, extent_i),
        .mirrored_repeat => blk: {
            const period = extent_i * 2;
            const mirrored = @mod(coord, period);
            break :blk if (mirrored < extent_i) mirrored else period - mirrored - 1;
        },
        .clamp_to_border => if (coord < 0 or coord >= extent_i) null else coord,
        else => std.math.clamp(coord, 0, extent_i - 1),
    };
}

fn samplerBorderColor(sampler: *SoftSampler) zm.F32x4 {
    return switch (sampler.interface.border_color) {
        .float_opaque_white, .int_opaque_white => .{ 1.0, 1.0, 1.0, 1.0 },
        .float_opaque_black, .int_opaque_black => .{ 0.0, 0.0, 0.0, 1.0 },
        else => .{ 0.0, 0.0, 0.0, 0.0 },
    };
}

fn viewLayerCount(image: *SoftImage, range: vk.ImageSubresourceRange) u32 {
    return if (range.layer_count == vk.REMAINING_ARRAY_LAYERS)
        image.interface.array_layers - range.base_array_layer
    else
        range.layer_count;
}

fn sampleNearestFloat4(image: *SoftImage, image_view: *SoftImageView, sampler: *SoftSampler, dim: spv.SpvDim, coord: CubeCoordinate) VkError!zm.F32x4 {
    const extent = image.getMipLevelExtent(image_view.interface.subresource_range.base_mip_level);
    const width_f: f32 = @floatFromInt(extent.width);
    const height_f: f32 = @floatFromInt(extent.height);
    return readSampledFloat4(
        image,
        image_view,
        sampler,
        dim,
        coord,
        @intFromFloat(coord.u * width_f),
        @intFromFloat(coord.v * height_f),
        @intFromFloat(coord.w * @as(f32, @floatFromInt(extent.depth))),
    );
}

fn sampleLinearFloat4(image: *SoftImage, image_view: *SoftImageView, sampler: *SoftSampler, dim: spv.SpvDim, coord: CubeCoordinate) VkError!zm.F32x4 {
    const extent = image.getMipLevelExtent(image_view.interface.subresource_range.base_mip_level);
    const width_f: f32 = @floatFromInt(extent.width);
    const height_f: f32 = @floatFromInt(extent.height);
    const x = coord.u * width_f - 0.5;
    const y = coord.v * height_f - 0.5;
    const z = coord.w * @as(f32, @floatFromInt(extent.depth)) - 0.5;
    const x0: i32 = @intFromFloat(@floor(x));
    const y0: i32 = @intFromFloat(@floor(y));
    const z0: i32 = @intFromFloat(@floor(z));
    const x1 = x0 + 1;
    const y1 = y0 + 1;
    const z1 = z0 + 1;
    const wx = x - @as(f32, @floatFromInt(x0));
    const wy = y - @as(f32, @floatFromInt(y0));
    const wz = z - @as(f32, @floatFromInt(z0));

    const p000 = try readSampledFloat4(image, image_view, sampler, dim, coord, x0, y0, z0);
    const p100 = try readSampledFloat4(image, image_view, sampler, dim, coord, x1, y0, z0);
    const p010 = try readSampledFloat4(image, image_view, sampler, dim, coord, x0, y1, z0);
    const p110 = try readSampledFloat4(image, image_view, sampler, dim, coord, x1, y1, z0);

    const row00 = p000 * zm.f32x4s(1.0 - wx) + p100 * zm.f32x4s(wx);
    const row10 = p010 * zm.f32x4s(1.0 - wx) + p110 * zm.f32x4s(wx);
    const slice0 = row00 * zm.f32x4s(1.0 - wy) + row10 * zm.f32x4s(wy);

    if (image_view.interface.view_type != .@"3d")
        return slice0;

    const p001 = try readSampledFloat4(image, image_view, sampler, dim, coord, x0, y0, z1);
    const p101 = try readSampledFloat4(image, image_view, sampler, dim, coord, x1, y0, z1);
    const p011 = try readSampledFloat4(image, image_view, sampler, dim, coord, x0, y1, z1);
    const p111 = try readSampledFloat4(image, image_view, sampler, dim, coord, x1, y1, z1);

    const row01 = p001 * zm.f32x4s(1.0 - wx) + p101 * zm.f32x4s(wx);
    const row11 = p011 * zm.f32x4s(1.0 - wx) + p111 * zm.f32x4s(wx);
    const slice1 = row01 * zm.f32x4s(1.0 - wy) + row11 * zm.f32x4s(wy);

    return slice0 * zm.f32x4s(1.0 - wz) + slice1 * zm.f32x4s(wz);
}

fn sampleImageFloat4(context: *anyopaque, context2: *anyopaque, dim: spv.SpvDim, x: f32, y: f32, z: f32) SpvRuntimeError!spv.Runtime.Vec4(f32) {
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

        if (dim == .Cube) {
            const coord = resolveCubeCoordinate(x, y, z);
            pixel = switch (sampler.interface.mag_filter) {
                .linear => sampleLinearFloat4(image, image_view, sampler, dim, coord),
                else => sampleNearestFloat4(image, image_view, sampler, dim, coord),
            } catch return SpvRuntimeError.Unknown;
        } else {
            const coord: CubeCoordinate = .{
                .u = x,
                .v = y,
                .w = z,
                .face = 0,
            };
            pixel = switch (sampler.interface.mag_filter) {
                .linear => sampleLinearFloat4(image, image_view, sampler, dim, coord),
                else => sampleNearestFloat4(image, image_view, sampler, dim, coord),
            } catch return SpvRuntimeError.Unknown;
        }
    }

    return .{
        .x = pixel[0],
        .y = pixel[1],
        .z = pixel[2],
        .w = pixel[3],
    };
}

fn queryImageSize(context: *anyopaque, dim: spv.SpvDim, arrayed: bool) SpvRuntimeError!spv.Runtime.Vec4(u32) {
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
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
    const extent = image.getMipLevelExtent(image_view.interface.subresource_range.base_mip_level);
    const layers = if (image_view.interface.subresource_range.layer_count == vk.REMAINING_ARRAY_LAYERS)
        image.interface.array_layers - image_view.interface.subresource_range.base_array_layer
    else
        image_view.interface.subresource_range.layer_count;
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
