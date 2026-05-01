const std = @import("std");
const vk = @import("vulkan");
const lib = @import("lib.zig");

const VkError = @import("../error_set.zig").VkError;

const Device = @import("../Device.zig");

const Self = @This();

pub const ObjectType: vk.ObjectType = .surface_khr;
