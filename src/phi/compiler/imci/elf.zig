const std = @import("std");

const elf_header_size: usize = 64;
const program_header_size: usize = 56;
const text_offset: usize = elf_header_size + program_header_size;

pub fn buildElf(allocator: std.mem.Allocator, code: []const u8) ![]u8 {
    const total = try std.math.add(usize, text_offset, code.len);

    const image = try allocator.alloc(u8, total);
    @memset(image, 0);

    const header = image[0..elf_header_size];
    @memcpy(header[0..4], "\x7fELF");

    header[4] = 2; // ELFCLASS64
    header[5] = 1; // ELFDATA2LSB
    header[6] = 1; // EV_CURRENT

    putLe(u16, header, 16, 3); // ET_DYN
    putLe(u16, header, 18, 181); // EM_K1OM
    putLe(u32, header, 20, 1); // EV_CURRENT
    putLe(u64, header, 24, text_offset); // Entry
    putLe(u64, header, 32, 64); // Program headers
    putLe(u64, header, 40, 0); // No section headers
    putLe(u32, header, 48, 0); // Flags
    putLe(u16, header, 52, 64); // ELF header size
    putLe(u16, header, 54, 56); // Program header size
    putLe(u16, header, 56, 1); // One program header

    const phdr = image[elf_header_size .. elf_header_size + program_header_size];

    putLe(u32, phdr, 0, 1); // PT_LOAD
    putLe(u32, phdr, 4, 5); // PF_R | PF_X
    putLe(u64, phdr, 8, 0); // File offset
    putLe(u64, phdr, 16, 0); // Virtual address
    putLe(u64, phdr, 24, 0); // Physical address
    putLe(u64, phdr, 32, @intCast(total));
    putLe(u64, phdr, 40, @intCast(total));
    putLe(u64, phdr, 48, 4096); // Alignment

    @memcpy(image[text_offset..], code);
    return image;
}

fn putLe(comptime T: type, buffer: []u8, offset: usize, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    @memcpy(buffer[offset..][0..bytes.len], &bytes);
}
