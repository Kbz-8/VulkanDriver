pub fn writePacked(comptime T: type, bytes: []u8, value: T) void {
    const raw: [@sizeOf(T)]u8 = @bitCast(value);
    @memcpy(bytes[0..@sizeOf(T)], raw[0..]);
}
