pub const max_output_locations: usize = 32;

pub const ImageDimension = enum {
    @"1D",
    @"2D",
    @"3D",
    Cube,
    Rect,
    Buffer,
    SubpassData,
};

pub const ImageOffset = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
};

pub const ImageGradient = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
};

pub const ImageDerivatives = struct {
    dx: ImageGradient,
    dy: ImageGradient,
};
