# Zig Compiler

The self-hosted Zig compiler's scanner and parser, found in `lib/std/zig/`. The gold standard for idiomatic Zig parsing code.

**Source files:**
- `references/zig/lib/std/zig/tokenizer.zig` - Tokenizer
- `references/zig/lib/std/zig/Parse.zig` - Parser
- `references/zig/lib/std/zig/Ast.zig` - AST

**Further reading:** Mitchell Hashimoto's walkthroughs of the [tokenizer](https://mitchellh.com/zig/tokenizer) and [parser](https://mitchellh.com/zig/parser).

## Tokenizer

The tokenizer is **allocation-free** — it operates on a source buffer and maintains only a byte index. No memory is allocated during tokenization.

### Token struct

```zig
pub const Token = struct {
    tag: Tag,   // enum identifying the token type
    loc: Loc,   // byte offsets into source

    pub const Loc = struct {
        start: usize,
        end: usize,
    };
};
```

Minimal: just a tag and a byte range. No line numbers, no copied lexemes — those are derived on demand from the source buffer.

### Tokenizer struct

```zig
// Just a buffer pointer and an index — truly stateless
buffer: [:0]const u8,  // null-terminated source
index: usize,
```

### Scanning approach

Single entry point: `pub fn next(self: *Tokenizer) Token` returns one token at a time.

Uses a **labeled state machine** with ~40 states inside a big `switch`:
- `.start` — dispatch on first character
- `.identifier` — consume identifier chars, then check keyword map
- `.string_literal`, `.char_literal` — consume until closing delimiter
- `.int`, `.float` — number literals with hex/binary/octal support
- `.line_comment`, `.doc_comment` — comments
- Various multi-character operator states (`.equal`, `.plus`, `.angle_bracket_left`, etc.)

### Keyword lookup

```zig
const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "fn", .keyword_fn },
    .{ "const", .keyword_const },
    // ... 50+ keywords
});
```

Built at **compile time** — `initComptime()` creates a perfect hash map that exists in the binary. Extremely fast O(1) lookup with no runtime allocation.

### Token.Tag enum

Comprehensive — 100+ variants covering:
- All Zig keywords (`keyword_fn`, `keyword_const`, `keyword_if`, etc.)
- All operators including Zig-specific ones (`plus_percent` for wrapping add, `plus_pipe` for saturating add)
- Punctuation, literals, comments, `builtin`, `invalid`, `eof`

The `lexeme()` method returns the fixed string for known tokens (`"+"` for `.plus`), or `null` for variable-length tokens.

### Contrast with our scanner

| Aspect | Zig | Ours |
|--------|-----|------|
| Allocation | None | Builds token `ArrayList` |
| Scanning | On-demand (`next()`) | All-at-once into array |
| Keywords | Comptime `StaticStringMap` | Comptime static map (similar) |
| State | Single `index` | `start` + `current` + `line` |
| Token data | Byte offsets only | Stores lexeme slice + line |

## Parser

Found in `Parse.zig`. Classic recursive descent but with a **two-pass** approach.

### Two-pass design

1. **First pass:** Tokenizer produces a complete token array (all tokens materialized up front)
2. **Second pass:** Parser walks the token array by index, building the AST

This enables easy lookahead (just index arithmetic) and backtracking.

### Parser struct

```zig
gpa: Allocator,
source: []const u8,
tokens: Ast.TokenList.Slice,   // pre-tokenized
tok_i: TokenIndex,              // current position
errors: std.ArrayList(AstError),
nodes: Ast.NodeList,            // building the AST
extra_data: std.ArrayList(u32), // overflow storage
scratch: std.ArrayList(Node.Index), // temp workspace
```

### Recursive descent structure

Grammar-based naming — each function parses one grammar rule:
- `parseRoot()` — top-level declarations
- `parseContainerMembers()` — struct/union/enum bodies
- `parseBlock()` — `{ ... }` blocks
- `parseExpr()` — expressions with precedence
- `parseStatement()` — statements

Operator precedence is encoded in the **call chain** (same approach as ours):
```
expression -> assignment -> logical_or -> logical_and ->
bitwise_or -> ... -> unary -> primary
```

### Error handling

