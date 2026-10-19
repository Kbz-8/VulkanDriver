# Backend-Agnostic Shader IR

> Note: this IR is still foundational and incomplete. Its representation may
> change as the compiler gains features. Backends should not treat it as a
> stable ABI yet.

This directory contains the backend-agnostic shader intermediate representation.
It sits between SPIR-V and the backends that consume it.
Format-specific details are removed while types, values, control flow,
interfaces, and semantic operations remain.

## Overview

- One `Module` describes one selected shader entry point.
- The current stages are `vertex`, `fragment`, and `compute`.
- Values are typed and use static single assignment (SSA).
- Blocks act as control-flow graph labels, but also own instructions,
  parameters, a terminator, and structured-control metadata.
- Block parameters serve the same purpose as `OpPhi` in SPIR-V.
- Instructions speak normalized meanings, not source-format opcodes.
- Types and constants are interned. Equal things share one identity.
- IDs are stable. Erasure leaves a tombstone; no dead ID is reused for another object.
- The printer is for debugging and tests. Its output can be parsed back into a
  validated module, but it is not yet a stable interchange format.

## Printer syntax

The printer uses these prefixes:

| Prefix  | Meaning                                                          | Example               |
| ------- | ---------------------------------------------------------------- | --------------------- |
| `%id`   | An SSA value, whether constant, parameter, or instruction result | `%3`, `%merged_value` |
| `@name` | A function, interface, or resource declaration                   | `@main`, `@out_color` |
| `.name` | A basic block                                                    | `.entry`, `.merge`    |
| `#N`    | A constant-store identity used within composite constants        | `#2`                  |

Names are annotations rather than identity. When a name is absent, invalid for
the textual grammar, or duplicated, the printer uses a numeric `%N` value
reference. Other unnamed objects use forms such as `@fn0`, `@interface1`, and
`.b2`. The parser accepts both numeric and identifier-shaped value references.

An instruction that produces a value prints its result type explicitly:

```text
%result: <type> = <opcode> <operands>
```

The type annotation makes operations such as `bitcast` and heterogeneous
`composite_construct` unambiguous when the text is parsed. Constants, function
parameters, and block parameters already carry their types in their own forms.

The outer structure has this shape:

```text
shader <stage> @<entry-point>
{
    <interface declarations>
    <resource declarations>
    <workgroup variable declarations>
    <constant declarations>

    fn @<name>(<parameters>) -> <type>
    {
        .<block>(<block parameters>):
            <instructions>
            <terminator>

    }
}
```

Execution modes, source locations, and structured-control metadata exist in
memory, but the printer does not display them yet.

## Parsing

`ir.parser` accepts the complete syntax emitted by the printer:

```zig
var from_string = try ir.parser.parseString(allocator, source);
defer from_string.deinit();

var from_file = try ir.parser.parseFile(allocator, io, "shader.ir");
defer from_file.deinit();
```

Use `parseFileInDir` when the path is relative to an existing `std.Io.Dir`.
Each parser entry point owns the returned module with the supplied allocator and
runs the IR validator before returning it. Parse, reference-resolution, or
validation failures are returned as errors. Because the printer omits the
metadata listed above, a print/parse round trip preserves the displayed IR but
cannot recover those hidden fields.

## Types

Types are interned in the module and printed inline; their `TypeId` is hidden.

| Kind             | Printed form                    | Meaning                                                                   |
| ---------------- | ------------------------------- | ------------------------------------------------------------------------- |
| Void             | `void`                          | No value. Used mainly for functions that return nothing.                  |
| Boolean          | `bool`                          | A truth value.                                                            |
| Signed integer   | `i32`                           | A signed integer of the written bit width.                                |
| Unsigned integer | `u32`                           | An unsigned integer of the written bit width.                             |
| Floating point   | `f32`                           | A floating value of the written bit width.                                |
| Vector           | `vec4[f32]`                     | A fixed number of equal scalar elements. Its length must be at least two. |
| Matrix           | `mat4x4[f32]`                   | A fixed number of equal vector elements. Its length must be at least two. |
| Array            | `array[u32, 8]`                 | A fixed number of equal elements. Its length must not be zero.            |
| Structure        | `struct[f32, vec4[f32]]`        | An ordered sequence of potentially different member types.                |
| Pointer          | `ptr[workgroup, u32]`           | A pointer to a type within an address space.                              |
| Resource handle  | `resourceHandle[sampled_image]` | An opaque handle for later resource operations.                           |

The current address spaces are `function`, `private`, `workgroup`,
`input`, `output`, `uniform`, `storage`, `push_constant`, and `physical`.

The current resource kinds are `uniform_buffer`, `storage_buffer`,
`sampled_image`, `storage_image`, and `sampler`. A resource handle may also
carry an optional data type in memory, although the printer omits that type.

## Resources

Resources are declared at module scope. Every `ResourceKind` uses the same
`set` and `binding` syntax:

```text
@name: TYPE = storage_buffer[set(N), binding(N)]
```

Image resources use `sampled_image` / `storage_image`; buffer-dimensional images
use `uniform_texel_buffer` / `storage_texel_buffer`, respectively. Their type can
be the numeric texel element type or `resourceHandle[KIND, TYPE]`. Shape belongs
to the image operation, not the resource handle. Texel-buffer fetches do not use
a sampler, including combined SPIR-V `samplerBuffer` declarations.

The declaration `TYPE` is the storage buffer's block or payload aggregate type;
it does not constrain the type of each byte-addressed access. Both operations
accept storage buffers, and byte offsets must have a scalar unsigned integer
type. Access values may be integer or floating-point scalars or vectors thereof.

```text
%value: u32 = load_buffer @data, %offset
store_buffer @data, %offset, %value
```

## Workgroup variables

Workgroup variables are module-level declarations, distinct from resources. The
printer emits them after the resource declarations and before the constant
declarations:

```text
@name: TYPE = workgroup[]
```

`TYPE` is the variable's declared storage type (for example, `array[u32, 8]`);
it does not constrain the type of each byte-addressed access, just as a
resource's aggregate type does not. `load_workgroup` and `store_workgroup` are
the only operations that use them.

## Constants

Constants live at module scope and also have ordinary numeric or named `%id` value identities.
The parser accepts direct decimal integer and floating-point values, including
signed values and floating-point exponents, as source-level convenience syntax:

```text
%0: constant u32 = 42
%1: constant i32 = -7
%2: constant f32 = 1.5e2
```

