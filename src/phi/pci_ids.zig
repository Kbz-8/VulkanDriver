
const PciInfo = struct {
    id: u16,
    name: []const u8,
};

/// Not a hashmap as they need runtime allocations
pub const map = [_]PciInfo{
    .{ .id = 0x2250, .name = "Intel(R) Xeon Phi(TM) Coprocessor 5100 Series" },

    .{ .id = 0x2251, .name = "Intel(R) Xeon Phi(TM) Coprocessor x100 Series" },
    .{ .id = 0x2252, .name = "Intel(R) Xeon Phi(TM) Coprocessor x100 Series" },
    .{ .id = 0x2253, .name = "Intel(R) Xeon Phi(TM) Coprocessor x100 Series" },
    .{ .id = 0x2254, .name = "Intel(R) Xeon Phi(TM) Coprocessor x100 Series" },
    .{ .id = 0x2255, .name = "Intel(R) Xeon Phi(TM) Coprocessor x100 Series" },
    .{ .id = 0x2256, .name = "Intel(R) Xeon Phi(TM) Coprocessor x100 Series" },
    .{ .id = 0x2257, .name = "Intel(R) Xeon Phi(TM) Coprocessor x100 Series" },
    .{ .id = 0x2258, .name = "Intel(R) Xeon Phi(TM) Coprocessor x100 Series" },
    .{ .id = 0x2259, .name = "Intel(R) Xeon Phi(TM) Coprocessor x100 Series" },
    .{ .id = 0x225a, .name = "Intel(R) Xeon Phi(TM) Coprocessor x100 Series" },
    .{ .id = 0x225b, .name = "Intel(R) Xeon Phi(TM) Coprocessor x100 Series" },

    .{ .id = 0x225c, .name = "Intel(R) Xeon Phi(TM) Coprocessor SE10/7120 Series" },
    .{ .id = 0x225d, .name = "Intel(R) Xeon Phi(TM) Coprocessor 3120 Series" },
    .{ .id = 0x225e, .name = "Intel(R) Xeon Phi(TM) Coprocessor 31S1" },

    .{ .id = 0x2262, .name = "Intel(R) Xeon Phi(TM) Coprocessor 7220" },
};
