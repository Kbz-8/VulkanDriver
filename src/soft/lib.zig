const std = @import("std");

const common = @import("common");

test {
    std.testing.refAllDeclsRecursive(@This());
}
