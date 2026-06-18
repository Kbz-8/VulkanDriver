const std = @import("std");
const drm = @import("drm");

const Instance = @import("Instance.zig");
const VkError = @import("error_set.zig").VkError;

pub fn enumerateDrmPhysicalDevices(allocator: std.mem.Allocator, instance: *Instance) VkError![]drm.Card {
    const io = instance.io();

    var devices: std.ArrayList(drm.Card) = .empty;
    errdefer {
        for (devices.items[0..]) |card| {
            card.close(io);
        }
        devices.deinit(allocator);
    }

    var dri_dir = std.Io.Dir.openDirAbsolute(io, drm.dir_name, .{ .iterate = true }) catch return VkError.InitializationFailed;
    defer dri_dir.close(io);

    var iterator = dri_dir.iterate();
    while (iterator.next(io) catch return VkError.InitializationFailed) |entry| {
        if (entry.kind != .character_device)
            continue;

        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ drm.dir_name, entry.name }) catch return VkError.OutOfHostMemory;
        defer allocator.free(path);

        const card = drm.Card.open(io, path) catch continue;
        devices.append(allocator, card) catch return VkError.OutOfHostMemory;
    }

    return devices.toOwnedSlice(allocator) catch VkError.OutOfHostMemory;
}