Direct integers must fit their declared width and signedness. Direct floats are
rounded to their declared `f16`, `f32`, or `f64` representation. The canonical
printer always emits integer and float bit patterns so reparsing cannot silently
change the stored value.

```text
%id: constant <type> = <value>
```

| Form         | Meaning                             | Printed example                         |
| ------------ | ----------------------------------- | --------------------------------------- |
| Boolean      | `true` or `false`                   | `%0: constant bool = true`              |
| Integer bits | The fixed-width integer bit pattern | `%1: constant u32 = bits(0x2a)`         |
| Float bits   | The IEEE-like bit pattern as stored | `%2: constant f32 = bits(0x3f800000)`   |
| Null         | The null value of its type          | `%3: constant ptr[private, u32] = null` |
| Undef        | An unconstrained value              | `%4: constant u32 = undef`              |
| Composite    | A sequence of other constants       | `%5: constant vec2[u32] = [#1, #1]`     |

## Functions, blocks, and SSA

A function owns typed parameters, an ordered list of blocks, one entry block,
and one return type. The first block created by the builder becomes the entry
block. The validator requires the entry block to have no predecessor.

Every block must end in exactly one terminator. A value defined by an instruction
must dominate every use, and within one block it must be written before it is
used. Constants and standalone undef values are module-wide; function and block
parameters cannot be used by another function.

### Block parameters and Phi lowering

A merge block does not contain a `phi` instruction. Instead, it declares a
parameter, and every incoming edge passes one argument of the same type:

```text
.left():
    branch .merge(%3)

.right():
    branch .merge(%4)

.merge(%5: u32):
    %6: u32 = integer_multiply %5, %2
    return
```

`%5` therefore receives the value supplied by the selected edge. The number and
types of edge arguments must exactly match the target block's parameters.

### Structured control

A block may carry one of these unprinted metadata values:

- `none`: no structured-control promise.
- `selection`: names one merge block.
- `loop`: names both merge and continue blocks.

The SPIR-V translator preserves `OpSelectionMerge` and `OpLoopMerge` in this
metadata. They are not terminators and do not create graph edges themselves.

## Common instruction rules

An instruction belongs to one block, has zero or one result, and may carry a
source location. Except for `store_interface`, `store_buffer`, `store_workgroup`,
`image_write`, `control_barrier`, and `call`, current operations are treated as
side-effect free by the rewriter. A block's terminator is stored separately from
its ordinary instructions.

Most arithmetic operations are intended for scalars or vectors of their named
category and act component by component where vectors are allowed. The validator
checks the integer, float, boolean, bit-width, aggregate, and vector or matrix
shape requirements described below. Any intentionally weaker checks are called
out in the relevant opcode section.

## Unary opcodes

Form:

```text
%result: <type> = <opcode> %operand
```

| Opcode        | Description                                                        | Usage                                                                     | Small printed example            |
| ------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------- | -------------------------------- |
| `absolute`    | Computes the floating-point absolute value component-wise.         | Floating scalar or vector; the result has the same type.                  | `%2: f32 = absolute %1`          |
| `acos`        | Computes the arc cosine in radians component-wise.                 | Floating scalar or vector; the result has the same type.                  | `%2: f32 = acos %1`              |
| `acosh`       | Computes the inverse hyperbolic cosine component-wise.             | Floating scalar or vector; the result has the same type.                  | `%2: f32 = acosh %1`             |
| `all`         | True when all components of the operand are true.                  | Boolean vector operand; scalar boolean result.                            | `%2: bool = all %1`              |
| `any`         | True when any component of the operand is true.                    | Boolean vector operand; scalar boolean result.                            | `%2: bool = any %1`              |
| `asin`        | Computes the arc sine in radians component-wise.                   | Floating scalar or vector; the result has the same type.                  | `%2: f32 = asin %1`              |
| `asinh`       | Computes the inverse hyperbolic sine component-wise.               | Floating scalar or vector; the result has the same type.                  | `%2: f32 = asinh %1`             |
| `atan`        | Computes the arc tangent in radians component-wise.                | Floating scalar or vector; the result has the same type.                  | `%2: f32 = atan %1`              |
| `atanh`       | Computes the inverse hyperbolic tangent component-wise.            | Floating scalar or vector; the result has the same type.                  | `%2: f32 = atanh %1`             |
| `bit_count`   | Counts the set bits in each component.                             | Integer scalar or vector; result has the same width and shape.            | `%2: u32 = bit_count %1`         |
| `bit_reverse` | Reverses the bits in each component.                               | Integer scalar or vector; result has the same width and shape.            | `%2: u32 = bit_reverse %1`       |
| `bitwise_not` | Inverts every bit.                                                 | Integer scalar or vector; result has the same width and shape.            | `%2: u32 = bitwise_not %1`       |
| `ceil`        | Rounds each component toward positive infinity.                    | Floating scalar or vector; the result has the same type.                  | `%2: f32 = ceil %1`              |
| `cos`         | Computes the cosine of an angle in radians component-wise.         | Floating scalar or vector; the result has the same type.                  | `%2: vec3[f32] = cos %1`         |
| `cosh`        | Computes the hyperbolic cosine component-wise.                     | Floating scalar or vector; the result has the same type.                  | `%2: f32 = cosh %1`              |
| `d_pdx`       | Computes the partial derivative with respect to screen x.          | Fragment-only floating scalar or vector; result has the same type.        | `%2: f32 = d_pdx %1`             |
| `d_pdy`       | Computes the partial derivative with respect to screen y.          | Fragment-only floating scalar or vector; result has the same type.        | `%2: vec3[f32] = d_pdy %1`       |
| `exp`         | Computes the natural exponential component-wise.                   | Floating scalar or vector; the result has the same type.                  | `%2: f32 = exp %1`               |
| `exp2`        | Computes the base-two exponential component-wise.                  | Floating scalar or vector; the result has the same type.                  | `%2: f32 = exp2 %1`              |
| `floor`       | Rounds each component toward negative infinity.                    | Floating scalar or vector; the result has the same type.                  | `%2: f32 = floor %1`             |
| `fwidth`      | Computes `abs(dFdx(x)) + abs(dFdy(x))` component-wise.             | Fragment-only floating scalar or vector; result has the same type.        | `%2: vec3[f32] = fwidth %1`      |
| `is_inf`      | Tests each component for positive or negative infinity.            | Floating scalar or vector; result is a matching boolean scalar or vector. | `%2: bool = is_inf %1`           |
| `is_nan`      | Tests each component for NaN.                                      | Floating scalar or vector; result is a matching boolean scalar or vector. | `%2: vec4[bool] = is_nan %1`     |
| `length`      | Computes a vector's Euclidean length or a scalar's absolute value. | Floating scalar or vector; result is the scalar element type.             | `%2: f32 = length %1`            |
| `log`         | Computes the natural logarithm component-wise.                     | Floating scalar or vector; the result has the same type.                  | `%2: f32 = log %1`               |
| `log2`        | Computes the base-two logarithm component-wise.                    | Floating scalar or vector; the result has the same type.                  | `%2: f32 = log2 %1`              |
| `logical_not` | Inverts each boolean component.                                    | Boolean scalar or vector; the result has the same type.                   | `%2: bool = logical_not %1`      |
| `negate`      | Changes the arithmetic sign.                                       | Signed integer or floating operand; the result has the same type.         | `%2: i32 = negate %1`            |
| `normalize`   | Produces a floating value with unit length.                        | Floating scalar or vector; the result has the same type.                  | `%2: vec3[f32] = normalize %1`   |
| `round`       | Rounds each component to the nearest integer.                      | Floating scalar or vector; the result has the same type.                  | `%2: f32 = round %1`             |
| `sign`        | Produces -1, 0, or 1 according to the operand's sign.              | Floating scalar or vector; the result has the same type.                  | `%2: vec3[f32] = sign %1`        |
| `sin`         | Computes the sine of an angle in radians component-wise.           | Floating scalar or vector; the result has the same type.                  | `%2: vec3[f32] = sin %1`         |
| `sinh`        | Computes the hyperbolic sine component-wise.                       | Floating scalar or vector; the result has the same type.                  | `%2: f32 = sinh %1`              |
| `tan`         | Computes the tangent of an angle in radians component-wise.        | Floating scalar or vector; the result has the same type.                  | `%2: vec3[f32] = tan %1`         |
| `tanh`        | Computes the hyperbolic tangent component-wise.                    | Floating scalar or vector; the result has the same type.                  | `%2: f32 = tanh %1`              |
| `transpose`   | Exchanges the rows and columns of a floating-point matrix.         | Floating matrix; result has reversed row and column counts.               | `%2: mat2x3[f32] = transpose %1` |

