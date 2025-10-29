const std = @import("std");

pub const icd = @import("icd.zig");

pub const Instance = @import("Instance.zig");
pub const PhysicalDevice = @import("PhysicalDevice.zig");

test {
    std.testing.refAllDeclsRecursive(@This());
}
