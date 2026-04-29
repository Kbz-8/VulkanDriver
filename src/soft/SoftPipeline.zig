const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");

const Device = base.Device;
const VkError = base.VkError;
const SpvRuntimeError = spv.Runtime.RuntimeError;

const NonDispatchable = base.NonDispatchable;
const ShaderModule = base.ShaderModule;

const SoftDevice = @import("SoftDevice.zig");
const SoftImage = @import("SoftImage.zig");
const SoftImageView = @import("SoftImageView.zig");
const SoftInstance = @import("SoftInstance.zig");
const SoftShaderModule = @import("SoftShaderModule.zig");

const Self = @This();
pub const Interface = base.Pipeline;

const Shader = struct {
    module: *SoftShaderModule,
    runtimes: []spv.Runtime,
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

    var runtimes_allocator_arena: std.heap.ArenaAllocator = .init(device_allocator);
    errdefer runtimes_allocator_arena.deinit();
    const runtimes_allocator = runtimes_allocator_arena.allocator();

    const instance: *SoftInstance = @alignCast(@fieldParentPtr("interface", device.instance));
    const runtimes_count = switch (instance.threaded.async_limit) {
        .nothing => 1,
        .unlimited => std.Thread.getCpuCount() catch 1, // If we cannot get the CPU count, fallback on single runtime
        else => |count| blk: {
            const cpu_count: usize = std.Thread.getCpuCount() catch break :blk @intFromEnum(count);
            break :blk if (@intFromEnum(count) >= cpu_count) cpu_count else @intFromEnum(count);
        },
    };

    self.* = .{
        .interface = interface,
        .runtimes_allocator = runtimes_allocator_arena,
        .stages = std.EnumMap(Stages, Shader).init(.{
            .compute = blk: {
                var shader: Shader = undefined;
                soft_module.ref();
                shader.module = soft_module;

                const runtimes = runtimes_allocator.alloc(spv.Runtime, runtimes_count) catch return VkError.OutOfDeviceMemory;

                for (runtimes) |*runtime| {
                    runtime.* = spv.Runtime.init(
                        runtimes_allocator,
                        &soft_module.module,
                        .{
                            .readImageFloat4 = readImageFloat4,
                            .readImageInt4 = readImageInt4,
                            .writeImageFloat4 = writeImageFloat4,
                            .writeImageInt4 = writeImageInt4,
                        },
                    ) catch |err| {
                        std.log.scoped(.SpvRuntimeInit).err("SPIR-V Runtime failed to initialize, {s}", .{@errorName(err)});
                        return VkError.Unknown;
                    };
                    if (info.stage.p_specialization_info) |specialization| {
                        if (specialization.p_map_entries) |map| {
                            const data: []const u8 = @as([*]const u8, @ptrCast(@alignCast(specialization.p_data)))[0..specialization.data_size];
                            for (map[0..], 0..specialization.map_entry_count) |entry, _| {
                                runtime.addSpecializationInfo(
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
            },
        }),
    };
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

    var runtimes_allocator_arena: std.heap.ArenaAllocator = .init(device_allocator);
    errdefer runtimes_allocator_arena.deinit();
    const runtimes_allocator = runtimes_allocator_arena.allocator();

    const instance: *SoftInstance = @alignCast(@fieldParentPtr("interface", device.instance));
    const runtimes_count = switch (instance.threaded.async_limit) {
        .nothing => 1,
        .unlimited => std.Thread.getCpuCount() catch 1, // If we cannot get the CPU count, fallback on single runtime
        else => |count| blk: {
            const cpu_count: usize = std.Thread.getCpuCount() catch break :blk @intFromEnum(count);
            break :blk if (@intFromEnum(count) >= cpu_count) cpu_count else @intFromEnum(count);
        },
    };

    self.* = .{
        .interface = interface,
        .runtimes_allocator = runtimes_allocator_arena,
        .stages = std.EnumMap(Stages, Shader).init(.{}),
    };

    if (info.p_stages) |stages| {
        for (stages[0..], 0..info.stage_count) |stage, _| {
            var shader: Shader = undefined;

            const module = try NonDispatchable(ShaderModule).fromHandleObject(stage.module);
            const soft_module: *SoftShaderModule = @alignCast(@fieldParentPtr("interface", module));
            soft_module.ref();
            shader.module = soft_module;

            const runtimes = runtimes_allocator.alloc(spv.Runtime, runtimes_count) catch return VkError.OutOfHostMemory;

            for (runtimes) |*runtime| {
                runtime.* = spv.Runtime.init(
                    runtimes_allocator,
                    &soft_module.module,
                    .{
                        .readImageFloat4 = readImageFloat4,
                        .readImageInt4 = readImageInt4,
                        .writeImageFloat4 = writeImageFloat4,
                        .writeImageInt4 = writeImageInt4,
                    },
                ) catch |err| {
                    std.log.scoped(.SpvRuntimeInit).err("SPIR-V Runtime failed to initialize, {s}", .{@errorName(err)});
                    return VkError.Unknown;
                };
                if (stage.p_specialization_info) |specialization| {
                    if (specialization.p_map_entries) |map| {
                        const data: []const u8 = @as([*]const u8, @ptrCast(@alignCast(specialization.p_data)))[0..specialization.data_size];
                        for (map[0..], 0..specialization.map_entry_count) |entry, _| {
                            runtime.addSpecializationInfo(runtimes_allocator, .{
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
    var it = self.stages.iterator();
    while (it.next()) |entry| {
        entry.value.module.unref(allocator);
    }
    self.runtimes_allocator.deinit();
    allocator.destroy(self);
}

fn readImageFloat4(context: *anyopaque, x: i32, y: i32, z: i32) SpvRuntimeError!spv.Runtime.Vec4(f32) {
    const image_view: *SoftImageView = @ptrCast(@alignCast(context));
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
    const pixel = image.readFloat4(
        .{
            .x = x,
            .y = y,
            .z = z,
        },
        .{
            .aspect_mask = image_view.interface.subresource_range.aspect_mask,
            .mip_level = image_view.interface.subresource_range.base_mip_level,
            .array_layer = image_view.interface.subresource_range.base_array_layer,
        },
        image_view.interface.format,
    ) catch return SpvRuntimeError.Unknown;
    return .{
        .x = pixel[0],
        .y = pixel[1],
        .z = pixel[2],
        .w = pixel[3],
    };
}

fn readImageInt4(context: *anyopaque, x: i32, y: i32, z: i32) SpvRuntimeError!spv.Runtime.Vec4(u32) {
    const image_view: *SoftImageView = @ptrCast(@alignCast(context));
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
    const pixel = image.readInt4(
        .{
            .x = x,
            .y = y,
            .z = z,
        },
        .{
            .aspect_mask = image_view.interface.subresource_range.aspect_mask,
            .mip_level = image_view.interface.subresource_range.base_mip_level,
            .array_layer = image_view.interface.subresource_range.base_array_layer,
        },
        image_view.interface.format,
    ) catch return SpvRuntimeError.Unknown;
    return .{
        .x = pixel[0],
        .y = pixel[1],
        .z = pixel[2],
        .w = pixel[3],
    };
}

fn writeImageFloat4(context: *anyopaque, x: i32, y: i32, z: i32, pixel: spv.Runtime.Vec4(f32)) SpvRuntimeError!void {
    const image_view: *SoftImageView = @ptrCast(@alignCast(context));
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
    image.writeFloat4(
        .{
            .x = x,
            .y = y,
            .z = z,
        },
        .{
            .aspect_mask = image_view.interface.subresource_range.aspect_mask,
            .mip_level = image_view.interface.subresource_range.base_mip_level,
            .array_layer = image_view.interface.subresource_range.base_array_layer,
        },
        image_view.interface.format,
        .{ pixel.x, pixel.y, pixel.z, pixel.w },
    ) catch return SpvRuntimeError.Unknown;
}

fn writeImageInt4(context: *anyopaque, x: i32, y: i32, z: i32, pixel: spv.Runtime.Vec4(u32)) SpvRuntimeError!void {
    const image_view: *SoftImageView = @ptrCast(@alignCast(context));
    const image: *SoftImage = @alignCast(@fieldParentPtr("interface", image_view.interface.image));
    image.writeInt4(
        .{
            .x = x,
            .y = y,
            .z = z,
        },
        .{
            .aspect_mask = image_view.interface.subresource_range.aspect_mask,
            .mip_level = image_view.interface.subresource_range.base_mip_level,
            .array_layer = image_view.interface.subresource_range.base_array_layer,
        },
        image_view.interface.format,
        .{ pixel.x, pixel.y, pixel.z, pixel.w },
    ) catch return SpvRuntimeError.Unknown;
}
