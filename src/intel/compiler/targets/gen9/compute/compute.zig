const std = @import("std");

pub const abi = @import("abi.zig");
pub const dispatch = @import("dispatch.zig");
pub const eu_encoder = @import("eu_encoder.zig");
pub const kernel_encoder = @import("kernel_encoder.zig");
pub const message_addresses = @import("message_addresses.zig");
pub const message_descriptor = @import("message_descriptor.zig");
pub const message_lowering = @import("message_lowering.zig");
pub const message_payloads = @import("message_payloads.zig");
pub const resource_layout = @import("resource_layout.zig");
pub const resource_lowering = @import("resource_lowering.zig");
pub const ResourceLayout = resource_layout.Layout;

pub const Error = error{UnsupportedWorkgroupSize};

pub fn validateWorkgroupSize(size: [3]u32) Error!void {
    if (size[0] == 0 or size[1] == 0 or size[2] == 0 or size[0] > 128 or size[1] > 128 or size[2] > 64)
        return Error.UnsupportedWorkgroupSize;
    const xy = std.math.mul(u32, size[0], size[1]) catch return Error.UnsupportedWorkgroupSize;
    const invocations = std.math.mul(u32, xy, size[2]) catch return Error.UnsupportedWorkgroupSize;
    if (invocations > 128)
        return Error.UnsupportedWorkgroupSize;
}

test "[gen9] compute: validate workgroup limits" {
    try validateWorkgroupSize(.{ 1, 1, 1 });
    try validateWorkgroupSize(.{ 128, 1, 1 });
    try std.testing.expectError(Error.UnsupportedWorkgroupSize, validateWorkgroupSize(.{ 0, 1, 1 }));
    try std.testing.expectError(Error.UnsupportedWorkgroupSize, validateWorkgroupSize(.{ 129, 1, 1 }));
    try std.testing.expectError(Error.UnsupportedWorkgroupSize, validateWorkgroupSize(.{ 64, 3, 1 }));
}
