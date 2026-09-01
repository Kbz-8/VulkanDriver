const std = @import("std");
const abi = @import("abi.zig");

pub const ResourceBinding = struct {
    set: u32,
    binding: u32,
};

pub const KernelInfo = struct {
    abi_version: u32 = abi.version,
    workgroup_size: [3]u32,
    dispatch_width: u8,
    stack_size: u32,
    resources: []const ResourceBinding,
};

pub const Artifact = struct {
    code: []u8,
    info: KernelInfo,

    pub fn deinit(self: *Artifact, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.info.resources);
        self.* = undefined;
    }
};
