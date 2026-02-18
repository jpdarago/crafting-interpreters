# Bun (JS Parser)

Bun's JavaScript/TypeScript lexer and parser, one of the largest production Zig codebases. Handles the full complexity of JS/TS/JSX.

**Source files:**
- `references/bun/src/js_lexer.zig` - Lexer
- `references/bun/src/js_parser.zig` - Parser
- `references/bun/src/js_ast.zig` - AST (also `src/ast/Expr.zig`, `Stmt.zig`, `E.zig`, `S.zig`, `B.zig`)

## Lexer

### Comptime-configurable design

The lexer is generated via a `NewLexer()` function with compile-time options:

```zig
pub fn NewLexer(comptime JSONOptions) type { ... }
```

Configuration flags control: JSON mode, comment handling, trailing commas, escape sequences, etc. This produces specialized lexer types at compile time — no runtime branching for features that are statically known.

### Lexer struct

```zig
pub const Lexer = struct {
    log: *logger.Log,
    source: logger.Source,
    current: usize,                  // byte offset
    start: usize,                    // token start
    end: usize,                      // token end
    has_newline_before: bool,        // critical for ASI
    token: T,                        // current token type
    code_point: CodePoint,           // current Unicode codepoint

    // String handling
    string_literal_raw_content: string,
    string_literal_raw_format: enum { ascii, utf16, needs_decode },
    temp_buffer_u16: std.array_list.Managed(u16),

    // Template literal tracking
    rescan_close_brace_as_template_token: bool,
};
```

Notable: `has_newline_before` is essential for JavaScript's automatic semicolon insertion (ASI). The lexer tracks whether a newline occurred between the previous and current token.

### Token types (~95 variants)

Includes JS-specific tokens that don't exist in simpler languages:
- **Template literals:** `t_template_head`, `t_template_middle`, `t_template_tail`, `t_no_substitution_template_literal`
- **Private identifiers:** `t_private_identifier` (for `#foo` in classes)
- **Shebang:** `t_hashbang` (for `#!/usr/bin/env node`)
- All assignment operators grouped for fast range checks

### String literal handling

Complex multi-encoding support:
- Input is WTF-8 (UTF-8 variant allowing lone surrogates)
- Internal storage uses UTF-16 with on-demand UTF-8 conversion
- Three quote types: `"`, `'`, `` ` `` (template literals)
- `decodeEscapeSequences()` handles Unicode escapes (`\uXXXX`, `\u{XXXXX}`), legacy octals, line continuations

### Regex vs division ambiguity

In JavaScript, `/` can start a regex or be division. Bun defers this to parser context — the lexer stores enough state for the parser to request a rescan when needed.

### Keyword lookup

Same comptime `ComptimeStringMap` pattern as Zig and Aro. Fast path for ASCII identifiers, slow path (`scanIdentifierWithEscapes()`) for Unicode escapes in identifiers.

### Contrast with our scanner

Our scanner is dramatically simpler — no encoding concerns, no template literals, no ASI tracking. But the fundamental pattern (advance through source, switch on current character, build tokens) is the same.

## Parser

Recursive descent, same precedence-in-call-chain approach as ours and the other reference projects.

### Key parser functions

```
parseProgram()
  -> parseStatements()
    -> parseStatement()
      -> parseExpression()
        -> parseAssignmentExpression()
          -> parseLogicalOr()
            -> parseLogicalAnd()
              -> parseBitwiseOr() -> ... -> parsePrimary()
```

### JS-specific complexity

**Destructuring patterns:**
- Array: `[a, b, ...rest] = array`
- Object: `{x, y: renamed} = obj`
- Nested, with defaults — these are parsed as expressions then validated as patterns

**Arrow functions:**
- Single param: `x => x + 1` (no parens — parser must backtrack)
- Async: `async (x) => x`
- Body can be expression or block

**Template literals:**
- Head/middle/tail distinction: `` `text ${expr} more ${expr} end` ``
- Lexer and parser cooperate — `rescan_close_brace_as_template_token` signals the lexer to treat `}` as template continuation

**Optional chaining:**
- `a?.b?.c` — property access
- `a?.()` — function call
- `a?.[i]` — computed access

**JSX:**
- `<Component prop={expr}>children</Component>`
- JSX pragma tracking for runtime selection

**TypeScript:**
- Type annotations are largely skipped during parsing
- Access modifiers, generics, enums lowered to JS equivalents

## AST

### Organization

Split across multiple files for manageability:
- `Expr.zig` / `E.zig` — expression nodes and their data types
- `Stmt.zig` / `S.zig` — statement nodes and their data types
- `B.zig` — binding/destructuring pattern types

### Expression nodes

```zig
pub const Expr = struct {
    loc: logger.Loc,
    data: Data,        // tagged union
};

