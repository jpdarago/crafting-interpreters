# Aro (C Compiler)

A full C23 compiler written in Zig, supporting GCC/Clang/MSVC extensions. Integrated into the Zig compiler as a C frontend. Architecture maps closest to our interpreter's pipeline.

**Source files:**
- `references/arocc/src/aro/Tokenizer.zig` (~2,400 lines)
- `references/arocc/src/aro/Parser.zig` (~10,900 lines)
- `references/arocc/src/aro/Tree.zig` (~3,800 lines)

## Tokenizer

### Token struct

```zig
pub const Token = struct {
    id: Id,            // token type
    source: Source.Id, // which source file
    start: u32,        // byte offset start
    end: u32,          // byte offset end
    line: u32,         // line number
};
```

More fields than Zig's tokenizer — tracks source file ID (for multi-file compilation) and line numbers directly.

### Tokenizer struct

```zig
buf: []const u8,
index: u32 = 0,
source: Source.Id,
langopts: LangOpts,        // C standard version + extensions
line: u32 = 1,
splice_index: u32 = 0,     // line splicing tracking
splice_locs: []const u32,
```

Notable: `LangOpts` configures which C standard features to accept (C89/C99/C11/C23) and which vendor extensions are active.

### State machine

Uses an explicit `state` enum with ~35 states inside `next()`:

```zig
var state: enum {
    start, whitespace,
    u, u8, U, L,              // string/char literal prefixes
    string_literal, char_literal_start, char_literal,
    char_escape_sequence, string_escape_sequence,
    identifier, extended_identifier,
    equal, bang, pipe, colon, percent, asterisk, plus,
    angle_bracket_left, angle_bracket_right,
    // ...
    line_comment, multi_line_comment,
    pp_num, pp_num_exponent, pp_num_digit_separator,
} = .start;
```

### Token.Id enum (~180 variants)

