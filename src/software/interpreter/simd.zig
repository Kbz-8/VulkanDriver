const std = @import("std");
const builtin = @import("builtin");

pub const has_avx2 = builtin.cpu.arch.isX86() and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
pub const lane_count: comptime_int = if (has_avx2) 8 else 4;
pub const Lane = if (lane_count == 8) u3 else u2;
pub const LaneMask = if (lane_count == 8) u8 else u4;
pub const full_lane_mask: LaneMask = std.math.maxInt(LaneMask);

pub fn laneBit(lane: Lane) LaneMask {
    return @as(LaneMask, 1) << lane;
}

pub fn cosh(x: anytype) @TypeOf(x) {
    const V = @TypeOf(x);
    const F = floatType(V);
    const a = @abs(x);
    const one = splat(V, 1.0);
    const m = expm1Vec(a);
    // cosh(a) = 1 + m^2/(2*(1+m)), reordered to avoid m*m overflow
    const normal = one + (m * splat(V, 0.5)) * (m / (one + m));
    // exp(a)/2 can overflow prematurely, so split the exponential
    const e = @exp(a * splat(V, 0.5));
    const large = (e * splat(V, 0.5)) * e;
    const split = splat(V, @log(std.math.floatMax(F)) - 1.0);
    return select(a > split, large, normal);
}

pub fn sinh(x: anytype) @TypeOf(x) {
    const V = @TypeOf(x);
    const F = floatType(V);
    const a = @abs(x);
    const one = splat(V, 1.0);
    const m = expm1Vec(a);
    const normal = splat(V, 0.5) * (m + m / (one + m));
    const e = @exp(a * splat(V, 0.5));
    const large = (e * splat(V, 0.5)) * e;
    const split = splat(V, @log(std.math.floatMax(F)) - 1.0);
    return withSign(select(a > split, large, normal), x);
}

pub fn tanh(x: anytype) @TypeOf(x) {
    const V = @TypeOf(x);
    _ = floatType(V);
    const a = @abs(x);
    const m = expm1Vec(-splat(V, 2.0) * a);
    return withSign(-m / (splat(V, 2.0) + m), x);
}

pub fn acosh(x: anytype) @TypeOf(x) {
    const V = @TypeOf(x);
    const F = floatType(V);
    const one = splat(V, 1.0);
    const t = x - one;
    const normal = log1pVec(t + @sqrt(t * (x + one)));
    const large = @log(x) + splat(V, std.math.ln2);
    const split = splat(V, @sqrt(std.math.floatMax(F)) * 0.25);
    return select(x < one, splat(V, std.math.nan(F)), select(x > split, large, normal));
}

pub fn asinh(x: anytype) @TypeOf(x) {
    const V = @TypeOf(x);
    const F = floatType(V);
    const a = @abs(x);
    const one = splat(V, 1.0);
    const aa = a * a;
    const normal = log1pVec(a + aa / (one + @sqrt(one + aa)));
    const large = @log(a) + splat(V, std.math.ln2);
    const split = splat(V, @sqrt(std.math.floatMax(F)) * 0.25);
    return withSign(select(a > split, large, normal), x);
}

pub fn atanh(x: anytype) @TypeOf(x) {
    const V = @TypeOf(x);
    _ = floatType(V);
    const a = @abs(x);
    const one = splat(V, 1.0);
    const magnitude = splat(V, 0.5) * log1pVec((splat(V, 2.0) * a) / (one - a));
    return withSign(select(a > one, splat(V, std.math.nan(floatType(V))), magnitude), x);
}

fn floatType(comptime V: type) type {
    return switch (@typeInfo(V)) {
        .vector => |v| switch (@typeInfo(v.child)) {
            .float => v.child,
            else => @compileError("expected a vector of floats"),
        },
        else => @compileError("expected @Vector(N, Float), not a scalar"),
    };
}

fn splat(comptime V: type, comptime value: anytype) V {
    return @splat(@as(floatType(V), value));
}

fn select(mask: anytype, yes: anytype, no: @TypeOf(yes)) @TypeOf(yes) {
    return @select(floatType(@TypeOf(yes)), mask, yes, no);
}

fn withSign(magnitude: anytype, x: @TypeOf(magnitude)) @TypeOf(magnitude) {
    const V = @TypeOf(x);
    const zero = splat(V, 0.0);
    // Preserve +0 and -0 for odd functions
    return select(x == zero, x, select(x < zero, -magnitude, magnitude));
}

fn invFactorial(comptime n: usize) comptime_float {
    var result: comptime_float = 1.0;
    for (1..n + 1) |i|
        result /= @as(comptime_float, @floatFromInt(i));
    return result;
}

fn expm1Vec(x: anytype) @TypeOf(x) {
    const V = @TypeOf(x);
    const F = floatType(V);
    const degree: usize = switch (@bitSizeOf(F)) {
        16 => 6,
        32 => 9,
        64 => 14,
        80 => 20,
        128 => 28,
        else => @compileError("unsupported float width"),
    };
    const small = @abs(x) < splat(V, 0.25);
    const z = select(small, x, splat(V, 0.0));

    var p = splat(V, invFactorial(degree + 1));
    inline for (0..degree) |i| {
        p = p * z + splat(V, invFactorial(degree - i));
    }
    return select(small, z * p, @exp(x) - splat(V, 1.0));
}

fn log1pVec(x: anytype) @TypeOf(x) {
    const V = @TypeOf(x);
    const one = splat(V, 1.0);
    const y = one + x;
    const delta = y - one;
    const unchanged = delta == splat(V, 0.0);
    const safe_delta = select(unchanged, one, delta);
    const corrected = @log(y) * (x / safe_delta);
    return select(unchanged, x, select(x == splat(V, std.math.inf(floatType(V))), x, corrected));
}
