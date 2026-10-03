const std = @import("std");
const shader_ir = @import("shader_ir");

const bc = @import("../bytecode.zig");
const Program = @import("../Program.zig");

test "[interpreter] generalized image samples lower dimensions, arrayedness, result kind, and LOD" {
    var module = try shader_ir.ir.parser.parseString(std.testing.allocator,
        \\shader fragment @main
        \\{
        \\    @image: u32 = sampled_image[set(0), binding(0)]
        \\    @sampler: resourceHandle[sampler] = sampler[set(0), binding(1)]
        \\    %one_d: constant f32 = 0.5
        \\    %two_d: constant vec2[f32] = null
        \\    %three_d: constant vec3[f32] = null
        \\    %arrayed_three_d: constant vec4[f32] = null
        \\    %lod: constant f32 = 0.0
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %one_d_result: vec4[u32] = image_sample_implicit_lod @image, @sampler, %one_d, dimension one_d, arrayed false
        \\            %two_d_result: vec4[u32] = image_sample_explicit_lod @image, @sampler, %two_d, %lod
        \\            %three_d_result: vec4[u32] = image_sample_implicit_lod @image, @sampler, %arrayed_three_d, dimension three_d, arrayed true
        \\            %cube_result: vec4[u32] = image_sample_implicit_lod @image, @sampler, %three_d, dimension cube, arrayed false
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    var program = try Program.compile(std.testing.allocator, &module);
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 4), program.image_sampler_pairs.len);
    try std.testing.expectEqual(Program.ImageDimension.one_d, program.image_sampler_pairs[0].dimension);
    try std.testing.expect(!program.image_sampler_pairs[0].arrayed);
    try std.testing.expectEqual(bc.ValueKind.unsigned_integer, program.image_sampler_pairs[0].destination_kind);
    try std.testing.expectEqual(bc.Opcode.image_sample_implicit_lod, program.code[0].opcode);
    try std.testing.expectEqual(bc.Register.invalid_register, program.code[0].c);

    try std.testing.expectEqual(Program.ImageDimension.two_d, program.image_sampler_pairs[1].dimension);
    try std.testing.expect(!program.image_sampler_pairs[1].arrayed);
    try std.testing.expectEqual(bc.Opcode.image_sample_explicit_lod, program.code[1].opcode);
    try std.testing.expect(program.code[1].c != .invalid_register);

    try std.testing.expectEqual(Program.ImageDimension.three_d, program.image_sampler_pairs[2].dimension);
    try std.testing.expect(program.image_sampler_pairs[2].arrayed);
    try std.testing.expectEqual(Program.ImageDimension.cube, program.image_sampler_pairs[3].dimension);
    try std.testing.expect(!program.image_sampler_pairs[3].arrayed);
}

test "[interpreter] cube-array image sampling is rejected" {
    var module = try shader_ir.ir.parser.parseString(std.testing.allocator,
        \\shader fragment @main
        \\{
        \\    @image: f32 = sampled_image[set(0), binding(0)]
        \\    @sampler: resourceHandle[sampler] = sampler[set(0), binding(1)]
        \\    %coordinate: constant vec4[f32] = null
        \\    fn @main() -> void
        \\    {
        \\        .entry():
        \\            %result: vec4[f32] = image_sample_implicit_lod @image, @sampler, %coordinate, dimension cube, arrayed true
        \\            return
        \\    }
        \\}
    );
    defer module.deinit();

    try std.testing.expectError(Program.CompileError.UnsupportedOperation, Program.compile(std.testing.allocator, &module));
}
