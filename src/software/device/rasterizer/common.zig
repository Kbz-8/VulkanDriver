const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;
const spv = @import("spv");

const blitter = @import("../blitter.zig");
const Renderer = @import("../Renderer.zig");

const VkError = base.VkError;
const F32x4 = zm.F32x4;
const U32x4 = @Vector(4, u32);

pub const RenderTargetAccess = struct {
    mutex: std.Io.Mutex,
    base: []u8,
    row_pitch: usize,
    texel_size: usize,
    sample_count: usize,
    sample_stride: usize,
    width: u32,
    height: u32,
    format: vk.Format,
};

pub const VertexInterpolation = struct {
    blob: []const u8,
    size: usize,
    free_responsability: bool,
};

pub const VertexInterpolationLocation = [4]VertexInterpolation;

pub fn depthBiasConstantUnit(format: vk.Format, z: f32) f32 {
    return switch (format) {
        .d16_unorm => 1.0 / @as(f32, @floatFromInt(std.math.maxInt(u16))),
        .x8_d24_unorm_pack32,
        .d24_unorm_s8_uint,
        => 1.0 / @as(f32, @floatFromInt(0x00ff_ffff)),
        .d32_sfloat,
        .d32_sfloat_s8_uint,
        => if (z > 0.0) std.math.pow(f32, 2.0, @floor(@log2(z)) - 23.0) else 0.0,
        else => 0.0,
    };
}

pub fn clampDepthBias(bias: f32, clamp: f32) f32 {
    if (clamp > 0.0)
        return @min(bias, clamp);
    if (clamp < 0.0)
        return @max(bias, clamp);
    return bias;
}

pub fn scissorContainsPixel(scissor: vk.Rect2D, x: i32, y: i32) bool {
    const min_x: i64 = @as(i64, scissor.offset.x);
    const min_y: i64 = @as(i64, scissor.offset.y);

    const max_x: i64 = min_x + @as(i64, @intCast(scissor.extent.width));
    const max_y: i64 = min_y + @as(i64, @intCast(scissor.extent.height));

    const pixel_x: i64 = @as(i64, x);
    const pixel_y: i64 = @as(i64, y);

    return pixel_x >= min_x and
        pixel_x < max_x and
        pixel_y >= min_y and
        pixel_y < max_y;
}

pub fn rectContainsPixel(rect: vk.Rect2D, x: usize, y: usize) bool {
    const min_x: i64 = @as(i64, rect.offset.x);
    const min_y: i64 = @as(i64, rect.offset.y);

    const max_x: i64 = min_x + @as(i64, @intCast(rect.extent.width));
    const max_y: i64 = min_y + @as(i64, @intCast(rect.extent.height));

    const pixel_x: i64 = @intCast(x);
    const pixel_y: i64 = @intCast(y);

    return pixel_x >= min_x and
        pixel_x < max_x and
        pixel_y >= min_y and
        pixel_y < max_y;
}

pub fn targetContainsPixel(target: RenderTargetAccess, x: i32, y: i32) bool {
    if (x < 0 or y < 0)
        return false;
    const pixel_x: u32 = @intCast(x);
    const pixel_y: u32 = @intCast(y);
    return pixel_x < target.width and pixel_y < target.height;
}

pub fn targetOffset(target: RenderTargetAccess, x: usize, y: usize) ?usize {
    if (x >= target.width or y >= target.height)
        return null;
    const offset = x * target.texel_size + y * target.row_pitch;
    if (offset > target.base.len or target.texel_size > target.base.len - offset)
        return null;
    return offset;
}

pub fn targetSampleOffset(target: RenderTargetAccess, x: usize, y: usize, sample_index: usize) ?usize {
    const base_offset = targetOffset(target, x, y) orelse return null;
    const offset = base_offset + sample_index * target.sample_stride;
    if (offset > target.base.len or target.texel_size > target.base.len - offset)
        return null;
    return offset;
}

