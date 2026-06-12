const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const spv = @import("spv");
const zm = base.zm;
const blitter = @import("device/blitter.zig");

const VkError = base.VkError;
const Device = base.Device;
const F32x4 = zm.F32x4;
const U32x4 = blitter.U32x4;

const SoftImage = @import("SoftImage.zig");
const SoftImageView = @import("SoftImageView.zig");

const Self = @This();
pub const Interface = base.Sampler;
pub const ImageOffset = spv.Runtime.ImageOffset;

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
    mip_level: u32,
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

fn samplerBorderColor(sampler: *Self, format: vk.Format) F32x4 {
    var color: F32x4 = switch (sampler.interface.border_color) {
        .float_opaque_white, .int_opaque_white => .{ 1.0, 1.0, 1.0, 1.0 },
        .float_opaque_black, .int_opaque_black => .{ 0.0, 0.0, 0.0, 1.0 },
        else => .{ 0.0, 0.0, 0.0, 0.0 },
    };

    switch (base.format.componentCount(format)) {
        1 => {
            color[1] = 0.0;
            color[2] = 0.0;
            color[3] = 1.0;
        },
        2 => {
            color[2] = 0.0;
            color[3] = 1.0;
        },
        3 => color[3] = 1.0,
        else => {},
    }

    return color;
}

fn samplerBorderColorInt(sampler: *Self, format: vk.Format) U32x4 {
    var color: U32x4 = switch (sampler.interface.border_color) {
        .float_opaque_white, .int_opaque_white => .{ 1, 1, 1, 1 },
        .float_opaque_black, .int_opaque_black => .{ 0, 0, 0, 1 },
        else => .{ 0, 0, 0, 0 },
    };

    switch (base.format.componentCount(format)) {
        1 => {
            color[1] = 0;
            color[2] = 0;
            color[3] = 1;
        },
        2 => {
            color[2] = 0;
            color[3] = 1;
        },
        3 => color[3] = 1,
        else => {},
    }

    return color;
}

fn viewLayerCount(image: *SoftImage, range: vk.ImageSubresourceRange) u32 {
    return if (range.layer_count == vk.REMAINING_ARRAY_LAYERS)
        image.interface.array_layers - range.base_array_layer
    else
        range.layer_count;
}

fn viewMipCount(image: *SoftImage, range: vk.ImageSubresourceRange) u32 {
    return if (range.level_count == vk.REMAINING_MIP_LEVELS)
        image.interface.mip_levels - range.base_mip_level
    else
        range.level_count;
}

fn sampleMipLevel(image: *SoftImage, image_view: *SoftImageView, sampler: *Self, lod: ?f32) u32 {
    const range = image_view.interface.subresource_range;
    const mip_count = viewMipCount(image, range);
    if (mip_count <= 1)
        return range.base_mip_level;

    const requested_lod = if (lod) |explicit_lod|
        explicit_lod + sampler.interface.mip_lod_bias
    else
        sampler.interface.min_lod;
    const clamped_lod = std.math.clamp(requested_lod, sampler.interface.min_lod, sampler.interface.max_lod);
    const level_float = switch (sampler.interface.mipmap_mode) {
        .nearest => @round(clamped_lod),
        else => @floor(clamped_lod),
    };
    const level: u32 = @intFromFloat(std.math.clamp(level_float, 0.0, @as(f32, @floatFromInt(mip_count - 1))));
    return range.base_mip_level + level;
}

fn sampleArrayLayer(coord: f32, layer_count: u32) u32 {
    const layer_coord: i32 = @intFromFloat(@floor(coord + 0.5));
    return @intCast(sampleAddress(layer_coord, layer_count, .clamp_to_edge));
}

fn sampledFormat(image_view: *SoftImageView) vk.Format {
    const range = image_view.interface.subresource_range;
    return base.format.fromAspect(image_view.interface.format, range.aspect_mask);
}

fn swizzleFloatComponent(color: F32x4, swizzle: vk.ComponentSwizzle, comptime identity_index: usize) f32 {
    return switch (swizzle) {
        .identity => color[identity_index],
        .zero => 0.0,
        .one => 1.0,
        .r => color[0],
        .g => color[1],
        .b => color[2],
        .a => color[3],
        else => color[identity_index],
    };
}