`length` accepts a floating scalar or vector and returns the scalar element type
(with matching precision); scalar length is the absolute value. `fwidth` accepts a
floating scalar or vector, preserves its type, and is fragment-only. It represents
`abs(dFdx(x)) + abs(dFdy(x))` with the default derivative granularity.
`d_pdx` and `d_pdy` preserve the floating scalar/vector operand type and use the
same fragment-only restriction. They represent `OpDPdx` and `OpDPdy` with default
(implementation-selected fine or coarse) derivative granularity, not explicit
fine/coarse derivatives. Their result type may be omitted in textual IR and is
inferred from the operand. Frontend/IR support does not imply backend execution
support; Intel common-IR lowering explicitly rejects these derivative operations.

`negate` is one normalized opcode: the operand type distinguishes integer
negation from floating negation. Unary integer and floating operations apply
component-wise when their operand is a vector.

## Binary opcodes

Form:

```text
%result: <type> = <opcode> %lhs, %rhs
```

Most binary operations require equal operand and result types. Product operations,
extended integer operations, and operations that reduce vectors or construct matrices
have the specialized type rules described below.

### Integer arithmetic

| Opcode                       | Description                                             | Usage                                                                       | Small printed example                                      |
| ---------------------------- | ------------------------------------------------------- | --------------------------------------------------------------------------- | ---------------------------------------------------------- |
| `integer_add`                | Adds fixed-width integers.                              | Integer operands of one type.                                               | `%3: u32 = integer_add %1, %2`                             |
| `integer_subtract`           | Subtracts the right operand from the left.              | Integer operands of one type.                                               | `%3: u32 = integer_subtract %1, %2`                        |
| `integer_multiply`           | Multiplies fixed-width integers.                        | Integer operands of one type.                                               | `%3: u32 = integer_multiply %1, %2`                        |
| `integer_add_carry`          | Returns the low sum and unsigned carry.                 | Equal unsigned operands; result is `struct[T, T]`.                          | `%3: struct[u32, u32] = integer_add_carry %1, %2`          |
| `integer_subtract_borrow`    | Returns the low difference and unsigned borrow.         | Equal unsigned operands; result is `struct[T, T]`.                          | `%3: struct[u32, u32] = integer_subtract_borrow %1, %2`    |
| `unsigned_multiply_extended` | Returns the low and high halves of an unsigned product. | Equal unsigned operands; result is `struct[T, T]`.                          | `%3: struct[u32, u32] = unsigned_multiply_extended %1, %2` |
| `signed_multiply_extended`   | Returns the low and high halves of a signed product.    | Equal signed operands; result is `struct[T, T]`.                            | `%3: struct[i32, i32] = signed_multiply_extended %1, %2`   |
| `unsigned_divide`            | Divides unsigned integers.                              | Unsigned integer operands.                                                  | `%3: u32 = unsigned_divide %1, %2`                         |
| `signed_divide`              | Divides signed integers.                                | Signed integer operands.                                                    | `%3: i32 = signed_divide %1, %2`                           |
| `unsigned_modulo`            | Produces the unsigned remainder.                        | Unsigned integer operands.                                                  | `%3: u32 = unsigned_modulo %1, %2`                         |
| `signed_modulo`              | Produces signed modulo, whose sign follows the divisor. | Signed integer operands; this corresponds to SPIR-V `OpSMod`, not `OpSRem`. | `%3: i32 = signed_modulo %1, %2`                           |
| `unsigned_min`               | Selects the smaller unsigned value component-wise.      | Equal unsigned integer scalars or vectors; same result type.                | `%3: vec3[u32] = unsigned_min %1, %2`                      |
| `unsigned_max`               | Selects the greater unsigned value component-wise.      | Equal unsigned integer scalars or vectors; same result type.                | `%3: vec3[u32] = unsigned_max %1, %2`                      |

`unsigned_min` and `unsigned_max` map GLSL.std.450 `UMin` and `UMax`.
Their intended operands are unsigned integer scalars or vectors, but the current
validator only checks that both operands and the result have the same type; it
does not yet enforce the unsigned integer category for these two opcodes.

Integer addition, subtraction, and multiplication are signedness-neutral at the
opcode level; the type retains signedness. Exceptional division, overflow,
and poison rules are not yet separately recorded by the IR.

### Floating arithmetic