pub fn compare(comptime T: type, op: vk.CompareOp, reference: T, value: T) bool {
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

fn applyStencilOp(op: vk.StencilOp, current: u32, reference: u32) u32 {
    return switch (op) {
        .keep => current,
        .zero => 0,
        .replace => reference,
        .increment_and_clamp => @min(current +| 1, std.math.maxInt(u8)),
        .decrement_and_clamp => if (current == 0) 0 else current - 1,
        .invert => ~current,
        .increment_and_wrap => current +% 1,
        .decrement_and_wrap => current -% 1,
        else => current,
    } & std.math.maxInt(u8);
}

fn updateStencilValue(stencil: *RenderTargetAccess, offset: usize, state: vk.StencilOpState, op: vk.StencilOp) void {
    const current = blitter.readInt4(stencil.base[offset..], stencil.format)[0] & std.math.maxInt(u8);
    const op_value = applyStencilOp(op, current, state.reference & std.math.maxInt(u8));
    const write_mask = state.write_mask & std.math.maxInt(u8);
    const new_value = (current & ~write_mask) | (op_value & write_mask);
    blitter.writeInt4(@splat(new_value), stencil.base[offset..], stencil.format);
}

pub fn stencilTestAndUpdate(stencil: *RenderTargetAccess, x: usize, y: usize, state: vk.StencilOpState, depth_passed: ?bool) bool {
    const offset = targetOffset(stencil.*, x, y) orelse return false;
    return stencilTestAndUpdateAtOffset(stencil, offset, state, depth_passed);
}

fn stencilTestAndUpdateAtOffset(stencil: *RenderTargetAccess, offset: usize, state: vk.StencilOpState, depth_passed: ?bool) bool {
    const current = blitter.readInt4(stencil.base[offset..], stencil.format)[0] & std.math.maxInt(u8);
    const reference = state.reference & std.math.maxInt(u8);
    const compare_mask = state.compare_mask & std.math.maxInt(u8);
    const stencil_passed = compare(u32, state.compare_op, reference & compare_mask, current & compare_mask);

    if (!stencil_passed) {
        updateStencilValue(stencil, offset, state, state.fail_op);
        return false;
    }

    if (depth_passed != null and !depth_passed.?) {
        updateStencilValue(stencil, offset, state, state.depth_fail_op);
        return false;
    }

    updateStencilValue(stencil, offset, state, state.pass_op);
    return true;
}

fn stencilTest(stencil: *RenderTargetAccess, offset: usize, state: vk.StencilOpState) bool {
    const current = blitter.readInt4(stencil.base[offset..], stencil.format)[0] & std.math.maxInt(u8);
    const reference = state.reference & std.math.maxInt(u8);
    const compare_mask = state.compare_mask & std.math.maxInt(u8);
    return compare(u32, state.compare_op, reference & compare_mask, current & compare_mask);
}

fn quantizeDepthForFormat(format: vk.Format, z: f32) f32 {
    const clamped = std.math.clamp(z, 0.0, 1.0);
    return switch (format) {
        .d16_unorm => @as(f32, @floatFromInt(@as(u16, @intFromFloat(@round(clamped * std.math.maxInt(u16)))))) / std.math.maxInt(u16),
        .x8_d24_unorm_pack32,
        .d24_unorm_s8_uint,
        => @as(f32, @floatFromInt(@as(u32, @intFromFloat(@round(clamped * @as(f32, @floatFromInt(0x00ff_ffff))))))) / @as(f32, @floatFromInt(0x00ff_ffff)),
        else => z,
    };
}

pub fn depthTestAndUpdate(depth: *RenderTargetAccess, x: usize, y: usize, z: f32, state: vk.PipelineDepthStencilStateCreateInfo) bool {
    const offset = targetOffset(depth.*, x, y) orelse return false;
    return depthTestAndUpdateAtOffset(depth, offset, z, state);
}

pub fn resolveDepthStencilState(draw_call: *Renderer.DrawCall, state: vk.PipelineDepthStencilStateCreateInfo) vk.PipelineDepthStencilStateCreateInfo {
    var resolved = state;
    const pipeline_data = draw_call.renderer.state.pipeline.?.interface.mode.graphics;
    if (pipeline_data.dynamic_state.depth_bounds) {
        const bounds = draw_call.renderer.dynamic_state.depth_bounds orelse Renderer.DepthBounds{
            .min = 0.0,
            .max = 1.0,
        };
        resolved.min_depth_bounds = bounds.min;
        resolved.max_depth_bounds = bounds.max;
    }
    return resolved;
}

pub fn depthTestSampleAndUpdate(
    io: std.Io,
    depth: *RenderTargetAccess,
    x: usize,
    y: usize,
    sample_index: usize,
    z: f32,
    state: ?vk.PipelineDepthStencilStateCreateInfo,
) VkError!bool {
    const depth_state = state orelse return true;
    const depth_offset = targetSampleOffset(depth.*, x, y, sample_index) orelse return false;

    depth.mutex.lock(io) catch return VkError.DeviceLost;
    defer depth.mutex.unlock(io);

    return depthTestAndUpdateAtOffset(depth, depth_offset, z, depth_state);
}

fn depthTestAndUpdateAtOffset(depth: *RenderTargetAccess, offset: usize, z: f32, state: vk.PipelineDepthStencilStateCreateInfo) bool {
    const reference = quantizeDepthForFormat(depth.format, z);
    if (state.depth_bounds_test_enable == .true and
        (reference < state.min_depth_bounds or reference > state.max_depth_bounds))
        return false;

    if (state.depth_test_enable == .false)
        return true;

    const depth_value = blitter.readFloat4(depth.base[offset..], depth.format);
    const passed = compare(f32, state.depth_compare_op, reference, depth_value[0]);
    if (passed and state.depth_write_enable == .true)
        blitter.writeFloat4(zm.f32x4s(reference), depth.base[offset..], depth.format);
    return passed;
}

fn resolveStencilState(draw_call: *Renderer.DrawCall, state: vk.StencilOpState, front: bool) vk.StencilOpState {
    var resolved = state;
    const dynamic = draw_call.renderer.dynamic_state;
    if ((if (front) dynamic.stencil_front_compare_mask else dynamic.stencil_back_compare_mask)) |mask|
        resolved.compare_mask = mask;
    if ((if (front) dynamic.stencil_front_write_mask else dynamic.stencil_back_write_mask)) |mask|
        resolved.write_mask = mask;
    if ((if (front) dynamic.stencil_front_reference else dynamic.stencil_back_reference)) |reference|
        resolved.reference = reference;
    return resolved;
}

pub fn interpolateVertexOutputs(
    allocator: std.mem.Allocator,
    v0: *const Renderer.Vertex,
    v1: *const Renderer.Vertex,
    v2: *const Renderer.Vertex,
    provoking_vertex: *const Renderer.Vertex,
    b0: f32,
    b1: f32,
    b2: f32,
    centroid_b0: f32,
    centroid_b1: f32,
    centroid_b2: f32,
) VkError![spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation {
    var inputs = [_]VertexInterpolationLocation{[_]VertexInterpolation{.{
        .blob = &.{},
        .size = 0,
        .free_responsability = false,
    }} ** 4} ** spv.SPIRV_MAX_OUTPUT_LOCATIONS;

    for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
        for (0..4) |component| {
            const out0 = v0.outputs[location][component] orelse continue;
            const out1 = v1.outputs[location][component] orelse continue;
            const out2 = v2.outputs[location][component] orelse continue;

            if (out0.interpolation_type == .flat or out0.size == 0) {
                const flat_out = provoking_vertex.outputs[location][component] orelse out0;
                inputs[location][component] = .{ .blob = flat_out.blob, .size = flat_out.size, .free_responsability = false };
                continue;
            }

            const len = @min(out0.size, out1.size, out2.size);
            if (std.mem.eql(u8, out0.blob[0..len], out1.blob[0..len]) and std.mem.eql(u8, out0.blob[0..len], out2.blob[0..len])) {
                inputs[location][component] = .{ .blob = out0.blob, .size = len, .free_responsability = false };
                continue;
            }

            const input = allocator.alloc(u8, len + @sizeOf(F32x4)) catch return VkError.OutOfDeviceMemory;
            @memset(input, 0);

            const input_b0 = if (out0.centroid) centroid_b0 else b0;
            const input_b1 = if (out0.centroid) centroid_b1 else b1;
            const input_b2 = if (out0.centroid) centroid_b2 else b2;

            var byte_index: usize = 0;
            while (byte_index + @sizeOf(F32x4) <= len) : (byte_index += @sizeOf(F32x4)) {
                const value0 = std.mem.bytesToValue(F32x4, out0.blob[byte_index..]);
                const value1 = std.mem.bytesToValue(F32x4, out1.blob[byte_index..]);
                const value2 = std.mem.bytesToValue(F32x4, out2.blob[byte_index..]);
                base.utils.writePacked(F32x4, input[byte_index..], interpolateF32x4(out0.interpolation_type, value0, value1, value2, v0, v1, v2, input_b0, input_b1, input_b2));
            }

            while (byte_index + @sizeOf(f32) <= len) : (byte_index += @sizeOf(f32)) {
                const value0 = std.mem.bytesToValue(f32, out0.blob[byte_index..]);
                const value1 = std.mem.bytesToValue(f32, out1.blob[byte_index..]);
                const value2 = std.mem.bytesToValue(f32, out2.blob[byte_index..]);
                base.utils.writePacked(f32, input[byte_index..], interpolateF32(out0.interpolation_type, value0, value1, value2, v0, v1, v2, input_b0, input_b1, input_b2));
            }

            if (byte_index < len)
                @memcpy(input[byte_index..len], out0.blob[byte_index..len]);

            inputs[location][component] = .{ .blob = input, .size = len, .free_responsability = true };
        }
    }

    return inputs;
}

pub fn interpolateLineOutputs(
    allocator: std.mem.Allocator,
    v0: *const Renderer.Vertex,
    v1: *const Renderer.Vertex,
    provoking_vertex: *const Renderer.Vertex,
    t: f32,
) VkError![spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation {
    return interpolateVertexOutputs(allocator, v0, v1, v0, provoking_vertex, 1.0 - t, t, 0.0, 1.0 - t, t, 0.0);
}

pub fn interpolateVertexOutputDerivatives(
    allocator: std.mem.Allocator,
    v0: *const Renderer.Vertex,
    v1: *const Renderer.Vertex,
    v2: *const Renderer.Vertex,
    b0: f32,
    b1: f32,
    b2: f32,
    db0: f32,
    db1: f32,
    db2: f32,
) VkError![spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation {
    var inputs = [_]VertexInterpolationLocation{[_]VertexInterpolation{.{
        .blob = &.{},
        .size = 0,
        .free_responsability = false,
    }} ** 4} ** spv.SPIRV_MAX_OUTPUT_LOCATIONS;

    for (0..spv.SPIRV_MAX_OUTPUT_LOCATIONS) |location| {
        for (0..4) |component| {
            const out0 = v0.outputs[location][component] orelse continue;
            const out1 = v1.outputs[location][component] orelse continue;
            const out2 = v2.outputs[location][component] orelse continue;

            const len = @min(out0.size, out1.size, out2.size);
            if (len == 0)
                continue;

            const input = allocator.alloc(u8, len + @sizeOf(F32x4)) catch return VkError.OutOfDeviceMemory;
            @memset(input, 0);

            if (out0.interpolation_type != .flat) {
                var byte_index: usize = 0;
                while (byte_index + @sizeOf(F32x4) <= len) : (byte_index += @sizeOf(F32x4)) {
                    const value0 = std.mem.bytesToValue(F32x4, out0.blob[byte_index..]);
                    const value1 = std.mem.bytesToValue(F32x4, out1.blob[byte_index..]);
                    const value2 = std.mem.bytesToValue(F32x4, out2.blob[byte_index..]);
                    base.utils.writePacked(F32x4, input[byte_index..], interpolateDerivativeF32x4(out0.interpolation_type, value0, value1, value2, v0, v1, v2, b0, b1, b2, db0, db1, db2));
                }

                while (byte_index + @sizeOf(f32) <= len) : (byte_index += @sizeOf(f32)) {
                    const value0 = std.mem.bytesToValue(f32, out0.blob[byte_index..]);
                    const value1 = std.mem.bytesToValue(f32, out1.blob[byte_index..]);
                    const value2 = std.mem.bytesToValue(f32, out2.blob[byte_index..]);
                    base.utils.writePacked(f32, input[byte_index..], interpolateDerivativeF32(out0.interpolation_type, value0, value1, value2, v0, v1, v2, b0, b1, b2, db0, db1, db2));
                }
            }

            inputs[location][component] = .{ .blob = input, .size = len, .free_responsability = true };
        }
    }

    return inputs;
}

fn perspectiveWeights(v0: *const Renderer.Vertex, v1: *const Renderer.Vertex, v2: *const Renderer.Vertex, b0: f32, b1: f32, b2: f32) struct { w0: f32, w1: f32, w2: f32 } {
    const iw0 = 1.0 / v0.position[3];
    const iw1 = 1.0 / v1.position[3];
    const iw2 = 1.0 / v2.position[3];
    const denominator = (b0 * iw0) + (b1 * iw1) + (b2 * iw2);
    if (denominator == 0.0)
        return .{ .w0 = b0, .w1 = b1, .w2 = b2 };
    return .{
        .w0 = (b0 * iw0) / denominator,
        .w1 = (b1 * iw1) / denominator,
        .w2 = (b2 * iw2) / denominator,
    };
}

inline fn interpolateF32(interpolation_type: anytype, value0: f32, value1: f32, value2: f32, v0: *const Renderer.Vertex, v1: *const Renderer.Vertex, v2: *const Renderer.Vertex, b0: f32, b1: f32, b2: f32) f32 {
    if (interpolation_type == .smooth) {
        const weights = perspectiveWeights(v0, v1, v2, b0, b1, b2);
        return (value0 * weights.w0) + (value1 * weights.w1) + (value2 * weights.w2);
    }
    return (value0 * b0) + (value1 * b1) + (value2 * b2);
}

inline fn interpolateF32x4(interpolation_type: anytype, value0: F32x4, value1: F32x4, value2: F32x4, v0: *const Renderer.Vertex, v1: *const Renderer.Vertex, v2: *const Renderer.Vertex, b0: f32, b1: f32, b2: f32) F32x4 {
    if (interpolation_type == .smooth) {
        const weights = perspectiveWeights(v0, v1, v2, b0, b1, b2);
        return (value0 * zm.f32x4s(weights.w0)) + (value1 * zm.f32x4s(weights.w1)) + (value2 * zm.f32x4s(weights.w2));
    }
    return (value0 * zm.f32x4s(b0)) + (value1 * zm.f32x4s(b1)) + (value2 * zm.f32x4s(b2));
}

inline fn interpolateDerivativeF32(interpolation_type: anytype, value0: f32, value1: f32, value2: f32, v0: *const Renderer.Vertex, v1: *const Renderer.Vertex, v2: *const Renderer.Vertex, b0: f32, b1: f32, b2: f32, db0: f32, db1: f32, db2: f32) f32 {
    if (interpolation_type != .smooth)
        return (value0 * db0) + (value1 * db1) + (value2 * db2);

    const iw0 = 1.0 / v0.position[3];
    const iw1 = 1.0 / v1.position[3];
    const iw2 = 1.0 / v2.position[3];
    const n = (value0 * b0 * iw0) + (value1 * b1 * iw1) + (value2 * b2 * iw2);
    const d = (b0 * iw0) + (b1 * iw1) + (b2 * iw2);
    const dn = (value0 * db0 * iw0) + (value1 * db1 * iw1) + (value2 * db2 * iw2);
    const dd = (db0 * iw0) + (db1 * iw1) + (db2 * iw2);
    if (d == 0.0)
        return 0.0;
    return ((dn * d) - (n * dd)) / (d * d);
}

inline fn interpolateDerivativeF32x4(interpolation_type: anytype, value0: F32x4, value1: F32x4, value2: F32x4, v0: *const Renderer.Vertex, v1: *const Renderer.Vertex, v2: *const Renderer.Vertex, b0: f32, b1: f32, b2: f32, db0: f32, db1: f32, db2: f32) F32x4 {
    if (interpolation_type != .smooth)
        return (value0 * zm.f32x4s(db0)) + (value1 * zm.f32x4s(db1)) + (value2 * zm.f32x4s(db2));

    const iw0 = 1.0 / v0.position[3];
    const iw1 = 1.0 / v1.position[3];
    const iw2 = 1.0 / v2.position[3];
    const n = (value0 * zm.f32x4s(b0 * iw0)) + (value1 * zm.f32x4s(b1 * iw1)) + (value2 * zm.f32x4s(b2 * iw2));
    const d = (b0 * iw0) + (b1 * iw1) + (b2 * iw2);
    const dn = (value0 * zm.f32x4s(db0 * iw0)) + (value1 * zm.f32x4s(db1 * iw1)) + (value2 * zm.f32x4s(db2 * iw2));
    const dd = (db0 * iw0) + (db1 * iw1) + (db2 * iw2);
    if (d == 0.0)
        return zm.f32x4s(0.0);
    return ((dn * zm.f32x4s(d)) - (n * zm.f32x4s(dd))) / zm.f32x4s(d * d);
}

inline fn fragmentOutputFloat4(output: [@sizeOf(F32x4)]u8, format: vk.Format) F32x4 {
    const color = std.mem.bytesToValue(F32x4, &output);
    _ = format;
    return color;
}

inline fn blendFactor(factor: vk.BlendFactor, src: F32x4, dst: F32x4, constant: F32x4) F32x4 {
    return switch (factor) {
        .zero => zm.f32x4s(0.0),
        .one => zm.f32x4s(1.0),
        .src_color => src,
        .one_minus_src_color => zm.f32x4s(1.0) - src,
        .dst_color => dst,
        .one_minus_dst_color => zm.f32x4s(1.0) - dst,
        .src_alpha => zm.f32x4s(src[3]),
        .one_minus_src_alpha => zm.f32x4s(1.0 - src[3]),
        .dst_alpha => zm.f32x4s(dst[3]),
        .one_minus_dst_alpha => zm.f32x4s(1.0 - dst[3]),
        .constant_color => constant,
        .one_minus_constant_color => zm.f32x4s(1.0) - constant,
        .constant_alpha => zm.f32x4s(constant[3]),
        .one_minus_constant_alpha => zm.f32x4s(1.0 - constant[3]),
        .src_alpha_saturate => .{ @min(src[3], 1.0 - dst[3]), @min(src[3], 1.0 - dst[3]), @min(src[3], 1.0 - dst[3]), 1.0 },
        else => zm.f32x4s(0.0),
    };
}

inline fn blendOp(op: vk.BlendOp, src: F32x4, dst: F32x4) F32x4 {
    return switch (op) {
        .add => src + dst,
        .subtract => src - dst,
        .reverse_subtract => dst - src,
        .min => @min(src, dst),
        .max => @max(src, dst),
        else => src,
    };
}

inline fn blendColor(src: F32x4, dst: F32x4, state: vk.PipelineColorBlendAttachmentState, constants: [4]f32, format: vk.Format) F32x4 {
    if (state.blend_enable == .false)
        return src;

    const min_value = zm.f32x4s(base.format.minElementValue(format));
    const max_value = zm.f32x4s(base.format.maxElementValue(format));
    const clamped_src = if (base.format.isFloat(format)) src else std.math.clamp(src, min_value, max_value);
    const constant = if (base.format.isFloat(format))
        F32x4{ constants[0], constants[1], constants[2], constants[3] }
    else
        std.math.clamp(F32x4{ constants[0], constants[1], constants[2], constants[3] }, min_value, max_value);

    const color_src = if (state.color_blend_op == .min or state.color_blend_op == .max)
        clamped_src
    else
        clamped_src * blendFactor(state.src_color_blend_factor, clamped_src, dst, constant);
    const color_dst = if (state.color_blend_op == .min or state.color_blend_op == .max)
        dst
    else
        dst * blendFactor(state.dst_color_blend_factor, clamped_src, dst, constant);
    const alpha_src = if (state.alpha_blend_op == .min or state.alpha_blend_op == .max)
        clamped_src
    else
        clamped_src * blendFactor(state.src_alpha_blend_factor, clamped_src, dst, constant);
    const alpha_dst = if (state.alpha_blend_op == .min or state.alpha_blend_op == .max)
        dst
    else
        dst * blendFactor(state.dst_alpha_blend_factor, clamped_src, dst, constant);

    var blended = blendOp(state.color_blend_op, color_src, color_dst);
    blended[3] = blendOp(state.alpha_blend_op, alpha_src, alpha_dst)[3];
    return blended;
}

inline fn applyColorWriteMask(blended: F32x4, dst: F32x4, mask: vk.ColorComponentFlags) F32x4 {
    return .{
        if (mask.r_bit) blended[0] else dst[0],
        if (mask.g_bit) blended[1] else dst[1],
        if (mask.b_bit) blended[2] else dst[2],
        if (mask.a_bit) blended[3] else dst[3],
    };
}

pub fn writeToTargets(
    outputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(F32x4)]u8,
    draw_call: *Renderer.DrawCall,
    color_attachment_access: []const ?RenderTargetAccess,
    depth_attachment_access: ?*RenderTargetAccess,
    stencil_attachment_access: ?*RenderTargetAccess,
    front_face: bool,
    x: usize,
    y: usize,
    z: f32,
    coverage_sample_mask: ?vk.SampleMask,
    fragment_sample_mask: ?vk.SampleMask,
    depth_already_applied: bool,
) VkError!void {
    const io = draw_call.renderer.device.interface.io();
    const pipeline_data = draw_call.renderer.state.pipeline.?.interface.mode.graphics;
    const depth_stencil_state = if (pipeline_data.depth_stencil) |state| resolveDepthStencilState(draw_call, state) else null;
    const effective_fragment_sample_mask = alphaToCoverageMask(
        pipeline_data.multisample,
        outputs,
        fragment_sample_mask,
    );

    if (!sampleMaskEnablesAnySample(pipeline_data.multisample, coverage_sample_mask, effective_fragment_sample_mask))
        return;

    if (x >= draw_call.framebuffer.interface.width or y >= draw_call.framebuffer.interface.height)
        return;

    if (draw_call.renderer.render_area) |render_area| {
        if (!rectContainsPixel(render_area, x, y))
            return;
    }

    const sample_count = pipeline_data.multisample.rasterization_samples.toInt();
    for (0..sample_count) |sample_index| {
        if (!sampleMaskEnablesSample(pipeline_data.multisample, coverage_sample_mask, effective_fragment_sample_mask, sample_index))
            continue;

        var stencil_state: ?vk.StencilOpState = null;
        var stencil_offset: ?usize = null;
        if (stencil_attachment_access) |stencil| {
            if (depth_stencil_state) |state| {
                if (state.stencil_test_enable == .true) {
                    stencil_state = if (front_face)
                        resolveStencilState(draw_call, state.front, true)
                    else
                        resolveStencilState(draw_call, state.back, false);
                    stencil_offset = targetSampleOffset(stencil.*, x, y, sample_index) orelse continue;
                    if (!stencilTest(stencil, stencil_offset.?, stencil_state.?)) {
                        updateStencilValue(stencil, stencil_offset.?, stencil_state.?, stencil_state.?.fail_op);
                        continue;
                    }
                }
            }
        }

        // After work depth test to avoid overwritten depth pixels during fragment invocations.
        var depth_passed: ?bool = null;
        if (!depth_already_applied and depth_attachment_access != null and depth_stencil_state != null) {
            const depth = depth_attachment_access.?;
            const depth_offset = targetSampleOffset(depth.*, x, y, sample_index) orelse continue;

            depth.mutex.lock(io) catch return VkError.DeviceLost;
            defer depth.mutex.unlock(io);

            depth_passed = depthTestAndUpdateAtOffset(depth, depth_offset, z, depth_stencil_state.?);
            if (!depth_passed.? and stencil_state == null)
                continue;
        }

        if (stencil_attachment_access) |stencil| {
            if (stencil_state) |state| {
                if (depth_passed != null and !depth_passed.?) {
                    updateStencilValue(stencil, stencil_offset.?, state, state.depth_fail_op);
                    continue;
                }
                updateStencilValue(stencil, stencil_offset.?, state, state.pass_op);
            }
        }

        for (draw_call.renderer.active_occlusion_queries.items) |active| {
            try active.pool.addSamples(active.query, 1);
        }

        for (color_attachment_access, 0..) |maybe_color, location| {
            const color = maybe_color orelse continue;
            const color_offset = targetSampleOffset(color, x, y, sample_index) orelse continue;
            if (base.format.isUnnormalizedInteger(color.format)) {
                const value = std.mem.bytesToValue(U32x4, &outputs[location]);
                blitter.writeInt4(value, color.base[color_offset..], color.format);
            } else {
                const src = fragmentOutputFloat4(outputs[location], color.format);
                const encoded_dst = blitter.readFloat4(color.base[color_offset..], color.format);
                const dst = if (base.format.isSrgb(color.format)) zm.srgbToRgb(encoded_dst) else encoded_dst;
                const final_color = if (pipeline_data.color_blend.attachments) |attachments| blk: {
                    if (location >= attachments.len)
                        break :blk src;
                    const constants = draw_call.renderer.dynamic_state.blend_constants orelse pipeline_data.color_blend.constants;
                    const blended = blendColor(src, dst, attachments[location], constants, color.format);
                    break :blk applyColorWriteMask(blended, dst, attachments[location].color_write_mask);
                } else src;
                const encoded_color = if (base.format.isSrgb(color.format)) zm.rgbToSrgb(final_color) else final_color;
                blitter.writeFloat4(encoded_color, color.base[color_offset..], color.format);
            }
        }
    }
}

fn alphaToCoverageMask(
    multisample: anytype,
    outputs: [spv.SPIRV_MAX_OUTPUT_LOCATIONS][@sizeOf(F32x4)]u8,
    fragment_sample_mask: ?vk.SampleMask,
) ?vk.SampleMask {
    if (multisample.alpha_to_coverage_enable == .false)
        return fragment_sample_mask;

    const sample_count = multisample.rasterization_samples.toInt();
    if (sample_count <= 1)
        return fragment_sample_mask;

    const color = std.mem.bytesToValue(F32x4, &outputs[0]);
    const alpha = std.math.clamp(color[3], 0.0, 1.0);
    const covered_samples: usize = @intFromFloat(@round(alpha * @as(f32, @floatFromInt(sample_count))));

    var alpha_mask: vk.SampleMask = 0;
    for (0..covered_samples) |sample_index| {
        if (sample_index >= @bitSizeOf(vk.SampleMask))
            break;

        const bit_index: u5 = @intCast(sample_index);
        alpha_mask |= @as(vk.SampleMask, 1) << bit_index;
    }

    return if (fragment_sample_mask) |mask| mask & alpha_mask else alpha_mask;
}

fn sampleMaskEnablesAnySample(multisample: anytype, coverage_sample_mask: ?vk.SampleMask, fragment_sample_mask: ?vk.SampleMask) bool {
    const sample_count = multisample.rasterization_samples.toInt();
    if (multisample.sample_mask == null and coverage_sample_mask == null and fragment_sample_mask == null)
        return true;

    if (multisample.sample_mask) |pipeline_sample_mask| {
        for (pipeline_sample_mask, 0..) |word, word_index| {
            if (sampleMaskWordEnablesAnySample(sample_count, word_index, word, coverage_sample_mask, fragment_sample_mask))
                return true;
        }
        return false;
    }

    return sampleMaskWordEnablesAnySample(sample_count, 0, std.math.maxInt(vk.SampleMask), coverage_sample_mask, fragment_sample_mask);
}

fn sampleMaskWordEnablesAnySample(sample_count: usize, word_index: usize, pipeline_word: vk.SampleMask, coverage_sample_mask: ?vk.SampleMask, fragment_sample_mask: ?vk.SampleMask) bool {
    const remaining_samples = sample_count -| (word_index * 32);
    const active_bits = @min(remaining_samples, 32);
    if (active_bits == 0)
        return false;

    const active_mask: vk.SampleMask = if (active_bits == 32)
        std.math.maxInt(vk.SampleMask)
    else
        (@as(vk.SampleMask, 1) << @intCast(active_bits)) - 1;

    const coverage_word = if (word_index == 0) coverage_sample_mask orelse std.math.maxInt(vk.SampleMask) else std.math.maxInt(vk.SampleMask);
    const fragment_word = if (word_index == 0) fragment_sample_mask orelse std.math.maxInt(vk.SampleMask) else std.math.maxInt(vk.SampleMask);
    return ((pipeline_word & coverage_word & fragment_word) & active_mask) != 0;
}

fn sampleMaskEnablesSample(multisample: anytype, coverage_sample_mask: ?vk.SampleMask, fragment_sample_mask: ?vk.SampleMask, sample_index: usize) bool {
    if (sample_index >= multisample.rasterization_samples.toInt())
        return false;

    const word_index = sample_index / 32;
    const bit_index: u5 = @intCast(sample_index % 32);
    const bit = @as(vk.SampleMask, 1) << bit_index;

    const pipeline_word = if (multisample.sample_mask) |pipeline_sample_mask|
        if (word_index < pipeline_sample_mask.len) pipeline_sample_mask[word_index] else @as(vk.SampleMask, 0)
    else
        std.math.maxInt(vk.SampleMask);

    const coverage_word = if (word_index == 0) coverage_sample_mask orelse std.math.maxInt(vk.SampleMask) else std.math.maxInt(vk.SampleMask);
    const fragment_word = if (word_index == 0) fragment_sample_mask orelse std.math.maxInt(vk.SampleMask) else std.math.maxInt(vk.SampleMask);
    return (pipeline_word & coverage_word & fragment_word & bit) != 0;
}
