const std = @import("std");

const c = @import("phi_protocol_c");

pub const version = c.PHI_KERNEL_ABI_VERSION;

pub const ContextError = error{
    UnsupportedAbiVersion,
    InvalidReservedField,
    InvalidResourceCount,
    InvalidResourceAddress,
    InvalidPushConstantAddress,
    InvalidBufferAddress,
    AddressRangeOverflow,
    InvalidDispatchGeometry,
    BaseGroupRangeOverflow,
    WorkgroupCountOverflow,
    InvalidWorkgroupRange,
};

/// Validate ABI metadata and numeric card address ranges without dereferencing encoded addresses
pub fn validateContext(context: c.PhiKernelContext, descriptors: []const c.PhiKernelBufferDescriptor, begin_workgroup: u64, end_workgroup: u64) ContextError!void {
    if (context.abi_version != version)
        return ContextError.UnsupportedAbiVersion;

    if (context.reserved != 0)
        return ContextError.InvalidReservedField;

    if (context.resource_count != descriptors.len)
        return ContextError.InvalidResourceCount;

    // The u32 resource_count times the 16-byte descriptor size fits in u64
    const table_size = @as(u64, context.resource_count) * c.PHI_KERNEL_BUFFER_DESCRIPTOR_SIZE;

    if (table_size != 0) {
        if (context.resources == 0 or context.resources % c.PHI_KERNEL_BUFFER_DESCRIPTOR_ALIGNMENT != 0)
            return ContextError.InvalidResourceAddress;

        if (@addWithOverflow(context.resources, table_size)[1] != 0)
            return ContextError.AddressRangeOverflow;
    }

    if (context.push_constant_size != 0 and context.push_constants == 0)
        return ContextError.InvalidPushConstantAddress;

    if (@addWithOverflow(context.push_constants, @as(u64, context.push_constant_size))[1] != 0)
        return ContextError.AddressRangeOverflow;

    for (descriptors) |descriptor| {
        if (descriptor.size != 0 and descriptor.address == 0)
            return ContextError.InvalidBufferAddress;

        if (@addWithOverflow(descriptor.address, descriptor.size)[1] != 0)
            return ContextError.AddressRangeOverflow;
    }

    var workgroup_count: u64 = 1;
    for (0..3) |axis| {
        if (context.local_size[axis] == 0 or context.num_workgroups[axis] != context.group_count[axis])
            return ContextError.InvalidDispatchGeometry;

        if (@addWithOverflow(context.base_group[axis], context.group_count[axis])[1] != 0)
            return ContextError.BaseGroupRangeOverflow;

        const product = @mulWithOverflow(workgroup_count, @as(u64, context.group_count[axis]));
        if (product[1] != 0)
            return ContextError.WorkgroupCountOverflow;

        workgroup_count = product[0];
    }

    if (begin_workgroup > end_workgroup or end_workgroup > workgroup_count)
        return ContextError.InvalidWorkgroupRange;
}

test "[compiler] kernel ABI v1 layout constants" {
    try std.testing.expectEqual(@as(u32, 1), version);
    try std.testing.expectEqual(@as(usize, 16), c.PHI_KERNEL_BUFFER_DESCRIPTOR_SIZE);
    try std.testing.expectEqual(@as(usize, 8), c.PHI_KERNEL_BUFFER_DESCRIPTOR_ALIGNMENT);
    try std.testing.expectEqual(@as(usize, 80), c.PHI_KERNEL_CONTEXT_SIZE);
    try std.testing.expectEqual(@as(usize, 8), c.PHI_KERNEL_CONTEXT_ALIGNMENT);
}