fn swizzleFloat4(color: F32x4, components: vk.ComponentMapping) F32x4 {
    return .{
        swizzleFloatComponent(color, components.r, 0),
        swizzleFloatComponent(color, components.g, 1),
        swizzleFloatComponent(color, components.b, 2),
        swizzleFloatComponent(color, components.a, 3),
    };
}

fn swizzleIntComponent(color: U32x4, swizzle: vk.ComponentSwizzle, comptime identity_index: usize) u32 {
    return switch (swizzle) {
        .identity => color[identity_index],
        .zero => 0,
        .one => 1,
        .r => color[0],
        .g => color[1],
        .b => color[2],
        .a => color[3],
        else => color[identity_index],
    };
}

fn swizzleInt4(color: U32x4, components: vk.ComponentMapping) U32x4 {
    return .{
        swizzleIntComponent(color, components.r, 0),
        swizzleIntComponent(color, components.g, 1),
        swizzleIntComponent(color, components.b, 2),
        swizzleIntComponent(color, components.a, 3),
    };
}

fn compareDepth(op: vk.CompareOp, reference: f32, value: f32) bool {
    return switch (op) {
        .never => false,
        .less => reference < value,
        .equal => reference == value,
        .less_or_equal => reference <= value,
        .greater => reference > value,
        .not_equal => reference != value,
        .greater_or_equal => reference >= value,
        .always => true,
        else => false,
    };
}

fn readSampledFloat4(
    image: *SoftImage,
    image_view: *SoftImageView,
    sampler: *Self,
    dim: spv.SpvDim,
    coord: CubeCoordinate,
    mip_level: u32,
    ix: i32,
    iy: i32,
    iz: i32,
) VkError!F32x4 {
    const range = image_view.interface.subresource_range;
    const format = sampledFormat(image_view);
    const extent = image.getMipLevelExtent(mip_level);
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
        .@"3d" => .{ sampleAddressOrBorder(iz, extent.depth, sampler.interface.address_mode_w) orelse return samplerBorderColor(sampler, format), range.base_array_layer },
        .cube => .{ 0, range.base_array_layer + texel.face },
        else => .{ 0, range.base_array_layer },
    };

    const sx = if (dim == .Cube)
        std.math.clamp(@as(i32, @intFromFloat(texel.u * width_f)), 0, @as(i32, @intCast(extent.width)) - 1)
    else
        sampleAddressOrBorder(ix, extent.width, sampler.interface.address_mode_u) orelse return samplerBorderColor(sampler, format);
    const sy = if (dim == .Cube)
        std.math.clamp(@as(i32, @intFromFloat(texel.v * height_f)), 0, @as(i32, @intCast(extent.height)) - 1)
    else
        sampleAddressOrBorder(iy, extent.height, sampler.interface.address_mode_v) orelse return samplerBorderColor(sampler, format);

    const color = try image.readFloat4(
        .{
            .x = sx,
            .y = sy,
            .z = z,
        },
        .{
            .aspect_mask = range.aspect_mask,
            .mip_level = mip_level,
            .array_layer = layer,
        },
        format,
    );
    return if (base.format.isSrgb(format)) zm.srgbToRgb(color) else color;
}

fn readSampledFloat4At(context: *const ImageSamplingContext, ix: i32, iy: i32, iz: i32) VkError!F32x4 {
    const color = try readSampledFloat4(
        context.image,
        context.image_view,
        context.sampler,
        context.dim,
        context.coord,
        context.mip_level,
        ix,
        iy,
        iz,
    );
    return swizzleFloat4(color, context.image_view.interface.components);
}