| Opcode            | Description                                             | Usage                                                                     | Small printed example              |
| ----------------- | ------------------------------------------------------- | ------------------------------------------------------------------------- | ---------------------------------- |
| `float_add`       | Adds floating-point values.                             | Floating operands of one type.                                            | `%3: f32 = float_add %1, %2`       |
| `float_subtract`  | Subtracts the right operand from the left.              | Floating operands of one type.                                            | `%3: f32 = float_subtract %1, %2`  |
| `float_multiply`  | Multiplies floating-point values.                       | Floating operands of one type.                                            | `%3: f32 = float_multiply %1, %2`  |
| `float_divide`    | Divides the left operand by the right.                  | Floating operands of one type.                                            | `%3: f32 = float_divide %1, %2`    |
| `float_min`       | Selects the smaller operand component-wise.             | Floating operands of one type; maps GLSL.std.450 `FMin`.                  | `%3: f32 = float_min %1, %2`       |
| `float_max`       | Selects the greater operand component-wise.             | Floating operands of one type; maps GLSL.std.450 `FMax`.                  | `%3: f32 = float_max %1, %2`       |
| `float_modulo`    | Produces `x - y * floor(x / y)`.                        | Floating operands of one type; this corresponds to SPIR-V `OpFMod`.       | `%3: f32 = float_modulo %1, %2`    |
| `float_remainder` | Produces `x - y * trunc(x / y)`.                        | Floating operands of one type; this corresponds to SPIR-V `OpFRem`.       | `%3: f32 = float_remainder %1, %2` |
| `atan2`           | Computes the quadrant-aware arc tangent of `lhs / rhs`. | Floating operands of one type; maps GLSL.std.450 `Atan2`.                 | `%3: f32 = atan2 %1, %2`           |
| `pow`             | Raises the left operand to the power of the right.      | Floating operands of one type; maps GLSL.std.450 `Pow`.                   | `%3: f32 = pow %1, %2`             |
| `step`            | Returns 0 if `rhs < lhs`, otherwise 1, component-wise.  | Equal floating scalars or vectors; `lhs` is the edge and `rhs` the value. | `%3: vec3[f32] = step %1, %2`      |

`step` maps GLSL.std.450 `Step`. The frontend requires both operands and the
result to have the same type; scalar-edge broadcasting is not represented by
this opcode. The current validator checks type equality but does not yet enforce
the floating scalar/vector category for `step`.

Instructions do not yet carry fast-math flags, rounding modes, contraction
permission, or NaN guarantees.

### Vector arithmetic

| Opcode                   | Description                                       | Usage                                                                                   | Small printed example                        |
| ------------------------ | ------------------------------------------------- | --------------------------------------------------------------------------------------- | -------------------------------------------- |
| `vector_times_scalar`    | Multiplies a vector by a scalar.                  | Floating vector and matching scalar; result has the vector type.                        | `%3: vec4[f32] = vector_times_scalar %1, %2` |
| `vector_times_matrix`    | Multiplies a row vector by a matrix.              | Compatible floating vector and matrix dimensions.                                       | `%3: vec4[f32] = vector_times_matrix %1, %2` |
| `dot`                    | Computes the dot product of two vectors.          | Equal floating vectors; result is their scalar element type.                            | `%3: f32 = dot %1, %2`                       |
| `vector_extract_dynamic` | Selects a vector component using a runtime index. | Floating, integer, or boolean vector and a scalar integer index; scalar element result. | `%3: f32 = vector_extract_dynamic %1, %2`    |

`vector_extract_dynamic` takes a vector and a scalar signed or unsigned integer
index and returns the vector's scalar element type. It supports floating, integer,
and boolean vectors; it does not accept matrices. An out-of-range index has an
undefined result, matching SPIR-V `OpVectorExtractDynamic`.

GLSL.std.450 `Length` maps directly to unary `length`. `FClamp` lowers to
`float_max(x, min)` followed by `float_min(lower, max)`; all three operands and the
result must have the same floating scalar or vector type.

GLSL.std.450 `Cross` has no standalone IR opcode. For matching three-component
floating vectors `a` and `b`, it constructs
`(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x)` using
`composite_extract`, `float_multiply`, `float_subtract`, and
`composite_construct`, retaining the vectors' scalar precision.

### Matrix arithmetic

| Opcode                | Description                                        | Usage                                                 | Small printed example                          |
| --------------------- | -------------------------------------------------- | ----------------------------------------------------- | ---------------------------------------------- |
| `matrix_times_matrix` | Multiplies compatible floating-point matrices.     | Inner dimensions and scalar element types must match. | `%3: mat4x4[f32] = matrix_times_matrix %1, %2` |
| `matrix_times_scalar` | Multiplies every matrix element by a scalar.       | Floating matrix and matching scalar.                  | `%3: mat4x4[f32] = matrix_times_scalar %1, %2` |
| `matrix_times_vector` | Multiplies a matrix by a compatible column vector. | Floating matrix and vector with matching dimensions.  | `%3: vec4[f32] = matrix_times_vector %1, %2`   |
| `outer_product`       | Constructs a matrix from two vectors' products.    | Floating vectors with a shared scalar element type.   | `%3: mat3x2[f32] = outer_product %1, %2`       |

### Shifts and bitwise arithmetic

| Opcode                   | Description                                        | Usage                                                         | Small printed example                     |
| ------------------------ | -------------------------------------------------- | ------------------------------------------------------------- | ----------------------------------------- |
| `shift_left`             | Shifts bits left and fills the low bits with zero. | Integer operands; the right operand supplies the shift count. | `%3: u32 = shift_left %1, %2`             |
| `logical_shift_right`    | Shifts right and fills high bits with zero.        | Integer operands interpreted without sign extension.          | `%3: u32 = logical_shift_right %1, %2`    |
| `arithmetic_shift_right` | Shifts right while repeating the sign bit.         | Signed integer value and integer shift count.                 | `%3: i32 = arithmetic_shift_right %1, %2` |
| `bitwise_and`            | Keeps bits set in both operands.                   | Integer operands of one type.                                 | `%3: u32 = bitwise_and %1, %2`            |
| `bitwise_or`             | Keeps bits set in either operand.                  | Integer operands of one type.                                 | `%3: u32 = bitwise_or %1, %2`             |
| `bitwise_xor`            | Keeps bits set in exactly one operand.             | Integer operands of one type.                                 | `%3: u32 = bitwise_xor %1, %2`            |

The validator currently requires the shift count to have the same complete IR
type as the shifted value. More flexible shift typing is not implemented yet.

