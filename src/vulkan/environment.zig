const std = @import("std");
const builtin = @import("builtin");

pub fn hasEnvVar(name: []const u8) bool {
    return getEnvVar(name) != null;
}

pub fn getEnvVar(name: []const u8) ?[:0]const u8 {
    if (builtin.os.tag == .windows)
        return null;

    if (std.mem.indexOfScalar(u8, name, '=') != null)
        return null;

    var ptr = std.c.environ;
    while (ptr[0]) |line| : (ptr += 1) {
        var line_i: usize = 0;
        while (line[line_i] != 0) : (line_i += 1) {
            if (line_i == name.len) break;
            if (line[line_i] != name[line_i]) break;
        }
        if ((line_i != name.len) or (line[line_i] != '=')) continue;

        return std.mem.sliceTo(line + line_i + 1, 0);
    }
    return null;
}
