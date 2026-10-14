const std = @import("std");

pub const Error = std.mem.Allocator.Error || error{
    MissingEntryPoint,
    MissingWorkgroupSize,
    InvalidModule,
    UnsupportedStage,
    UnsupportedType,
    UnsupportedOperation,
    UnsupportedDispatchWidth,
    UnsupportedWorkgroupSize,
    UnsupportedEntrySignature,
    UnsupportedControlFlow,
    UnsupportedConstant,
    UnsupportedResource,
    UnsupportedSourceSemantics,
    UnstructuredControlFlow,
    RegisterAllocationFailed,
    EncodingFailed,
    BranchOutOfRange,
    CodeGenerationNotImplemented,
};
