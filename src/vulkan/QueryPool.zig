const std = @import("std");
const vk = @import("vulkan");

const NonDispatchable = @import("NonDispatchable.zig");

const VkError = @import("error_set.zig").VkError;

const Device = @import("Device.zig");

const Self = @This();
pub const ObjectType: vk.ObjectType = .query_pool;

owner: *Device,
query_type: vk.QueryType,
queries: []Query,

vtable: *const VTable,

const Query = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    available: bool = false,
    active: bool = false,
};

pub const VTable = struct {
    destroy: *const fn (*Self, std.mem.Allocator) void,
};

pub fn init(device: *Device, allocator: std.mem.Allocator, info: *const vk.QueryPoolCreateInfo) VkError!Self {
    const queries = allocator.alloc(Query, info.query_count) catch return VkError.OutOfHostMemory;
    errdefer allocator.free(queries);
    for (queries) |*query| {
        query.* = .{};
    }

    return .{
        .owner = device,
        .query_type = info.query_type,
        .queries = queries,
        .vtable = undefined,
    };
}

pub inline fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.vtable.destroy(self, allocator);
}

pub fn reset(self: *Self, first: u32, count: u32) VkError!void {
    const range = try self.queryRange(first, count);
    for (range) |*query| {
        query.value.store(0, .seq_cst);
        query.available = false;
        query.active = false;
    }
}

pub fn begin(self: *Self, query: u32) VkError!void {
    if (self.query_type != .occlusion)
        return VkError.FeatureNotPresent;
    const q = try self.queryAt(query);
    q.value.store(0, .seq_cst);
    q.available = false;
    q.active = true;
}

pub fn end(self: *Self, query: u32) VkError!void {
    const q = try self.queryAt(query);
    q.active = false;
    q.available = true;
}

pub fn writeTimestamp(self: *Self, query: u32, value: u64) VkError!void {
    if (self.query_type != .timestamp)
        return VkError.ValidationFailed;

    const q = try self.queryAt(query);
    q.value.store(value, .seq_cst);
    q.available = true;
    q.active = false;
}

pub fn addSamples(self: *Self, query: u32, samples: u64) VkError!void {
    const q = try self.queryAt(query);
    if (q.active)
        _ = q.value.fetchAdd(samples, .seq_cst);
}

pub fn writeResults(self: *Self, first: u32, count: u32, bytes: []u8, stride: vk.DeviceSize, flags: vk.QueryResultFlags) VkError!void {
    return self.writeResultsImpl(first, count, bytes, stride, flags, true);
}

pub fn copyResults(self: *Self, first: u32, count: u32, bytes: []u8, stride: vk.DeviceSize, flags: vk.QueryResultFlags) VkError!void {
    return self.writeResultsImpl(first, count, bytes, stride, flags, false);
}

fn writeResultsImpl(self: *Self, first: u32, count: u32, bytes: []u8, stride: vk.DeviceSize, flags: vk.QueryResultFlags, report_not_ready: bool) VkError!void {
    _ = try self.queryRange(first, count);
    if (count == 0)
        return;

    const value_size: usize = if (flags.@"64_bit") 8 else 4;
    const item_size = value_size * (1 + @as(usize, @intFromBool(flags.with_availability_bit)));
    if (count > 1 and stride < item_size)
        return VkError.ValidationFailed;

    var not_ready = false;
    for (0..count) |i| {
        const query = &self.queries[first + i];
        if (flags.wait_bit) {
            while (!query.available) {
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
        }

        const offset: usize = @intCast(@as(vk.DeviceSize, @intCast(i)) * stride);
        if (offset + item_size > bytes.len)
            return VkError.Incomplete;

        if (query.available or flags.partial_bit) {
            writeInt(bytes[offset..][0..value_size], query.value.load(.seq_cst), flags);
        } else {
            not_ready = true;
        }

        if (flags.with_availability_bit) {
            writeInt(bytes[offset + value_size ..][0..value_size], @intFromBool(query.available), flags);
        }
    }

    if (not_ready and report_not_ready)
        return VkError.NotReady;
}

fn writeInt(bytes: []u8, value: u64, flags: vk.QueryResultFlags) void {
    if (flags.@"64_bit") {
        std.mem.writeInt(u64, bytes[0..8], value, .little);
    } else {
        std.mem.writeInt(u32, bytes[0..4], @truncate(value), .little);
    }
}

fn queryAt(self: *Self, query: u32) VkError!*Query {
    if (query >= self.queries.len)
        return VkError.ValidationFailed;
    return &self.queries[query];
}

fn queryRange(self: *Self, first: u32, count: u32) VkError![]Query {
    if (first > self.queries.len or count > self.queries.len - first)
        return VkError.ValidationFailed;
    return self.queries[first .. first + count];
}
