const std = @import("std");
const base = @import("base");

const common = @import("common.zig");
const edge_function = @import("edge_function.zig");
const fragment = @import("../fragment/dispatcher.zig");

const Renderer = @import("../Renderer.zig");
const VkError = base.VkError;

const tile_size: usize = 32;

pub const Batch = struct {
    arena: std.heap.ArenaAllocator,
    state: edge_function.FillState,
    triangles: std.ArrayList(edge_function.PreparedTriangle) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        draw_call: *Renderer.DrawCall,
        color_attachment_access: []const ?common.RenderTargetAccess,
        depth_attachment_access: ?*common.RenderTargetAccess,
        stencil_attachment_access: ?*common.RenderTargetAccess,
    ) VkError!Batch {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .state = try edge_function.initFillState(
                allocator,
                draw_call,
                color_attachment_access,
                depth_attachment_access,
                stencil_attachment_access,
                .tile_exclusive,
            ),
        };
    }

    pub fn deinit(self: *Batch) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn arenaAllocator(self: *Batch) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn appendTriangle(self: *Batch, vertices: [3]common.RasterVertex, provoking_vertex: *const Renderer.Vertex, front_face: bool) VkError!void {
        const triangle = edge_function.prepareTriangle(&self.state, vertices, provoking_vertex, front_face) orelse return;
        self.triangles.append(self.arena.allocator(), triangle) catch return VkError.OutOfDeviceMemory;
    }

    pub fn execute(self: *Batch) VkError!void {
        if (self.triangles.items.len == 0)
            return;

        const framebuffer = self.state.draw_call.framebuffer.interface;
        var bins = try Bins.build(
            self.state.allocator,
            self.triangles.items,
            framebuffer.width,
            framebuffer.height,
        );
        defer bins.deinit(self.state.allocator);
        if (bins.active_tiles.len == 0)
            return;

        var context: WorkerContext = .{
            .batch = self,
            .bins = &bins,
            .next_active_tile = .init(0),
            .failed = .init(false),
            .error_mutex = .init,
            .first_error = null,
        };

        const io = self.state.draw_call.renderer.device.interface.io();
        const worker_count = @min(self.state.worker_capacity, bins.active_tiles.len);
        var group: std.Io.Group = .init;
        for (0..worker_count) |worker_index|
            group.async(io, workerWrapper, .{ &context, worker_index });

        group.await(io) catch return VkError.DeviceLost;

        if (context.first_error) |err|
            return err;
        if (context.failed.load(.acquire))
            return VkError.DeviceLost;
    }
};

