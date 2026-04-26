const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");
const zm = base.zm;

const VkError = base.VkError;

const lib = @import("../lib.zig");

const Renderer = @import("Renderer.zig");

pub const F32x4 = zm.F32x4;

pub fn drawLineBresenham(allocator: std.mem.Allocator, fragments: *std.ArrayList(Renderer.Fragment), v0: F32x4, v1: F32x4) VkError!void {
    var x0: i32 = @intFromFloat(v0[0]);
    var y0: i32 = @intFromFloat(v0[1]);
    var x1: i32 = @intFromFloat(v1[0]);
    var y1: i32 = @intFromFloat(v1[1]);

    const steep = blk: {
        if (@abs(y1 - y0) > @abs(x1 - x0)) {
            std.mem.swap(i32, &x0, &y0);
            std.mem.swap(i32, &x1, &y1);
            break :blk true;
        }
        break :blk false;
    };

    if (x0 > x1) {
        std.mem.swap(i32, &x0, &x1);
        std.mem.swap(i32, &y0, &y1);
    }

    const d_err = @abs(y1 - y0);
    const d_x = x1 - x0;
    const y_step: i32 = if (y0 > y1) -1 else 1;

    var err = @divTrunc(d_x, 2); // Pixel center.
    var y = y0;

    var x = x0;
    while (x <= x1) : (x += 1) {
        const x_fragment: f32 = @floatFromInt(if (steep) y else x);
        const y_fragment: f32 = @floatFromInt(if (steep) x else y);

        fragments.append(allocator, .{
            .position = zm.f32x4(x_fragment, y_fragment, 0.0, 1.0),
            .color = zm.f32x4(1.0, 1.0, 1.0, 1.0),
        }) catch return VkError.OutOfDeviceMemory;

        err -= @intCast(d_err);
        if (err < 0) {
            y += y_step;
            err += d_x;
        }
    }
}

fn edgeFunction(a: F32x4, b: F32x4, p: F32x4) f32 {
    return ((p[0] - a[0]) * (b[1] - a[1])) - ((p[1] - a[1]) * (b[0] - a[0]));
}

pub fn drawTriangleFilled(allocator: std.mem.Allocator, fragments: *std.ArrayList(Renderer.Fragment), v0: F32x4, v1: F32x4, v2: F32x4) VkError!void {
    const min_x: i32 = @intFromFloat(@floor(@min(v0[0], @min(v1[0], v2[0]))));
    const max_x: i32 = @intFromFloat(@ceil(@max(v0[0], @max(v1[0], v2[0]))));
    const min_y: i32 = @intFromFloat(@floor(@min(v0[1], @min(v1[1], v2[1]))));
    const max_y: i32 = @intFromFloat(@ceil(@max(v0[1], @max(v1[1], v2[1]))));

    const area = edgeFunction(v0, v1, v2);
    if (area == 0.0) return;

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const p = zm.f32x4(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, 0.0, 1.0);

            const w0 = edgeFunction(v1, v2, p);
            const w1 = edgeFunction(v2, v0, p);
            const w2 = edgeFunction(v0, v1, p);

            const inside = if (area > 0.0)
                w0 >= 0.0 and w1 >= 0.0 and w2 >= 0.0
            else
                w0 <= 0.0 and w1 <= 0.0 and w2 <= 0.0;

            if (!inside) continue;

            const b0 = w0 / area;
            const b1 = w1 / area;
            const b2 = w2 / area;
            const z = (b0 * v0[2]) + (b1 * v1[2]) + (b2 * v2[2]);

            fragments.append(allocator, .{
                .position = zm.f32x4(@floatFromInt(x), @floatFromInt(y), z, 1.0),
                .color = zm.f32x4(1.0, 1.0, 1.0, 1.0),
            }) catch return VkError.OutOfDeviceMemory;
        }
    }
}