### Boolean conjunction

| Opcode        | Description                               | Usage                        | Small printed example           |
| ------------- | ----------------------------------------- | ---------------------------- | ------------------------------- |
| `logical_and` | Is true only when both operands are true. | Boolean operands and result. | `%3: bool = logical_and %1, %2` |
| `logical_or`  | Is true when either operand is true.      | Boolean operands and result. | `%3: bool = logical_or %1, %2`  |

## Ternary opcodes

Form:

```text
%result: <type> = <opcode> %first, %second, %third
```

| Opcode          | Description                                                     | Usage                                                      | Small printed example                  |
| --------------- | --------------------------------------------------------------- | ---------------------------------------------------------- | -------------------------------------- |
| `float_mix`     | Computes `first * (1 - third) + second * third` component-wise. | Three equal floating scalars or vectors; same result type. | `%4: vec3[f32] = float_mix %1, %2, %3` |
| `float_mul_add` | Computes fused `first * second + third` component-wise.         | Three equal floating scalars or vectors; same result type. | `%4: f32 = float_mul_add %1, %2, %3`   |
| `smooth_step`   | Performs Hermite interpolation from edge 0 through edge 1.      | Three equal floating scalars or vectors; same result type. | `%4: f32 = smooth_step %1, %2, %3`     |

These map GLSL.std.450 `FMix`, `Fma`, and `SmoothStep`, respectively.
For `float_mix`, the third operand is a floating interpolation weight, not a
boolean selector. For `smooth_step`, operands are `(edge0, edge1, x)`.
All three opcodes require matching types without implicit scalar broadcasting;
`float_mul_add` explicitly requests a fused operation rather than separate
multiplication and addition.

## Comparison opcodes

All comparisons are printed with the `cmp_` prefix as one opcode token:

```text
%result: <bool-or-bool-vector> = cmp_<opcode> %lhs, %rhs
```

The operands must share one type. Scalar comparisons produce `bool`; vector
comparisons produce a boolean vector with the same component count.

| Opcode                          | Description                                                    | Usage                                    | Small printed example                             |
| ------------------------------- | -------------------------------------------------------------- | ---------------------------------------- | ------------------------------------------------- |
| `cmp_equal`                     | Tests whether two booleans or integers are equal.              | Equal-typed boolean or integer operands. | `%3: bool = cmp_equal %1, %2`                     |
| `cmp_not_equal`                 | Tests whether two booleans or integers differ.                 | Equal-typed boolean or integer operands. | `%3: bool = cmp_not_equal %1, %2`                 |
| `cmp_unsigned_less`             | Compares integer bit patterns as unsigned.                     | Unsigned integer operands.               | `%3: bool = cmp_unsigned_less %1, %2`             |
| `cmp_signed_less`               | Compares integers as signed.                                   | Signed integer operands.                 | `%3: bool = cmp_signed_less %1, %2`               |
| `cmp_ordered_float_equal`       | Is true when neither operand is NaN and they are equal.        | Floating operands.                       | `%3: bool = cmp_ordered_float_equal %1, %2`       |
| `cmp_unordered_float_equal`     | Is true when either operand is NaN, or they are equal.         | Floating operands.                       | `%3: bool = cmp_unordered_float_equal %1, %2`     |
| `cmp_ordered_float_not_equal`   | Is true when neither operand is NaN and they differ.           | Floating operands.                       | `%3: bool = cmp_ordered_float_not_equal %1, %2`   |
| `cmp_unordered_float_not_equal` | Is true when either operand is NaN, or they differ.            | Floating operands.                       | `%3: bool = cmp_unordered_float_not_equal %1, %2` |
| `cmp_ordered_float_less`        | Is true when neither operand is NaN and left is less.          | Floating operands.                       | `%3: bool = cmp_ordered_float_less %1, %2`        |
| `cmp_ordered_float_less_equal`  | Is true when neither operand is NaN and left is at most right. | Floating operands.                       | `%3: bool = cmp_ordered_float_less_equal %1, %2`  |
| `cmp_unordered_float_less`      | Is true when either operand is NaN, or left is less.           | Floating operands.                       | `%3: bool = cmp_unordered_float_less %1, %2`      |

There are no greater-than opcodes in the current instruction set. Swap the
operands and use the appropriate less-than form.

## Other opcodes

### `bit_field_extract`

Extracts a contiguous bit range and either sign-extends or zero-extends it as
selected by the `signed` or `unsigned` variant. The offset and count are integer
scalars; the base and result are integer scalars or vectors with equal width and
shape.

```text
%4: i32 = bit_field_extract signed %1, %2, %3
```

### `bit_field_insert`

Replaces a contiguous bit range in the base value. The base and inserted value
are integer scalars or vectors with equal width and shape; offset and count are
integer scalars.

```text
%5: u32 = bit_field_insert %1, %2, %3, %4
```

### `select`

Selects one of two equal-typed values using a boolean condition. It does not
change control flow.

```text
%4: u32 = select %1, %2, %3
```

Here `%1` is `bool`; `%2`, `%3`, and `%4` share one type.

### `bitcast`

Reinterprets an operand's bits as the result type without performing a numeric
conversion.

```text
%2: f32 = bitcast %1
```

The intended source and destination have equal total bit width. The current
validator only requires that both values exist; it does not yet prove equal
width.

### `convert`

Performs numeric conversion between 32-bit floating-point and integer values.
The variants are `signed_to_float`, `unsigned_to_float`, `float_to_signed`, and
`float_to_unsigned`.

```text
%2: f32 = convert signed_to_float %1
%4: u32 = convert float_to_unsigned %3
```

The operand and result are scalars or vectors with equal component counts. The
integer side must be `i32` or `u32` as selected by the variant, and the floating
side must be `f32`. Floating-point values outside the destination integer's
representable range have unspecified conversion results rather than trapping.

### `composite_construct`

Constructs a vector, matrix, array, or structure from its immediate elements.

```text
%5: vec4[f32] = composite_construct %1, %2, %3, %4
```

For a vector or array, every element must have the composite's element type and
their count must equal its length. For a matrix, all elements must have its column
vector type and their count must equal its column count. For a structure, each
element must match the member at the same position.

### `composite_extract`

Traverses one or more literal indices through a vector, array, or structure and
returns the selected nested member.

```text
%4: f32 = composite_extract %3[1][0]
```

At least one index is required. Every index must lie within its composite, and
the result type must equal the selected member type.

### `load_interface`

Reads one declared shader input. It cannot read an output declaration.

