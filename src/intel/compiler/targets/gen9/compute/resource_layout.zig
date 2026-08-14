const std = @import("std");
const ids = @import("../../../ir/id.zig");
const program_ir = @import("../../../ir/program.zig");

pub const max_storage_buffers: usize = 4;

pub const Error = std.mem.Allocator.Error || error{
    TooManyStorageBuffers,
};

pub const Binding = struct {
    set: u32,
    binding: u32,
    binding_table_index: u8,
};

const Candidate = struct {
    resource: ids.StorageBufferId,
    set: u32,
    binding: u32,
};

pub const Layout = struct {
    bindings: []Binding,
    resource_indices: []?u8,

    pub fn init(allocator: std.mem.Allocator, program: *const program_ir.Program) Error!Layout {
        var candidates: std.ArrayList(Candidate) = .empty;
        defer candidates.deinit(allocator);

        for (program.storage_buffers.entries.items, 0..) |entry, index| {
            const buffer = entry orelse continue;
            try candidates.append(allocator, .{
                .resource = ids.StorageBufferId.fromIndex(index),
                .set = buffer.set,
                .binding = buffer.binding,
            });
        }
        std.mem.sort(Candidate, candidates.items, {}, lessThan);

        var unique_count: usize = 0;
        for (candidates.items, 0..) |candidate, index| {
            if (index == 0 or candidate.set != candidates.items[index - 1].set or candidate.binding != candidates.items[index - 1].binding)
                unique_count += 1;
        }
        if (unique_count > max_storage_buffers)
            return Error.TooManyStorageBuffers;

        const bindings = try allocator.alloc(Binding, unique_count);
        errdefer allocator.free(bindings);
        const resource_indices = try allocator.alloc(?u8, program.storage_buffers.entries.items.len);
        errdefer allocator.free(resource_indices);
        @memset(resource_indices, null);

        var binding_index: usize = 0;
        for (candidates.items, 0..) |candidate, index| {
            if (index == 0 or candidate.set != candidates.items[index - 1].set or candidate.binding != candidates.items[index - 1].binding) {
                bindings[binding_index] = .{
                    .set = candidate.set,
                    .binding = candidate.binding,
                    .binding_table_index = @intCast(binding_index),
                };
                binding_index += 1;
            }
            resource_indices[candidate.resource.index()] = @intCast(binding_index - 1);
        }
        std.debug.assert(binding_index == bindings.len);

        return .{
            .bindings = bindings,
            .resource_indices = resource_indices,
        };
    }

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.bindings);
        allocator.free(self.resource_indices);
        self.* = undefined;
    }

    pub fn bindingTableIndex(self: *const Layout, resource: ids.StorageBufferId) ?u8 {
        if (resource.index() >= self.resource_indices.len)
            return null;
        return self.resource_indices[resource.index()];
    }
};

fn lessThan(_: void, lhs: Candidate, rhs: Candidate) bool {
    if (lhs.set != rhs.set)
        return lhs.set < rhs.set;
    if (lhs.binding != rhs.binding)
        return lhs.binding < rhs.binding;
    return lhs.resource.index() < rhs.resource.index();
}

test "[gen9] compute resource layout: assign stable binding-table indices" {
    const device = @import("../../../device.zig");

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, device_info, .simd8);
    defer program.deinit();

    const third = try program.addStorageBuffer(.{ .set = 2, .binding = 7 });
    const first = try program.addStorageBuffer(.{ .set = 0, .binding = 3 });
    const alias = try program.addStorageBuffer(.{ .set = 0, .binding = 3 });
    const second = try program.addStorageBuffer(.{ .set = 1, .binding = 0 });

    var layout = try Layout.init(std.testing.allocator, &program);
    defer layout.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), layout.bindings.len);
    try std.testing.expectEqual(Binding{ .set = 0, .binding = 3, .binding_table_index = 0 }, layout.bindings[0]);
    try std.testing.expectEqual(Binding{ .set = 1, .binding = 0, .binding_table_index = 1 }, layout.bindings[1]);
    try std.testing.expectEqual(Binding{ .set = 2, .binding = 7, .binding_table_index = 2 }, layout.bindings[2]);
    try std.testing.expectEqual(@as(?u8, 0), layout.bindingTableIndex(first));
    try std.testing.expectEqual(@as(?u8, 0), layout.bindingTableIndex(alias));
    try std.testing.expectEqual(@as(?u8, 1), layout.bindingTableIndex(second));
    try std.testing.expectEqual(@as(?u8, 2), layout.bindingTableIndex(third));
}

test "[gen9] compute resource layout: enforce advertised storage-buffer limit" {
    const device = @import("../../../device.zig");

    const device_info: device.DeviceInfo = .{
        .generation = .gen9,
        .platform = .skylake,
        .pci_device_id = 0x1912,
        .grf_count = 128,
    };
    var program = program_ir.Program.init(std.testing.allocator, .{ 1, 1, 1 }, device_info, .simd8);
    defer program.deinit();
    for (0..max_storage_buffers + 1) |binding|
        _ = try program.addStorageBuffer(.{ .set = 0, .binding = @intCast(binding) });

    try std.testing.expectError(Error.TooManyStorageBuffers, Layout.init(std.testing.allocator, &program));
}
