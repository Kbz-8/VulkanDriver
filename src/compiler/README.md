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
| `@name` | A function or interface declaration                              | `@main`, `@out_color` |
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
    <constant declarations>

    fn @<name>(<parameters>) -> <type>
    {
        .<block>(<block parameters>):
            <instructions>
            <terminator>

    }
}
```

Execution modes, resources, source locations, and structured-control metadata
exist in memory, but the printer does not display them yet.

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
| Array            | `array[u32, 8]`                 | A fixed number of equal elements. Its length must not be zero.            |
| Structure        | `struct[f32, vec4[f32]]`        | An ordered sequence of potentially different member types.                |
| Pointer          | `ptr[workgroup, u32]`           | A pointer to a type within an address space.                              |
| Resource handle  | `resourceHandle[sampled_image]` | An opaque handle for later resource operations.                           |

The current address spaces are `function`, `private`, `workgroup`,
`input`, `output`, `uniform`, `storage`, `push_constant`, and `physical`.

The current resource kinds are `uniform_buffer`, `storage_buffer`,
`sampled_image`, `storage_image`, and `sampler`. A resource handle may also
carry an optional data type in memory, although the printer omits that type.

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
source location. Except for `store_interface` and `call`, current operations are
treated as side-effect free by the rewriter. A block's terminator is stored
separately from its ordinary instructions.

Most arithmetic operations are intended for scalars or vectors of their named
category and act component by component where vectors are allowed. The current
foundational validator often checks only that operand and result types match.
The stricter integer, float, boolean, bit-width, and vector-shape requirements
below describe semantic intent and still need more complete validation.

## Unary opcodes

Form:

```text
%result: <type> = <opcode> %operand
```

| Opcode        | Arity | Description                  | Usage                                                             | Small printed example       |
| ------------- | ----: | ---------------------------- | ----------------------------------------------------------------- | --------------------------- |
| `negate`      |     1 | Changes the arithmetic sign. | Signed integer or floating operand; the result has the same type. | `%2: i32 = negate %1`       |
| `logical_not` |     1 | Inverts a boolean value.     | Boolean operand and boolean result.                               | `%2: bool = logical_not %1` |
| `bitwise_not` |     1 | Inverts every bit.           | Integer operand; the result has the same type.                    | `%2: u32 = bitwise_not %1`  |

`negate` is one normalized opcode: the operand type distinguishes integer
negation from floating negation.

## Binary opcodes

Form:

```text
%result: <type> = <opcode> %lhs, %rhs
```

The two operands and result currently must have the same IR type.

### Integer arithmetic

| Opcode             | Description                                             | Usage                                                                       | Small printed example               |
| ------------------ | ------------------------------------------------------- | --------------------------------------------------------------------------- | ----------------------------------- |
| `integer_add`      | Adds fixed-width integers.                              | Integer operands of one type.                                               | `%3: u32 = integer_add %1, %2`      |
| `integer_subtract` | Subtracts the right operand from the left.              | Integer operands of one type.                                               | `%3: u32 = integer_subtract %1, %2` |
| `integer_multiply` | Multiplies fixed-width integers.                        | Integer operands of one type.                                               | `%3: u32 = integer_multiply %1, %2` |
| `unsigned_divide`  | Divides unsigned integers.                              | Unsigned integer operands.                                                  | `%3: u32 = unsigned_divide %1, %2`  |
| `signed_divide`    | Divides signed integers.                                | Signed integer operands.                                                    | `%3: i32 = signed_divide %1, %2`    |
| `unsigned_modulo`  | Produces the unsigned remainder.                        | Unsigned integer operands.                                                  | `%3: u32 = unsigned_modulo %1, %2`  |
| `signed_modulo`    | Produces signed modulo, whose sign follows the divisor. | Signed integer operands; this corresponds to SPIR-V `OpSMod`, not `OpSRem`. | `%3: i32 = signed_modulo %1, %2`    |

Integer addition, subtraction, and multiplication are signedness-neutral at the
opcode level; the type retains signedness. Exceptional division, overflow,
and poison rules are not yet separately recorded by the IR.

### Floating arithmetic

| Opcode           | Description                                                  | Usage                                                               | Small printed example             |
| ---------------- | ------------------------------------------------------------ | ------------------------------------------------------------------- | --------------------------------- |
| `float_add`      | Adds floating-point values.                                  | Floating operands of one type.                                      | `%3: f32 = float_add %1, %2`      |
| `float_subtract` | Subtracts the right operand from the left.                   | Floating operands of one type.                                      | `%3: f32 = float_subtract %1, %2` |
| `float_multiply` | Multiplies floating-point values.                            | Floating operands of one type.                                      | `%3: f32 = float_multiply %1, %2` |
| `float_divide`   | Divides the left operand by the right.                       | Floating operands of one type.                                      | `%3: f32 = float_divide %1, %2`   |
| `float_modulo`   | Produces floating modulo, similar to `x - y * floor(x / y)`. | Floating operands of one type; this corresponds to SPIR-V `OpFMod`. | `%3: f32 = float_modulo %1, %2`   |

Instructions do not yet carry fast-math flags, rounding modes, contraction
permission, or NaN guarantees.

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

## Comparison opcodes

All comparisons are printed with the `cmp_` prefix as one opcode token:

```text
%result: bool = cmp_<opcode> %lhs, %rhs
```

The operands must share one type, and the current validator requires the result
to be the scalar `bool` type.

| Opcode                          | Description                                             | Usage                                    | Small printed example                             |
| ------------------------------- | ------------------------------------------------------- | ---------------------------------------- | ------------------------------------------------- |
| `cmp_equal`                     | Tests whether two booleans or integers are equal.       | Equal-typed boolean or integer operands. | `%3: bool = cmp_equal %1, %2`                     |
| `cmp_not_equal`                 | Tests whether two booleans or integers differ.          | Equal-typed boolean or integer operands. | `%3: bool = cmp_not_equal %1, %2`                 |
| `cmp_unsigned_less`             | Compares integer bit patterns as unsigned.              | Unsigned integer operands.               | `%3: bool = cmp_unsigned_less %1, %2`             |
| `cmp_signed_less`               | Compares integers as signed.                            | Signed integer operands.                 | `%3: bool = cmp_signed_less %1, %2`               |
| `cmp_ordered_float_equal`       | Is true when neither operand is NaN and they are equal. | Floating operands.                       | `%3: bool = cmp_ordered_float_equal %1, %2`       |
| `cmp_unordered_float_equal`     | Is true when either operand is NaN, or they are equal.  | Floating operands.                       | `%3: bool = cmp_unordered_float_equal %1, %2`     |
| `cmp_ordered_float_not_equal`   | Is true when neither operand is NaN and they differ.    | Floating operands.                       | `%3: bool = cmp_ordered_float_not_equal %1, %2`   |
| `cmp_unordered_float_not_equal` | Is true when either operand is NaN, or they differ.     | Floating operands.                       | `%3: bool = cmp_unordered_float_not_equal %1, %2` |
| `cmp_ordered_float_less`        | Is true when neither operand is NaN and left is less.   | Floating operands.                       | `%3: bool = cmp_ordered_float_less %1, %2`        |
| `cmp_unordered_float_less`      | Is true when either operand is NaN, or left is less.    | Floating operands.                       | `%3: bool = cmp_unordered_float_less %1, %2`      |

There are no greater-than opcodes in the current instruction set. Swap the
operands and use the appropriate less-than form. Less-or-equal forms are also
not defined yet.

## Other opcodes

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

### `composite_construct`

Constructs a vector or structure from its immediate elements.

```text
%5: vec4[f32] = composite_construct %1, %2, %3, %4
```

For a vector, every element must have the vector's element type and their count
must equal its length. For a structure, each element must match the member at
the same position. The validator does not support array construction yet.

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
```

The result type must equal the interface variable's type. An optional dynamic
`element_index` exists in memory for future arrayed interfaces, but the current
printer does not show it and the validator does not use it to change the
result type.

### `store_interface`

Writes one declared shader output. It produces no SSA result and cannot write an
input declaration.

```text
store_interface @out_color, %1
```

The stored value must equal the interface variable's type. As with
`load_interface`, an optional unprinted `element_index` is reserved for later
arrayed-interface work. This operation has side effects.

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

The compiler currently provides a word parser and an initial translator in
`spirv/`. The parser validates the header, word counts, truncation, and literal
strings. The translator selects one entry point and lowers a defined subset:

- Vertex, fragment, and compute stages.
- Basic scalar, vector, array, structure, pointer, and function types.
- Ordinary and composite constants; unapplied specialization constants are
  refused.
- Functions, blocks, branches, structured merge marks, and returns.
- `OpPhi` into block parameters and edge arguments.
- The arithmetic, comparison, select, bitcast, and composite operations named
  in the reference above where mappings currently exist.
- Decorated stage inputs and outputs, with interface load and store.
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