```text
%1: vec4[f32] = load_interface @in_color
%2: vec4[f32] = load_interface @in_color, element_index %index
```

The optional dynamic `element_index` for arrayed interfaces is printed as a
trailing `, element_index %index` operand. When it is null, the printer omits
that operand and preserves the unindexed syntax.

The result type must equal the interface variable's type. The current validator
does not use `element_index` to change the result type.

### `store_interface`

Writes one declared shader output. It produces no SSA result and cannot write an
input declaration.

```text
store_interface @out_color, %1
store_interface @out_color, %1, element_index %index
```

As with `load_interface`, the optional dynamic `element_index` for arrayed
interfaces is printed after the value as `, element_index %index`. When it is
null, the printer preserves the unindexed syntax.

The stored value must equal the interface variable's type; the current validator
does not use `element_index` to change that requirement. This operation has side
effects.

### `load_push_constant`

Reads a value from the push-constant region at an explicit byte offset.

```text
%value: u32 = load_push_constant %offset
```

The byte offset must be a scalar unsigned integer. The result must be an
integer or floating-point scalar, or a vector of such values. This operation
is side-effect free.

### `load_buffer`

Reads a numeric scalar or vector at an explicit byte offset. The resource must
be a storage buffer, the byte offset must be a scalar unsigned integer, and the
instruction must have a result. The result type is independent of the resource's
block or payload aggregate type.

```text
%value: u32 = load_buffer @data, %offset
```

### `store_buffer`

Writes a numeric scalar or vector to a storage buffer at an explicit byte
offset. It produces no SSA result, and both the unsigned integer offset and
stored value are ordinary value uses. The value type is independent of the
resource's block or payload aggregate type. This operation has side effects.

```text
store_buffer @data, %offset, %value
```

### `load_workgroup`

Reads a numeric scalar or vector from a declared workgroup variable at an
explicit byte offset.

```text
%value: u32 = load_workgroup @data, %offset
```

The byte offset must be a scalar unsigned integer. The result must be an
integer or floating-point scalar, or a vector of such values.

### `store_workgroup`

Writes a numeric scalar or vector to a declared workgroup variable at an
explicit byte offset. It produces no SSA result, and the value type is
independent of the variable's declared type. This operation has side effects.

```text
store_workgroup @data, %offset, %value
```

### `image_read`

Reads a value from a storage image at a coordinate.

```text
%value: vec4[f32] = image_read @img, %coord
```

The resource must be a `storage_image`, or `storage_texel_buffer` when
`dimension buffer` is specified. An optional suffix preserves image shape:

```text
%value: vec4[f32] = image_read @img, %coord, dimension one_d, arrayed true
```

The omitted suffix means `dimension two_d, arrayed false`; the printer preserves
the old unsuffixed form for this default. The SPIR-V frontend requires integer32
texel coordinates and retains the consumed coordinate prefix without numeric
conversion, ignoring any extra components allowed by SPIR-V. Storage cube reads and writes, both arrayed and
non-arrayed, require exactly three `i32` or `u32` coordinates `(x, y, z)`. Here z
is the view-relative face/layer index: a face in `[0, 6)` for a non-arrayed cube,
or the combined face/layer for a cube array. There is no fourth coordinate and
no compiler-side face/layer splitting. Coordinate bounds are a runtime concern;
the validator checks the cube coordinate type and width. This differs from
sampled cube arrays, which use four floating-point components.

For compatibility with old IR, other storage shapes still check coordinate
existence rather than imposing new coordinate/result type restrictions on
reads/writes. Arrayed 3D images and arrayed buffers are rejected.

### `image_fetch`

Performs an unfiltered, integer-coordinate lookup without a sampler:

```text
%value: vec4[f32] = image_fetch @img, %coord, lod %lod, dimension two_d, arrayed false
%texel: vec4[u32] = image_fetch @buffer, %index, dimension buffer, arrayed false
```

Non-buffer fetches require a `sampled_image` and a scalar `i32`/`u32` LOD.
Buffer fetches require a `uniform_texel_buffer` and forbid LOD. Coordinates use
32-bit signed or unsigned integer components: one for 1D/buffer, two for 2D,
three for 3D, plus one array-layer component for arrayed 1D/2D images. The result
must be a numeric four-component vector whose element type matches the resource's
image data type. Cube fetches, arrayed 3D/buffer shapes, and multisampling are
unsupported. This is a compiler IR contract, not a backend support guarantee.

### `image_sample_explicit_lod`

Samples a sampled image through a sampler at an explicit level of detail.

```text
%value: vec4[f32] = image_sample_explicit_lod @img, @sampler, %coord, %lod, dimension two_d, arrayed false
```

The image must be a `sampled_image` resource and the sampler a `sampler`
resource. The coordinate is a float vector with one component per image
dimension, plus one more when `arrayed` is true. The level of detail is an
`f32` value. The result is a four-component float vector; if the image carries
a data type, its element type must match. The `dimension` is one of
`one_d`, `two_d`, `three_d`, or `cube`. Sampling and gathering reject `buffer`.
For compatibility, sampling IR validation still accepts arrayed 3D shapes with
four-component coordinates; storage/fetch validation and the SPIR-V frontend
reject arrayed 3D images.

### `image_sample_implicit_lod`

Samples a sampled image through a sampler using an implicit level of detail.

```text
%value: vec4[f32] = image_sample_implicit_lod @img, @sampler, %coord, dimension two_d, arrayed false
```

The same rules as `image_sample_explicit_lod` apply, except no level-of-detail
operand is supplied.

### `image_gather`

Gathers one selected color component from four neighboring texels of a sampled
image through a sampler. The result's four components are samples from four
texels, not the RGBA components of one texel.

```text
%value: vec4[f32] = image_gather @img, @sampler, %coord, %component, dimension two_d, arrayed false
```

The image and sampler resource rules are the same as for
`image_sample_explicit_lod`. The coordinate uses `f32` components matching the
image dimension and optional array layer. The component selector is a scalar
32-bit signed or unsigned integer selecting color component 0 through 3, and the
result is a four-component vector with the image's sampled element type. The
validator checks the selector's type, but not its value range.

The current SPIR-V frontend and software interpreter support only non-arrayed 2D
gathers without optional image operands. The IR carries `dimension` and `arrayed`
fields, but their presence does not imply support for other gather forms.

### `image_write`