pub const Data = union(Tag) {
    e_array: *E.Array,
    e_binary: *E.Binary,
    e_call: *E.Call,
    e_dot: *E.Dot,              // obj.prop
    e_index: *E.Index,          // obj[key]
    e_arrow: *E.Arrow,
    e_function: *E.Function,
    e_class: *E.Class,
    e_jsx_element: *E.JSXElement,
    e_template: *E.Template,
    e_identifier: E.Identifier, // inline (small)
    e_number: E.Number,         // inline (small)
    e_boolean: E.Boolean,       // inline (small)
    // ... 30+ expression types
};
```

### Size constraint

The `Data` union is strictly kept to **24 bytes** (3 pointer widths). Larger structures are stored as pointers (`*E.Array`, `*E.Call`), while small primitive-like values are stored inline (`E.Number`, `E.Boolean`). This ensures all expression nodes have uniform size for cache efficiency.

### Statement nodes

```zig
pub const Stmt = struct {
    loc: logger.Loc,
    data: Data,
};

pub const Data = union(Tag) {
    s_block: *S.Block,
    s_local: *S.Local,          // var/let/const
    s_if: *S.If,
    s_while: *S.While,
    s_for: *S.For,
    s_for_in: *S.ForIn,
    s_for_of: *S.ForOf,         // includes await variant
    s_switch: *S.Switch,
    s_try: *S.Try,
    s_import: *S.Import,
    s_export_clause: *S.ExportClause,
    // ... 20+ statement types
};
```

### Binding patterns (destructuring)

```zig
pub const B = union {
    b_identifier: *B.Identifier,  // x
    b_array: *B.Array,            // [a, b, c]
    b_object: *B.Object,          // {x, y}
    b_missing: B.Missing,         // placeholder
};
```

A separate node category for destructuring — these appear in variable declarations, function parameters, and assignment targets.

### Key data structures

```zig
// Binary operation
pub const Binary = struct {
    left: ExprNodeIndex,
    right: ExprNodeIndex,
    op: Op.Code,
};

// Property access with optional chaining
pub const Dot = struct {
    target: ExprNodeIndex,
    name: string,
    name_loc: logger.Loc,
    optional_chain: ?OptionalChain,  // .start or .continuation
    can_be_removed_if_unused: bool,  // for tree-shaking
};

// Function call
pub const Call = struct {
    target: ExprNodeIndex,
    args: ExprNodeList,
    optional_chain: ?OptionalChain,
    is_direct_eval: bool,           // special case for eval()
    can_be_unwrapped_if_unused: CallUnwrap,
};
```

### Node indexing

Uses opaque `ExprNodeIndex` and `StmtNodeIndex` instead of raw pointers. This enables array-based AST storage with better cache locality. The parser uses `SegmentedList` internally for pointer stability during construction.

### Memory model

- Thread-local `Stmt.Data.Store` for allocation pooling
- `ASTMemoryAllocator` for alternative strategies
- UTF-16/UTF-8 conversion pools for string handling

## Comparison with our interpreter

| Aspect | Bun | Ours |
|--------|-----|------|
| Lexer | WTF-8, comptime-configurable, ASI tracking | Simple ASCII scanner |
| Token types | ~95 | ~40 |
| Parser | Recursive descent + complex backtracking | Recursive descent, straightforward |
| AST union size | Strict 24-byte cap | Variable (tagged union) |
| Node types | 50+ expr + 20+ stmt + binding patterns | ~10 expr + ~5 stmt |
| Memory | Thread-local pools, index-based | Arena allocator |
| Features | JS/TS/JSX, modules, destructuring, optional chaining | Literals, variables, control flow |

## Error Handling

### Centralized logger

Bun uses a shared `logger.Log` system rather than parser-specific error handling:

```zig
pub const Log = struct {
    warnings: u32,
    errors: u32,
    msgs: std.array_list.Managed(Msg),
    level: Level,   // verbose | debug | info | warn | err
};

pub const Msg = struct {
    kind: Kind,     // err | warn | note | debug | verbose
    data: Data,     // text + optional location
    notes: []Data,  // attached notes for context
};
```

The parser holds a `log: *logger.Log` pointer and calls `log.addError(source, loc, text)` or `log.addRangeError(source, range, text)` for errors with byte-range context.

### Error messages with source context

Error output includes line text with a caret marker:

```
5 | const x = ;
              ^
error: Unexpected end of file
  at example.js:5:12
```

Messages have attached **notes** for additional context (e.g., "did you mean ...?" or "previous definition here").

### Recovery strategy

The parser **continues after errors** without a panic mode — it logs the error and attempts to parse the next construct. This works because JS/TS has enough syntactic landmarks (semicolons, braces) for the parser to resynchronize. The `Log.level` field filters which messages are actually emitted.

### Contrast with our error handling

| Aspect | Bun | Ours |
|--------|-----|------|
| Strategy | Centralized log, continue parsing | Set flag, return error |
| Severity levels | 5 (verbose → error) | 1 (error only) |
| Message data | Text + location + notes | Line number + message |
| Source context | Line text with caret | None |
| Output | Terminal with ANSI colors | Plain stderr |

### Lessons for our interpreter

1. **Comptime configuration** is powerful — `NewLexer()` eliminates runtime branching for static features
2. **Strict union size constraints** (24 bytes) improve cache behavior
3. **Separating binding patterns** from expressions is cleaner for destructuring
4. **Index-based AST** (not pointer-based) enables better memory layout
5. `has_newline_before` shows how lexer state can encode parser-relevant context

#bun #javascript #typescript #lexer #parser #ast #reference