**Collects all errors** rather than stopping at the first one:
- `errors: std.ArrayList(AstError)` accumulates diagnostics
- Recovery via `findNextContainerMember()` — skip tokens until a valid boundary
- `warn()` logs but continues; `fail()` logs and returns error
- 100+ error tag variants for specific messages

### Node construction

- `addNode(elem: Node)` — append to the node array
- `addExtra(extra: anytype)` — pack structured data into the `extra_data` u32 array
- `reserveNode()` / `unreserveNode()` — for tentative parsing (backtracking)
- `listToSpan(list)` — convert scratch list to a SubRange in extra_data

## AST

The most architecturally interesting part. Uses **data-oriented design** rather than traditional tagged unions.

### Core structure

```zig
pub const Ast = struct {
    source: [:0]const u8,
    tokens: TokenList.Slice,
    nodes: NodeList.Slice,     // MultiArrayList
    extra_data: []u32,
    errors: []const Error,
};
```

### Node representation

```zig
pub const Node = struct {
    tag: Tag,              // 1 byte: node type
    main_token: TokenIndex,// which token identifies this node
    data: Data,            // 8 bytes: up to 2 node references
};
```

Each node is exactly **1 byte tag + 4 bytes token + 8 bytes data = 13 bytes**. The `Data` union holds combinations of node indices, optional indices, and extra_data pointers.

### MultiArrayList (struct-of-arrays)

Instead of `[]Node` (array of structs), Zig uses `std.MultiArrayList(Node)`. This stores each field in a separate contiguous array:

```
tags:        [tag0, tag1, tag2, ...]
main_tokens: [tok0, tok1, tok2, ...]
datas:       [data0, data1, data2, ...]
```

**Benefits:**
- Better cache locality when iterating one field across many nodes
- Smaller memory footprint (1-byte tags packed tightly)
- Efficient for compiler passes that only need certain fields

### Indexing system

All indices are **newtype enums** for type safety at zero cost:
- `Node.Index` — enum(u32), index into nodes array
- `Node.OptionalIndex` — enum(u32), maxInt = "none"
- `ExtraIndex` — index into extra_data
- `Node.Offset` — signed relative offset

### Extra data storage

When a node needs more than 2 child references (e.g., function parameters, block statements), it stores a `SubRange` pointing into the `extra_data: []u32` array. This handles variable-length data without per-node heap allocation.

### Contrast with our AST

| Aspect | Zig | Ours |
|--------|-----|------|
| Node type | Compact 13-byte struct | Tagged union (variable size) |
| Storage | MultiArrayList (SoA) | `SegmentedList` (pointer-stable) |
| Children | Indices into flat array | Pointers to other nodes |
| Variable-length | `extra_data` u32 array | Embedded in union variants |
| Memory layout | Columnar / cache-friendly | Scattered heap allocations |

The Zig approach is optimized for large programs where cache behavior matters. Our approach is simpler and more natural for a small interpreter.

## Error Handling

### Error accumulation

The parser collects **all errors** rather than stopping at the first one:

```zig
errors: std.ArrayList(AstError),
```

Each error has a **tag** (one of 100+ variants like `expected_semi_after_decl`, `expected_comma_after_field`), a token index pointing to the offending location, and optional extra data for additional context.

Two reporting functions:
- `warn()` — records the error and **continues parsing** (used for non-fatal issues)
- `fail()` — records the error and **returns `error.ParseError`** to unwind

### Error recovery: container member skipping

When a parse error occurs in a declaration, the parser catches the error and skips to the next container member:

```zig
fn findNextContainerMember() void {
    // Skip tokens until we find something that looks like the start
    // of a new declaration: keyword_pub, keyword_fn, keyword_const,
    // keyword_var, keyword_test, etc.
}
```

This is **container-boundary recovery** — errors in one declaration don't affect parsing of the next. The Zig compiler reports all errors from all declarations in a single compile.

### Error bundle rendering

After parsing, all errors are formatted into an `ErrorBundle` that renders with source context, caret markers, and notes — similar to Rust's error output. Errors are sorted by source position.

### Contrast with our error handling

| Aspect | Zig Compiler | Ours |
|--------|-------------|------|
| Strategy | Accumulate all errors | Set flag, continue |
| Recovery | Skip to next container member | Return error, no skip |
| Error data | Tag + token index + extra | Line number + message string |
| Output | ErrorBundle with source context | `[file:line] message` to stderr |

#zig #tokenizer #parser #ast #reference
