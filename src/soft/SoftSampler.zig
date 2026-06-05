const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");
const zm = base.zm;

const VkError = base.VkError;
const Device = base.Device;
const F32x4 = zm.F32x4;

const SoftImage = @import("SoftImage.zig");
const SoftImageView = @import("SoftImageView.zig");

const Self = @This();
pub const Interface = base.Sampler;

const CubeCoordinate = struct {
    face: u32,
    u: f32,
    v: f32,
    w: f32 = 0.0,
};

const ImageSamplingContext = struct {
    image: *SoftImage,
    image_view: *SoftImageView,
    sampler: *Self,
    dim: spv.SpvDim,
    coord: CubeCoordinate,
};

interface: Interface,

pub fn create(device: *base.Device, allocator: std.mem.Allocator, info: *const vk.SamplerCreateInfo) VkError!*Self {
    const self = allocator.create(Self) catch return VkError.OutOfHostMemory;
    errdefer allocator.destroy(self);

    var interface = try Interface.init(device, allocator, info);

    interface.vtable = &.{
        .destroy = destroy,
    };

    self.* = .{
        .interface = interface,
    };
    return self;
}

pub fn destroy(interface: *Interface, allocator: std.mem.Allocator) void {
    const self: *Self = @alignCast(@fieldParentPtr("interface", interface));
    allocator.destroy(self);
}

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

inline fn sampleAddress(coord: i32, extent: u32, mode: vk.SamplerAddressMode) i32 {
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

fn samplerBorderColor(sampler: *Self) F32x4 {
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

fn sampleArrayLayer(coord: f32, layer_count: u32) u32 {
    const layer_coord: i32 = @intFromFloat(@floor(coord + 0.5));
    return @intCast(sampleAddress(layer_coord, layer_count, .clamp_to_edge));
}

fn readSampledFloat4(
    image: *SoftImage,
    image_view: *SoftImageView,
    sampler: *Self,
    dim: spv.SpvDim,
    coord: CubeCoordinate,
    ix: i32,
    iy: i32,
    iz: i32,
) VkError!F32x4 {
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
        .@"1d_array" => .{ 0, range.base_array_layer + sampleArrayLayer(coord.v, viewLayerCount(image, range)) },
        .@"2d_array" => .{ 0, range.base_array_layer + sampleArrayLayer(coord.w, viewLayerCount(image, range)) },
        .cube_array => .{ 0, range.base_array_layer + sampleArrayLayer(coord.w, @divTrunc(viewLayerCount(image, range), 6)) * 6 + texel.face },
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

    return image.readFloat4(
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
}

fn readSampledFloat4At(context: *const ImageSamplingContext, ix: i32, iy: i32, iz: i32) VkError!F32x4 {
    return readSampledFloat4(
        context.image,
        context.image_view,
        context.sampler,
        context.dim,
        context.coord,
        ix,
        iy,
        iz,
    );
}

pub fn sampleImageFloat4(image: *SoftImage, image_view: *SoftImageView, sampler: *Self, dim: spv.SpvDim, x: f32, y: f32, z: f32) VkError!F32x4 {
    const extent = image.getMipLevelExtent(image_view.interface.subresource_range.base_mip_level);
    const coord: CubeCoordinate = switch (image_view.interface.view_type) {
        .@"1d_array" => .{
            .u = x,
            .v = y,
            .face = 0,
        },
        .@"1d" => .{
            .u = x,
            .v = 0.0,
            .face = 0,
        },
        .@"2d_array" => .{
            .u = x,
            .v = y,
            .w = z,
            .face = 0,
        },
        .cube, .cube_array => resolveCubeCoordinate(x, y, z),
        else => .{
            .u = x,
            .v = y,
            .w = z,
            .face = 0,
        },
    };
    const context: ImageSamplingContext = .{
        .image = image,
        .image_view = image_view,
        .sampler = sampler,
        .dim = dim,
        .coord = coord,
    };

    return sampleFloat4(
        *const ImageSamplingContext,
        &context,
        zm.f32x4(
            coord.u * @as(f32, @floatFromInt(extent.width)),
            coord.v * @as(f32, @floatFromInt(extent.height)),
            coord.w * @as(f32, @floatFromInt(extent.depth)),
            0.0,
        ),
        switch (sampler.interface.mag_filter) {
            .linear => .linear,
            else => .nearest,
        },
        image_view.interface.view_type == .@"3d",
        readSampledFloat4At,
    );
}

pub fn sampleFloat4(
    comptime Context: type,
    context: Context,
    pos: F32x4,
    filter: vk.Filter,
    filter_3D: bool,
    comptime read: fn (Context, i32, i32, i32) VkError!F32x4,
) VkError!F32x4 {
    if (filter == .nearest) {
        return read(
            context,
            @intFromFloat(pos[0]),
            @intFromFloat(pos[1]),
            @intFromFloat(pos[2]),
        );
    }

    const x = pos[0] - 0.5;
    const y = pos[1] - 0.5;
    const z = pos[2] - 0.5;
    const x0: i32 = @intFromFloat(@floor(x));
    const y0: i32 = @intFromFloat(@floor(y));
    const z0: i32 = @intFromFloat(@floor(z));
    const x1 = x0 + 1;
    const y1 = y0 + 1;
    const z1 = z0 + 1;
    const wx = x - @as(f32, @floatFromInt(x0));
    const wy = y - @as(f32, @floatFromInt(y0));
    const wz = z - @as(f32, @floatFromInt(z0));

    const p000 = try read(context, x0, y0, z0);
    const p100 = try read(context, x1, y0, z0);
    const p010 = try read(context, x0, y1, z0);
    const p110 = try read(context, x1, y1, z0);

    const row00 = p000 * zm.f32x4s(1.0 - wx) + p100 * zm.f32x4s(wx);
    const row10 = p010 * zm.f32x4s(1.0 - wx) + p110 * zm.f32x4s(wx);
    const slice0 = row00 * zm.f32x4s(1.0 - wy) + row10 * zm.f32x4s(wy);

    if (!filter_3D)
        return slice0;

    const p001 = try read(context, x0, y0, z1);
    const p101 = try read(context, x1, y0, z1);
    const p011 = try read(context, x0, y1, z1);
    const p111 = try read(context, x1, y1, z1);

    const row01 = p001 * zm.f32x4s(1.0 - wx) + p101 * zm.f32x4s(wx);
    const row11 = p011 * zm.f32x4s(1.0 - wx) + p111 * zm.f32x4s(wx);
    const slice1 = row01 * zm.f32x4s(1.0 - wy) + row11 * zm.f32x4s(wy);

    return slice0 * zm.f32x4s(1.0 - wz) + slice1 * zm.f32x4s(wz);
}
