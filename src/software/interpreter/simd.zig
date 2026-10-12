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