Writes a value to a storage image at a coordinate. It produces no SSA result.
The resource must be a `storage_image`, or a `storage_texel_buffer` for
`dimension buffer`. This operation has side effects. It accepts the same optional
`dimension ..., arrayed ...` suffix and defaults as `image_read`.

```text
image_write @img, %coord, %value
```

### `control_barrier`

Performs a memory barrier between workgroup threads. It takes no operands and
produces no result. This operation has side effects and is only allowed in a
compute shader.

```text
control_barrier
```

### `call`

Invokes another IR function. Arguments must match the callee's parameters in
number, order, and type.

```text
%4: vec4[f32] = call @shade(%1, %2)
call @observe(%4)
```

A non-void callee requires a result of its return type; a void callee forbids
one. Calls are conservatively treated as side-effecting. The operation exists in
the common IR, although the current SPIR-V translator rejects
`OpFunctionCall`.

### `array_length`

Computes the number of elements in a storage buffer from an explicit byte
offset.

```text
%count: u32 = array_length @arr, %offset, stride 4
```

The resource must be a `storage_buffer`. The byte offset must be a scalar
unsigned integer, `stride` is a literal element size in bytes (non-zero), and
the result must be `u32` or `u64`. An optional `descriptor_index` operand, like
`load_buffer` and `store_buffer`, must be a scalar unsigned integer when
present.

## Terminators

Terminators yield no ordinary instruction result. They alone determine outgoing
control-flow edges.

| Terminator           | Description                                     | Usage                                                                           | Small printed example                      |
| -------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------ |
| `branch`             | Unconditionally transfers control to one block. | Pass exactly one argument for every target parameter.                           | `branch .merge(%3)`                        |
| `conditional_branch` | Selects one of two edges using a boolean.       | The condition is `bool`; each edge independently matches its target parameters. | `conditional_branch %1, .yes(%2), .no(%3)` |
| `return` (void)      | Ends a void function.                           | The enclosing return type is `void`.                                            | `return`                                   |
| `return` (value)     | Ends a function and returns a value.            | The value type equals the function return type.                                 | `return %3`                                |
| `discard`            | Discards the fragment invocation.               | Fragment stage only.                                                            | `discard`                                  |
| `unreachable`        | States that execution cannot reach this point.  | Any function; no successors.                                                    | `unreachable`                              |

The Zig union names the return forms `return_void` and `return_value`; the
printer renders both as the overloaded `return` spelling shown above.

## Interfaces and builtins

An interface variable has a type, a direction (`input` or `output`), and one
semantic. Its semantic attributes are enclosed in the direction's brackets:

- A location: `location(N), component(C), index(I)`.
- A builtin: `builtin(name)`.

The currently supported builtins are `position`, `vertex_index`, `instance_index`,
`frag_coord`, `frag_depth`, and `global_invocation_id`.

Printed declarations resemble these:

```text
@in_color: vec4[f32] = input[location(0), component(0), index(0)]
@position: vec4[f32] = output[builtin(position)]
```

## Complete examples

These examples use the printer's exact grammar and indentation. Their numeric
value IDs are illustrative but follow the same module-wide numbering used by
the printer.

### A compute shader that adds two constants

```text
shader compute @main
{
    %0: constant u32 = bits(0x1)
    %1: constant u32 = bits(0x2)

    fn @main() -> void
    {
        .entry():
            %2: u32 = integer_add %0, %1
            return

    }
}
```

### A vertex interface passed through

```text
shader vertex @main
{
    @in_color: vec4[f32] = input[location(0), component(0), index(0)]
    @out_color: vec4[f32] = output[location(0), component(0), index(0)]

    fn @main() -> void
    {
        .entry():
            %0: vec4[f32] = load_interface @in_color
            store_interface @out_color, %0
            return

    }
}
```

### A selection whose Phi becomes a block parameter

```text
shader compute @main
{
    %0: constant bool = true
    %1: constant u32 = bits(0x1)
    %2: constant u32 = bits(0x2)

    fn @main() -> void
    {
        .entry():
            conditional_branch %0, .left(), .right()

        .left():
            %3: u32 = integer_add %1, %2
            branch .merge(%3)

        .right():
            %4: u32 = integer_subtract %2, %1
            branch .merge(%4)

        .merge(%5: u32):
            %6: u32 = integer_multiply %5, %2
            return

    }
}
```

The selection's merge metadata is not visible in this output, although it
remains attached to `.entry` in memory.

## Validator guarantees

When `validator.validate` succeeds, it has proved the following:

- The module has a live entry point.
- All referenced types, constants, values, functions, blocks, and instructions
  are live.
- Parent links and SSA definition links agree in both directions.
- Every function has an entry block, and no edge targets that entry block.
- Every block has a terminator.
- Edges remain within their function and exactly match target block parameters.
- Returns agree with function return types; `discard` appears only in a fragment shader.
- Interface loads read inputs; interface stores write outputs.
- Operation-specific result presence and the foundational type equalities hold.
- Structured merge and continue targets belong to the same function.

The validator does not yet prove every semantic category listed in the opcode
reference. In particular, several arithmetic opcodes can currently be built
with an inappropriate but equal operand type; bitcast widths are not compared;
shift-count rules are rudimentary; and floating-point execution modes are not
attached to operations. Backends should explicitly require the properties and
validation needed by their lowering.

## Properties and passes

The module carries independent property bits:

- `valid_cfg`
- `valid_ssa`
- `structured_control_flow`
- `no_function_calls`
- `no_local_memory`
- `no_matrix_types`
- `no_large_composites`
- `explicit_resource_offsets`

A pass declares properties that it requires, produces, and invalidates. The pass
manager rejects a pass whose requirements are missing, applies its property
changes, and runs the validator after every pass by default.

## Builder, rewriter, and visitor

`Builder.zig` is the normal entry point for construction. It interns types and
constants, stores copied slices in the module arena, adds functions and blocks,
appends instructions, and assigns block terminators.

`parser/root.zig` owns the public parsing entry points and recursive-descent grammar.
Its implementation details are split by responsibility: `parser/Lexer.zig`
tokenizes input, `parser/ast.zig` holds the temporary syntax model, and
`parser/lower.zig` resolves that model into the common IR.

`Rewriter.zig` provides the first safe mutation operations:

- Count and replace SSA uses without changing definitions.
- Erase a dead, side-effect-free instruction.
- Redirect edges with a complete new argument list.
- Add a block parameter while adding every incoming edge argument.
- Remove a block parameter while removing its incoming arguments.