const Bins = struct {
    tiles_x: usize,
    offsets: []usize,
    triangle_indices: []usize,
    active_tiles: []usize,

    fn build(allocator: std.mem.Allocator, triangles: []const edge_function.PreparedTriangle, framebuffer_width: usize, framebuffer_height: usize) VkError!Bins {
        const tiles_x = std.math.divCeil(usize, framebuffer_width, tile_size) catch return VkError.MathFailedDrv;
        const tiles_y = std.math.divCeil(usize, framebuffer_height, tile_size) catch return VkError.MathFailedDrv;
        const tile_count = std.math.mul(usize, tiles_x, tiles_y) catch return VkError.MathFailedDrv;

        const counts = allocator.alloc(usize, tile_count) catch return VkError.OutOfDeviceMemory;
        defer allocator.free(counts);
        @memset(counts, 0);

        for (triangles) |triangle| {
            const range = triangleTileRange(triangle.bounds);
            var tile_y = range.min_y;
            while (tile_y <= range.max_y) : (tile_y += 1) {
                var tile_x = range.min_x;
                while (tile_x <= range.max_x) : (tile_x += 1) {
                    const tile_index = tile_y * tiles_x + tile_x;
                    counts[tile_index] = std.math.add(usize, counts[tile_index], 1) catch return VkError.MathFailedDrv;
                }
            }
        }

        const offsets_len = std.math.add(usize, tile_count, 1) catch return VkError.MathFailedDrv;
        const offsets = allocator.alloc(usize, offsets_len) catch return VkError.OutOfDeviceMemory;
        errdefer allocator.free(offsets);
        offsets[0] = 0;
        var active_tile_count: usize = 0;
        for (counts, 0..) |count, tile_index| {
            offsets[tile_index + 1] = std.math.add(usize, offsets[tile_index], count) catch return VkError.MathFailedDrv;
            if (count != 0)
                active_tile_count += 1;
        }

        const triangle_indices = allocator.alloc(usize, offsets[tile_count]) catch return VkError.OutOfDeviceMemory;
        errdefer allocator.free(triangle_indices);
        const cursors = allocator.dupe(usize, offsets[0..tile_count]) catch return VkError.OutOfDeviceMemory;
        defer allocator.free(cursors);

        for (triangles, 0..) |triangle, triangle_index| {
            const range = triangleTileRange(triangle.bounds);
            var tile_y = range.min_y;
            while (tile_y <= range.max_y) : (tile_y += 1) {
                var tile_x = range.min_x;
                while (tile_x <= range.max_x) : (tile_x += 1) {
                    const tile_index = tile_y * tiles_x + tile_x;
                    triangle_indices[cursors[tile_index]] = triangle_index;
                    cursors[tile_index] += 1;
                }
            }
        }

        const active_tiles = allocator.alloc(usize, active_tile_count) catch return VkError.OutOfDeviceMemory;
        errdefer allocator.free(active_tiles);

        var active_index: usize = 0;
        for (counts, 0..) |count, tile_index| {
            if (count == 0)
                continue;
            active_tiles[active_index] = tile_index;
            active_index += 1;
        }

        return .{
            .tiles_x = tiles_x,
            .offsets = offsets,
            .triangle_indices = triangle_indices,
            .active_tiles = active_tiles,
        };
    }

    fn deinit(self: *Bins, allocator: std.mem.Allocator) void {
        allocator.free(self.offsets);
        allocator.free(self.triangle_indices);
        allocator.free(self.active_tiles);
        self.* = undefined;
    }

    fn triangleIndices(self: *const Bins, tile_index: usize) []const usize {
        return self.triangle_indices[self.offsets[tile_index]..self.offsets[tile_index + 1]];
    }

    fn tileBounds(self: *const Bins, tile_index: usize) common.PixelBounds {
        const tile_x = tile_index % self.tiles_x;
        const tile_y = tile_index / self.tiles_x;
        const min_x = tile_x * tile_size;
        const min_y = tile_y * tile_size;
        return .{
            .min_x = @intCast(min_x),
            .max_x = @intCast(min_x + tile_size - 1),
            .min_y = @intCast(min_y),
            .max_y = @intCast(min_y + tile_size - 1),
        };
    }
};

const TileRange = struct {
    min_x: usize,
    max_x: usize,
    min_y: usize,
    max_y: usize,
};

fn triangleTileRange(bounds: common.PixelBounds) TileRange {
    return .{
        .min_x = @as(usize, @intCast(bounds.min_x)) / tile_size,
        .max_x = @as(usize, @intCast(bounds.max_x)) / tile_size,
        .min_y = @as(usize, @intCast(bounds.min_y)) / tile_size,
        .max_y = @as(usize, @intCast(bounds.max_y)) / tile_size,
    };
}

const WorkerContext = struct {
    batch: *Batch,
    bins: *const Bins,
    next_active_tile: std.atomic.Value(usize),
    failed: std.atomic.Value(bool),
    error_mutex: std.Io.Mutex,
    first_error: ?VkError,

    fn recordError(self: *WorkerContext, err: VkError) void {
        self.failed.store(true, .release);
        const io = self.batch.state.draw_call.renderer.device.interface.io();
        self.error_mutex.lock(io) catch return;
        defer self.error_mutex.unlock(io);
        if (self.first_error == null)
            self.first_error = err;
    }
};

fn workerWrapper(context: *WorkerContext, worker_index: usize) void {
    worker(context, worker_index) catch |err| context.recordError(err);
}

fn worker(context: *WorkerContext, worker_index: usize) VkError!void {
    const state = &context.batch.state;

    // SAFETY: only used if state.has_fragment_shader
    var fragment_worker: fragment.Worker = if (state.has_fragment_shader) try fragment.acquireWorker(state.draw_call, worker_index) else undefined;
    defer if (state.has_fragment_shader)
        fragment_worker.release();

    while (!context.failed.load(.acquire)) {
        const active_index = context.next_active_tile.fetchAdd(1, .monotonic);
        if (active_index >= context.bins.active_tiles.len)
            break;

        const tile_index = context.bins.active_tiles[active_index];
        const bounds = context.bins.tileBounds(tile_index);
        for (context.bins.triangleIndices(tile_index)) |triangle_index| {
            try edge_function.rasterizeTriangleInRect(
                state,
                if (state.has_fragment_shader) &fragment_worker else null,
                &context.batch.triangles.items[triangle_index],
                bounds,
            );
        }
    }
}
