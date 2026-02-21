const std = @import("std");
const vk = @import("vulkan");
const base = @import("base");

const SoftDescriptorSet = @import("../SoftDescriptorSet.zig");
const SoftPipeline = @import("../SoftPipeline.zig");

pipeline: ?*SoftPipeline,
sets: [base.VULKAN_MAX_DESCRIPTOR_SETS]?*SoftDescriptorSet,