fn readSampledInt4(
    image: *SoftImage,
    image_view: *SoftImageView,
    sampler: *Self,
    dim: spv.SpvDim,
    coord: CubeCoordinate,
    mip_level: u32,
    ix: i32,
    iy: i32,
    iz: i32,
) VkError!U32x4 {
    const range = image_view.interface.subresource_range;
    const format = sampledFormat(image_view);
    const extent = image.getMipLevelExtent(mip_level);
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
        .@"3d" => .{ sampleAddressOrBorder(iz, extent.depth, sampler.interface.address_mode_w) orelse return samplerBorderColorInt(sampler, format), range.base_array_layer },
        .cube => .{ 0, range.base_array_layer + texel.face },
        else => .{ 0, range.base_array_layer },
    };

    const sx = if (dim == .Cube)
        std.math.clamp(@as(i32, @intFromFloat(texel.u * width_f)), 0, @as(i32, @intCast(extent.width)) - 1)
    else
        sampleAddressOrBorder(ix, extent.width, sampler.interface.address_mode_u) orelse return samplerBorderColorInt(sampler, format);
    const sy = if (dim == .Cube)
        std.math.clamp(@as(i32, @intFromFloat(texel.v * height_f)), 0, @as(i32, @intCast(extent.height)) - 1)
    else
        sampleAddressOrBorder(iy, extent.height, sampler.interface.address_mode_v) orelse return samplerBorderColorInt(sampler, format);

    return image.readInt4(
        .{
            .x = sx,
            .y = sy,
            .z = z,
        },
        .{
            .aspect_mask = range.aspect_mask,
            .mip_level = mip_level,
            .array_layer = layer,
        },
        format,
    );
}

pub fn sampleImageFloat4(image: *SoftImage, image_view: *SoftImageView, sampler: *Self, dim: spv.SpvDim, x: f32, y: f32, z: f32, lod: ?f32, offset: ImageOffset) VkError!F32x4 {
    const mip_level = sampleMipLevel(image, image_view, sampler, lod);
    const extent = image.getMipLevelExtent(mip_level);
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
    const scale_u: f32 = if (sampler.interface.unnormalized_coordinates == .true) 1.0 else @floatFromInt(extent.width);
    const scale_v: f32 = if (sampler.interface.unnormalized_coordinates == .true) 1.0 else @floatFromInt(extent.height);
    const scale_w: f32 = if (sampler.interface.unnormalized_coordinates == .true) 1.0 else @floatFromInt(extent.depth);
    const context: ImageSamplingContext = .{
        .image = image,
        .image_view = image_view,
        .sampler = sampler,
        .dim = dim,
        .coord = coord,
        .mip_level = mip_level,
    };

    return sampleFloat4(
        *const ImageSamplingContext,
        &context,
        zm.f32x4(
            coord.u * scale_u + @as(f32, @floatFromInt(offset.x)),
            coord.v * scale_v + @as(f32, @floatFromInt(offset.y)),
            coord.w * scale_w + @as(f32, @floatFromInt(offset.z)),
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

pub fn sampleImageInt4(image: *SoftImage, image_view: *SoftImageView, sampler: *Self, dim: spv.SpvDim, x: f32, y: f32, z: f32, lod: ?f32, offset: ImageOffset) VkError!U32x4 {
    const mip_level = sampleMipLevel(image, image_view, sampler, lod);
    const extent = image.getMipLevelExtent(mip_level);
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
    const scale_u: f32 = if (sampler.interface.unnormalized_coordinates == .true) 1.0 else @floatFromInt(extent.width);
    const scale_v: f32 = if (sampler.interface.unnormalized_coordinates == .true) 1.0 else @floatFromInt(extent.height);
    const scale_w: f32 = if (sampler.interface.unnormalized_coordinates == .true) 1.0 else @floatFromInt(extent.depth);

    const color = try readSampledInt4(
        image,
        image_view,
        sampler,
        dim,
        coord,
        mip_level,
        @as(i32, @intFromFloat(@floor(coord.u * scale_u))) + offset.x,
        @as(i32, @intFromFloat(@floor(coord.v * scale_v))) + offset.y,
        @as(i32, @intFromFloat(@floor(coord.w * scale_w))) + offset.z,
    );
    return swizzleInt4(color, image_view.interface.components);
}

pub fn sampleImageDref(image: *SoftImage, image_view: *SoftImageView, sampler: *Self, dim: spv.SpvDim, x: f32, y: f32, z: f32, dref: f32, lod: ?f32, offset: ImageOffset) VkError!f32 {
    const color = try sampleImageFloat4(image, image_view, sampler, dim, x, y, z, lod, offset);
    if (sampler.interface.compare_enable == .false)
        return color[0];
    return if (compareDepth(sampler.interface.compare_op, dref, color[0])) 1.0 else 0.0;
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
            @intFromFloat(@floor(pos[0])),
            @intFromFloat(@floor(pos[1])),
            @intFromFloat(@floor(pos[2])),
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