test "[compiler] context reject version reserved count and descriptor table ContextErrors" {
    const valid: c.PhiKernelContext = .{
        .abi_version = version,
        .resource_count = 2,
        .resources = 8,
        .push_constants = 0,
        .push_constant_size = 0,
        .base_group = .{ 0, 0, 0 },
        .group_count = .{ 1, 1, 1 },
        .local_size = .{ 1, 1, 1 },
        .num_workgroups = .{ 1, 1, 1 },
    };

    const descriptors = [_]c.PhiKernelBufferDescriptor{
        .{ .address = 0, .size = 0 },
        .{ .address = 0, .size = 0 },
    };

    var context = valid;
    for ([_]u32{ 0, version + 1 }) |abi_version| {
        context.abi_version = abi_version;
        try std.testing.expectError(ContextError.UnsupportedAbiVersion, validateContext(context, &descriptors, 0, 1));
    }

    context = valid;
    context.reserved = 1;

    try std.testing.expectError(ContextError.InvalidReservedField, validateContext(context, &descriptors, 0, 1));

    context = valid;

    for ([_]u32{ 0, 1, 3, std.math.maxInt(u32) }) |count| {
        context.resource_count = count;
        try std.testing.expectError(ContextError.InvalidResourceCount, validateContext(context, &descriptors, 0, 1));
    }

    context = valid;

    for ([_]u64{ 0, 1, 12 }) |address| {
        context.resources = address;
        try std.testing.expectError(ContextError.InvalidResourceAddress, validateContext(context, &descriptors, 0, 1));
    }

    // One descriptor would fit here, but the complete two-descriptor table does not
    context.resources = std.math.maxInt(u64) - 23;
    try std.testing.expectError(ContextError.AddressRangeOverflow, validateContext(context, &descriptors, 0, 1));

    context.resources = std.math.maxInt(u64) - 39;
    try validateContext(context, &descriptors, 0, 1);
}

test "[compiler] context check local sizes" {
    const valid: c.PhiKernelContext = .{
        .abi_version = version,
        .resource_count = 0,
        .resources = 0,
        .push_constants = 0,
        .push_constant_size = 0,
        .base_group = .{ 2, 3, 4 },
        .group_count = .{ 2, 3, 4 },
        .local_size = .{ 1, 2, 3 },
        .num_workgroups = .{ 2, 3, 4 },
    };

    for (0..3) |axis| {
        var context = valid;
        context.local_size[axis] = 0;
        try std.testing.expectError(ContextError.InvalidDispatchGeometry, validateContext(context, &.{}, 0, 24));

        context = valid;
        context.local_size[axis] = std.math.maxInt(u32);
        try validateContext(context, &.{}, 0, 24);

        context = valid;
        context.num_workgroups[axis] += 1;
        try std.testing.expectError(ContextError.InvalidDispatchGeometry, validateContext(context, &.{}, 0, 24));

        context = valid;
        context.base_group[axis] = std.math.maxInt(u32) - context.group_count[axis];
        try validateContext(context, &.{}, 0, 24);

        context.base_group[axis] += 1;
        try std.testing.expectError(ContextError.BaseGroupRangeOverflow, validateContext(context, &.{}, 0, 24));
    }
}

test "[compiler] context check u64 workgroup product and accepts zero-workgroup dispatches" {
    var context: c.PhiKernelContext = .{
        .abi_version = version,
        .resource_count = 0,
        .resources = 0,
        .push_constants = 0,
        .push_constant_size = 0,
        .base_group = .{ 0, 0, 0 },
        .group_count = .{ std.math.maxInt(u32), std.math.maxInt(u32), 1 },
        .local_size = .{ std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) },
        .num_workgroups = .{ std.math.maxInt(u32), std.math.maxInt(u32), 1 },
    };

    const count = @as(u64, std.math.maxInt(u32)) * std.math.maxInt(u32);

    try validateContext(context, &.{}, 0, count);
    try validateContext(context, &.{}, count, count);

    try std.testing.expectError(ContextError.InvalidWorkgroupRange, validateContext(context, &.{}, 0, count + 1));

    context.group_count[2] = 2;
    context.num_workgroups = context.group_count;

    try std.testing.expectError(ContextError.WorkgroupCountOverflow, validateContext(context, &.{}, 0, 0));

    for (0..3) |axis| {
        context.group_count = .{ std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) };
        context.group_count[axis] = 0;
        context.num_workgroups = context.group_count;
        context.base_group = .{ 0, 0, 0 };
        context.base_group[axis] = std.math.maxInt(u32);

        // With no resources, even an unaligned unused encoded address is ignored
        context.resources = std.math.maxInt(u64);

        try validateContext(context, &.{}, 0, 0);
        try std.testing.expectError(ContextError.InvalidWorkgroupRange, validateContext(context, &.{}, 0, 1));
        try std.testing.expectError(ContextError.InvalidWorkgroupRange, validateContext(context, &.{}, 1, 1));
    }
}