`visitor.zig` walks module declarations, functions, blocks, instructions,
terminators, and SSA uses in hierarchical order. `cfg.zig` computes
predecessors, reachability, and dominance with a deliberately simple quadratic
matrix. `validator/dominance.zig` contains the SSA dominance checks built on
that analysis. This is suitable for the foundation but is not intended as the
final large-shader implementation.

## SPIR-V frontend

The compiler currently provides a word parser, an owned `SourceModule`, and an
initial translator in `spirv/`. The parser validates the header, word counts,
truncation, and literal strings. `SourceModule` copies and retains validated
SPIR-V so API objects can instantiate multiple entry points without borrowing
application memory.

Use `translator.instantiate` when retaining a source module:

```zig
var source = try ir.spirv.SourceModule.init(allocator, words);
defer source.deinit(allocator);

var module = try ir.spirv.translator.instantiate(allocator, &source, .{
    .entry_point = "main",
    .stage = .compute,
    .specializations = &.{.{
        .constant_id = 7, // SPIR-V SpecId
        .data = std.mem.asBytes(&workgroup_width),
    }},
});
defer module.deinit();
```

`translator.translate` remains a convenience wrapper for borrowed words. Each
translation selects one entry point and returns an independent mutable IR
module. Only functions in that entry point's static call tree are declared and
translated; unused helpers and other entry points cannot require interfaces
omitted from the selected entry point. The translator lowers a defined subset:

- Vertex, fragment, and compute stages.
- Basic scalar, vector, array, structure, pointer, and function types.
- Ordinary constants plus scalar boolean, integer, and floating-point
  specialization constants selected through `SpecId`. Missing overrides use the
  SPIR-V defaults, and specialization composites are rebuilt from their
  specialized elements. `OpSpecConstantOp` is not evaluated yet.
- Functions, blocks, branches, structured merge marks, and returns. `OpSwitch`
  is lowered to a chain of integer equality tests and conditional branches.
- `OpPhi` into block parameters and edge arguments.
- The arithmetic, comparison, select, bitcast, conversion, bit-field, and
  composite operations named in the reference above where mappings currently
  exist, including extended integer arithmetic, matrix products and transpose,
  floating remainder and classification, plus the complete scalar/vector
  integer and floating-point comparison families. Redundant greater-than forms
  are canonicalized by reversing less-than operands; integer and unordered
  floating-point `<=`/`>=` forms use a comparison followed by `logical_not`.
- Fragment-only `OpDPdx`, `OpDPdy`, and `OpFwidth` on floating scalars/vectors,
  mapped to `d_pdx`, `d_pdy`, and `fwidth`. Explicit fine/coarse derivative
  instructions remain unsupported.
- GLSL.std.450 floating unary operations `Acos`, `Acosh`, `Asin`, `Asinh`,
  `Atan`, `Atanh`, `Ceil`, `Cos`, `Cosh`, `Exp`, `Exp2`, `FAbs`, `FSign`,
  `Floor`, `Length`, `Log`, `Log2`, `Normalize`, `Round`, `Sin`, `Sinh`, `Tan`,
  and `Tanh`; binary operations `Atan2`, `FMax`, `FMin`, `Pow`, and `Step`;
  unsigned integer `UMax` and `UMin`; and ternary operations `FMix`, `Fma`, and
  `SmoothStep`. `FClamp` lowers to floating maximum followed by minimum;
  `NClamp` uses per-component comparisons and selects on `f32` vectors. `Cross`
  accepts two matching three-component floating vectors and lowers to component
  extraction, multiplication, subtraction, and vector construction, preserving
  the operand precision without requiring a dedicated IR or interpreter opcode.
  `OpExtInstImport` declarations are classified once and dispatched through
  `src/compiler/spirv/extensions/`; set-specific translation lives below the
  corresponding extension subdirectory. Only the listed extended instructions
  are implemented; an opcode's presence in the GLSL.std.450 enum alone does not
  imply translation support.
- Non-multisampled storage images with 1D, 1D-array, 2D, 2D-array, 3D, cube,
  cube-array, or buffer shape. `OpImageRead` / `OpImageWrite` retain dimension
  and arrayness. Image fetch/read/write coordinates must be integer32 scalars or
  vectors with at least the required number of components; extra components are
  discarded through prefix extraction when lowering to IR. Buffer/1D accesses
  consume one component, arrayed 1D/2D consume two/three, and 3D/cube/cube-array
  consume three. Cube-array z remains the combined face/layer, not a fourth
  coordinate. `OpImageTexelPointer` is not subject to this normalization.
  Buffer images with `Sampled` 1/2 map to uniform/storage texel-buffer resources.
  Arrayed 3D/buffer types are rejected.
- Core `OpImage` extracts the image resource from a sampled image. `OpImageFetch`
  lowers to unfiltered `image_fetch`: only the `Lod` image operand is supported
  for non-buffer images. Omitting image operands selects view-relative LOD zero,
  which the frontend materializes as an explicit integer32 constant to preserve
  the public IR requirement for non-buffer LOD. Buffer fetches have no image
  operands or LOD. Cube and
  multisampled fetches are rejected. Combined buffer descriptors do not allocate
  an unused sampler resource. Sampling/gathering buffer images is rejected.
  Image size queries, `UClamp`, and additional atomic operations are not added.
- `OpImageGather` on non-arrayed 2D sampled images without optional image
  operands, mapped to `image_gather` with an explicit component selector.
- Decorated stage inputs and outputs, with interface load and store. Partial
  output stores reconstruct the aggregate while preserving untouched components,
  including nested constant and dynamic indices. After inlining, output reads
  are promoted to invocation-local SSA state carried through block parameters
  and edge arguments; unwritten components start as `undef`. Returned IR retains
  whole-output stores and does not load output interfaces.
- `OpName` debug names for functions, blocks, parameters, constants, and
  instruction results when they are valid textual IR identifiers.

Symbolic identifiers in SPIR-V assembly are assembler syntax and are not stored
in the binary by `spirv-as`; add `OpName` instructions when those names must
survive translation. Unsupported source instructions return an error; they are
not preserved as opaque SPIR-V. This prevents silent mistranslation.

## Running tests

From the repository root, run:

```sh
zig build test-ir
```

The SPIR-V translation tests keep their assembly as multiline strings beside
their assertions and pipe it through `spirv-as`. Therefore SPIRV-Tools must be
on `PATH` when those tests run. Only malformed-binary parser tests use raw words,
because an assembler cannot produce intentionally malformed instructions.

## Documentation

A complete codebase documentation can be found [here](https://vulkan-driver.kbz8.me/docs/ir/).
