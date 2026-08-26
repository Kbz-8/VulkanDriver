const std = @import("std");

pub const Error = error{
    InvalidExtent,
    InvalidBuffer,
};

pub fn scaleBgra8Nearest(
    source: []const u8,
    source_width: usize,
    source_height: usize,
    destination: []u8,
    destination_width: usize,
    destination_height: usize,
) Error!void {
    if (source_width == 0 or source_height == 0 or destination_width == 0 or destination_height == 0)
        return Error.InvalidExtent;

    const source_pixel_count = std.math.mul(usize, source_width, source_height) catch return Error.InvalidBuffer;
    const source_size = std.math.mul(usize, source_pixel_count, 4) catch return Error.InvalidBuffer;
    const destination_pixel_count = std.math.mul(usize, destination_width, destination_height) catch return Error.InvalidBuffer;
    const destination_size = std.math.mul(usize, destination_pixel_count, 4) catch return Error.InvalidBuffer;
    if (source.len < source_size or destination.len < destination_size)
        return Error.InvalidBuffer;

    for (0..destination_height) |destination_y| {
        const source_y = destination_y * source_height / destination_height;
        for (0..destination_width) |destination_x| {
            const source_x = destination_x * source_width / destination_width;
            const source_offset = (source_y * source_width + source_x) * 4;
            const destination_offset = (destination_y * destination_width + destination_x) * 4;
            @memcpy(destination[destination_offset..][0..4], source[source_offset..][0..4]);
        }
    }
}
