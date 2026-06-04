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

pub fn stencilTestAndUpdate(
    stencil: *RenderTargetAccess,
    x: usize,
    y: usize,
    state: vk.StencilOpState,
    depth_passed: ?bool,
) bool {
    const offset = targetOffset(stencil.*, x, y) orelse return false;
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

pub fn depthTestAndUpdate(depth: *RenderTargetAccess, x: usize, y: usize, z: f32, state: vk.PipelineDepthStencilStateCreateInfo) bool {
    if (state.depth_test_enable == .false)
        return true;

    const offset = targetOffset(depth.*, x, y) orelse return false;
    const depth_value = blitter.readFloat4(depth.base[offset..], depth.format);
    const passed = compare(f32, state.depth_compare_op, z, depth_value[0]);
    if (passed and state.depth_write_enable == .true)
        blitter.writeFloat4(zm.f32x4s(z), depth.base[offset..], depth.format);
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
    b0: f32,
    b1: f32,
    b2: f32,
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
                inputs[location][component] = .{ .blob = out0.blob, .size = out0.size, .free_responsability = false };
                continue;
            }

            const len = @min(out0.size, out1.size, out2.size);
            const input = allocator.alloc(u8, len + @sizeOf(F32x4)) catch return VkError.OutOfDeviceMemory;
            @memset(input, 0);

            var byte_index: usize = 0;
            while (byte_index + @sizeOf(F32x4) <= len) : (byte_index += @sizeOf(F32x4)) {
                const value0 = std.mem.bytesToValue(F32x4, out0.blob[byte_index..]);
                const value1 = std.mem.bytesToValue(F32x4, out1.blob[byte_index..]);
                const value2 = std.mem.bytesToValue(F32x4, out2.blob[byte_index..]);
                base.utils.writePacked(F32x4, input[byte_index..], interpolateF32x4(value0, value1, value2, b0, b1, b2));
            }

            while (byte_index + @sizeOf(f32) <= len) : (byte_index += @sizeOf(f32)) {
                const value0 = std.mem.bytesToValue(f32, out0.blob[byte_index..]);
                const value1 = std.mem.bytesToValue(f32, out1.blob[byte_index..]);
                const value2 = std.mem.bytesToValue(f32, out2.blob[byte_index..]);
                base.utils.writePacked(f32, input[byte_index..], (value0 * b0) + (value1 * b1) + (value2 * b2));
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
    t: f32,
) VkError![spv.SPIRV_MAX_OUTPUT_LOCATIONS]VertexInterpolationLocation {
    return interpolateVertexOutputs(allocator, v0, v1, v0, 1.0 - t, t, 0.0);
}

inline fn interpolateF32x4(value0: F32x4, value1: F32x4, value2: F32x4, b0: f32, b1: f32, b2: f32) F32x4 {
    return (value0 * zm.f32x4s(b0)) + (value1 * zm.f32x4s(b1)) + (value2 * zm.f32x4s(b2));
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

inline fn blendColor(src: F32x4, dst: F32x4, state: vk.PipelineColorBlendAttachmentState, constants: [4]f32) F32x4 {
    if (state.blend_enable == .false)
        return src;

    const constant = F32x4{ constants[0], constants[1], constants[2], constants[3] };
    const color_src = if (state.color_blend_op == .min or state.color_blend_op == .max)
        src
    else
        src * blendFactor(state.src_color_blend_factor, src, dst, constant);
    const color_dst = if (state.color_blend_op == .min or state.color_blend_op == .max)
        dst
    else
        dst * blendFactor(state.dst_color_blend_factor, src, dst, constant);
    const alpha_src = if (state.alpha_blend_op == .min or state.alpha_blend_op == .max)
        src
    else
        src * blendFactor(state.src_alpha_blend_factor, src, dst, constant);
    const alpha_dst = if (state.alpha_blend_op == .min or state.alpha_blend_op == .max)
        dst
    else
        dst * blendFactor(state.dst_alpha_blend_factor, src, dst, constant);

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
) VkError!void {
    const io = draw_call.renderer.device.interface.io();
    const depth_stencil_state = draw_call.renderer.state.pipeline.?.interface.mode.graphics.depth_stencil;

    var stencil_state: ?vk.StencilOpState = null;
    var stencil_offset: ?usize = null;
    if (stencil_attachment_access) |stencil| {
        if (depth_stencil_state) |state| {
            if (state.stencil_test_enable == .true) {
                stencil_state = if (front_face)
                    resolveStencilState(draw_call, state.front, true)
                else
                    resolveStencilState(draw_call, state.back, false);
                stencil_offset = targetOffset(stencil.*, x, y) orelse return;
                if (!stencilTest(stencil, stencil_offset.?, stencil_state.?)) {
                    updateStencilValue(stencil, stencil_offset.?, stencil_state.?, stencil_state.?.fail_op);
                    return;
                }
            }
        }
    }

    // After work depth test to avoid overwritten depth pixels during fragment invocations.
    var depth_passed: ?bool = null;
    if (depth_attachment_access) |depth| {
        const depth_offset = targetOffset(depth.*, x, y) orelse return;

        depth.mutex.lock(io) catch return VkError.DeviceLost;
        defer depth.mutex.unlock(io);

        if (depth_stencil_state) |state| {
            depth_passed = depthTestAndUpdate(depth, x, y, z, state);
            if (!depth_passed.? and stencil_state == null)
                return;
        } else {
            const depth_value = blitter.readFloat4(depth.base[depth_offset..], depth.format);
            if (z >= depth_value[0])
                return;
            blitter.writeFloat4(zm.f32x4s(z), depth.base[depth_offset..], depth.format);
            depth_passed = true;
        }
    }

    if (stencil_attachment_access) |stencil| {
        if (stencil_state) |state| {
            if (depth_passed != null and !depth_passed.?) {
                updateStencilValue(stencil, stencil_offset.?, state, state.depth_fail_op);
                return;
            }
            updateStencilValue(stencil, stencil_offset.?, state, state.pass_op);
        }
    }

    for (color_attachment_access, 0..) |maybe_color, location| {
        const color = maybe_color orelse continue;
        const color_offset = targetOffset(color, x, y) orelse continue;

        if (base.format.isUnnormalizedInteger(color.format)) {
            blitter.writeInt4(std.mem.bytesToValue(U32x4, &outputs[location]), color.base[color_offset..], color.format);
        } else {
            const pipeline_data = draw_call.renderer.state.pipeline.?.interface.mode.graphics;
            const src = fragmentOutputFloat4(outputs[location], color.format);
            const encoded_dst = blitter.readFloat4(color.base[color_offset..], color.format);
            const dst = if (base.format.isSrgb(color.format)) zm.srgbToRgb(encoded_dst) else encoded_dst;
            const final_color = if (pipeline_data.color_blend.attachments) |attachments| blk: {
                if (location >= attachments.len)
                    break :blk src;
                const constants = draw_call.renderer.dynamic_state.blend_constants orelse pipeline_data.color_blend.constants;
                const blended = blendColor(src, dst, attachments[location], constants);
                break :blk applyColorWriteMask(blended, dst, attachments[location].color_write_mask);
            } else src;
            const encoded_color = if (base.format.isSrgb(color.format)) zm.rgbToSrgb(final_color) else final_color;
            blitter.writeFloat4(encoded_color, color.base[color_offset..], color.format);
        }
    }
}