Far more than our ~40 token types. Includes:
- **String/char literals with encoding prefixes:** `string_literal`, `string_literal_utf_8`, `string_literal_utf_16`, `string_literal_utf_32`, `string_literal_wide`
- **C-specific operators:** `arrow` (->), `ellipsis` (...), `hash_hash` (## for token pasting)
- **120+ keywords** spanning C89 through C23, plus GCC/Clang/MSVC extensions
- **Preprocessor tokens:** `macro_param`, `stringify_param`, `placemarker`, `include_start`

### C-specific challenges handled

1. **String literal prefixes:** `u8"..."`, `u"..."`, `U"..."`, `L"..."` — each gets a separate token type. The tokenizer enters prefix states (`u`, `u8`, `U`, `L`) before transitioning to string scanning.
2. **Trigraphs/digraphs:** `??=` for `#`, `<:` for `[`, etc. (legacy C89/C99 features).
3. **Line splicing:** `\` at end of line continues to next line. Tracked via `splice_locs`.
4. **Extended identifiers:** Unicode escapes (`\uXXXX`, `\UXXXXXXXX`) and UTF-8 codepoints in identifiers.
5. **Preprocessor numbers:** `pp_num` token type for the lexical category of numbers before semantic analysis.

### Keyword lookup

Same approach as Zig — compile-time `ComptimeStringMap`:
```zig
const keywords = std.ComptimeStringMap(Token.Id, .{
    .{ "auto", .keyword_auto },
    .{ "break", .keyword_break },
    // ... 120+ entries
});
```

## Parser

At ~10,900 lines, this is a serious production parser. Recursive descent with extensive state tracking.

### Parser struct (abbreviated)

```zig
pp: *Preprocessor,
comp: *Compilation,
tok_ids: []const Token.Id,
tok_i: TokenIndex = 0,
tree: Tree,

// Symbol table
syms: SymbolStack = .{},

// Temporary buffers for building lists
list_buf: NodeList = .empty,
param_buf: std.ArrayList(Type.Func.Param) = .empty,
enum_buf: std.ArrayList(Type.Enum.Field) = .empty,
record_buf: std.ArrayList(Type.Record.Field) = .empty,

// Per-function state
func: struct { qt: ?QualType = null, name: TokenIndex = 0, ... } = .{},

// Control flow tracking
@"switch": ?*Switch = null,
in_loop: bool = false,
```

Noteworthy: the parser tracks switch statement context for case value validation, and `in_loop` for break/continue legality.

### Recursive descent call chain

Operator precedence encoded identically to our approach — in the function call chain:

```
expr()
  -> comma_expr()           // lowest: ,
    -> assignExpr()          // =, +=, -=, ...
      -> condExpr()          // ?:
        -> boolOrExpr()      // ||
          -> boolAndExpr()   // &&
            -> bitOrExpr()   // |
              -> bitXorExpr()// ^
                -> bitAndExpr()  // &
                  -> equalExpr()     // == !=
                    -> relationalExpr()  // < > <= >=
                      -> shiftExpr()     // << >>
                        -> additiveExpr()    // + -
                          -> multiplicativeExpr() // * / %
                            -> unaryExpr()   // ! ~ - + ++ -- & * sizeof
                              -> postfixExpr()  // ++ -- [] () . ->
                                -> primaryExpr()  // literals, identifiers, (expr)
```

15 precedence levels vs our ~10.

### C-specific parsing challenges

1. **Typedef names vs identifiers:** The parser maintains a `SymbolStack` to know whether an identifier is a type name or a variable. This is the classic "lexer hack" — C's grammar is context-sensitive.
2. **Declaration vs expression ambiguity:** `(T)(x)` — is it a cast or a function call? Resolved by checking if `T` is a type name.
3. **Designated initializers (C99):** `.field = expr` and `[n] = expr` inside initializer lists.
4. **Flexible array members:** Last struct field can be `[]` with no size.
5. **`_Generic` selection (C11):** `_Generic(expr, type1: expr1, ..., default: exprN)`.
6. **Attributes:** Three syntaxes — GCC `__attribute__((name))`, C23 `[[name]]`, MSVC `__declspec(...)`.
7. **Computed goto (GCC):** `goto *expr` — requires tracking address-of-label expressions.

### Error handling

Rich diagnostics system:
- `Diagnostics` object with error/warning classification
- Configurable pedantic/extension warning levels
- Error recovery: `synchronize()` skips to next statement boundary (same concept as our panic mode)

### Token consumption helpers

```zig
fn eatToken(p: *Parser, id: Token.Id) ?TokenIndex   // consume if match
fn expectToken(p: *Parser, expected: Token.Id) Error!TokenIndex  // consume or error
fn tokSlice(p: *Parser, tok: TokenIndex) []const u8  // get token text
```

Same pattern as ours — `eatToken` is our `match`, `expectToken` is our `consume`.

## AST (Tree)

### Tree struct

```zig
tokens: Token.List.Slice,
nodes: std.MultiArrayList(Node.Repr) = .empty,  // SoA layout
extra: std.ArrayList(u32) = .empty,
root_decls: std.ArrayList(Node.Index) = .empty,
value_map: ValueMap = .empty,  // compile-time evaluated values
```

Uses **`MultiArrayList`** like the Zig compiler — struct-of-arrays for cache efficiency.

### Node types (~100 variants as tagged union)

**Declarations:** `function`, `variable`, `typedef`, `struct_decl`, `union_decl`, `enum_decl`, `enum_field`, `record_field`, `static_assert`

**Statements:** `compound_stmt`, `if_stmt`, `while_stmt`, `do_while_stmt`, `for_stmt`, `switch_stmt`, `case_stmt`, `default_stmt`, `goto_stmt`, `return_stmt`, `break_stmt`, `continue_stmt`, `labeled_stmt`, `asm_stmt`

**Expressions:** All binary/unary operators, `cast` (with 55+ cast kind variants), `call_expr`, `array_access_expr`, `member_access_expr`, `cond_expr`, `comma_expr`, `sizeof_expr`, `compound_literal_expr`, `generic_expr`, plus literals

### Key node structures

```zig
pub const IfStmt = struct {
    if_tok: TokenIndex,
    cond: Node.Index,
    then_body: Node.Index,
    else_body: ?Node.Index,
};

pub const Binary = struct {
    qt: QualType,        // result type (C is typed!)
    lhs: Node.Index,
    op_tok: TokenIndex,
    rhs: Node.Index,
};

pub const Cast = struct {
    qt: QualType,
    l_paren: TokenIndex,
    kind: Kind,          // 55+ cast kinds (lval_to_rval, int_cast, float_to_int, ...)
    operand: Node.Index,
    implicit: bool,      // compiler-inserted vs explicit
};
```

Notable: every expression node carries a `QualType` — the result type including qualifiers (const, volatile, restrict, atomic). This is the fundamental difference from our dynamically-typed interpreter.

### Implicit casts

Aro inserts **explicit cast nodes** for every implicit conversion (e.g., lvalue-to-rvalue, array-to-pointer, integer promotion). The `Cast.Kind` enum has 55+ variants tracking exactly what conversion occurs. Our interpreter doesn't need this since values carry their types at runtime.

## Comparison with our interpreter

| Aspect | Aro | Ours |
|--------|-----|------|
| Scanner | State machine, ~35 states, 180 token types | Switch-based, ~40 token types |
| Keywords | 120+ (C standards + extensions) | ~20 Lox keywords |
| Parser size | ~10,900 lines | ~500 lines |
| Precedence levels | 15 | ~10 |
| Type system | Full C types with qualifiers | Dynamic typing |
| AST storage | MultiArrayList (SoA) | SegmentedList |
| Error handling | Rich diagnostics, configurable warnings | Simple error messages |
| Scope tracking | SymbolStack with shadowing detection | Environment chain |

The architecture is the most similar to ours of all four reference projects — same pipeline shape (tokenizer -> parser -> tree), same recursive descent approach, same precedence-in-call-chain pattern. The complexity difference comes entirely from C being a much larger, more complex language.

#aro #c-compiler #tokenizer #parser #ast #reference
