# Lua

The PUC-Rio reference Lua implementation in C. Famously compact — the entire language (scanner, parser, code generator, VM, GC, standard library) fits in ~24,000 lines of C. Lua is especially relevant because **Lox was directly inspired by it**, and the Crafting Interpreters book references Lua's design throughout.

Unlike our interpreter, Lua has **no AST** — the parser emits bytecode directly in a single pass.

**Source files:**
- `references/lua/llex.h` (~93 lines) — token types and scanner structs
- `references/lua/llex.c` (~604 lines) — scanner implementation
- `references/lua/lparser.h` (~196 lines) — parser structs (`expdesc`, `FuncState`)
- `references/lua/lparser.c` (~2,200 lines) — parser and code emission
- `references/lua/lcode.c` (~1,970 lines) — code generation helpers
- `references/lua/lopcodes.h` (~440 lines) — bytecode instruction formats

## Scanner

### Token representation

Single-character tokens use their ASCII code directly ('+' = 43, '-' = 45, etc.). Multi-character and reserved tokens start above `UCHAR_MAX`:

```c
#define FIRST_RESERVED  (UCHAR_MAX + 1)  // 256

enum RESERVED {
  TK_AND = FIRST_RESERVED, TK_BREAK,
  TK_DO, TK_ELSE, TK_ELSEIF, TK_END, TK_FALSE, TK_FOR, TK_FUNCTION,
  TK_GLOBAL, TK_GOTO, TK_IF, TK_IN, TK_LOCAL, TK_NIL, TK_NOT, TK_OR,
  TK_REPEAT, TK_RETURN, TK_THEN, TK_TRUE, TK_UNTIL, TK_WHILE,
  // multi-char operators
  TK_IDIV, TK_CONCAT, TK_DOTS, TK_EQ, TK_GE, TK_LE, TK_NE,
  TK_SHL, TK_SHR, TK_DBCOLON, TK_EOS,
  // literals
  TK_FLT, TK_INT, TK_NAME, TK_STRING
};

#define NUM_RESERVED  23   // TK_AND through TK_WHILE
```

23 reserved words — close to our ~20 Lox keywords. The ASCII-as-token trick eliminates a mapping step for single-char operators.

### Token struct

```c
typedef union {
  lua_Number r;     // floating-point constant
  lua_Integer i;    // integer constant
  TString *ts;      // string (identifier or literal)
} SemInfo;

typedef struct Token {
  int token;        // token type (TK_* or single char)
  SemInfo seminfo;  // semantic value
} Token;
```

The `SemInfo` union carries the token's value — a number, integer, or interned string pointer. More compact than our approach of storing a separate lexeme slice.

### LexState (scanner state)

```c
typedef struct LexState {
  int current;            // current character being scanned
  int linenumber;         // line counter
  int lastline;           // line of last consumed token
  Token t;                // current token
  Token lookahead;        // one-token lookahead (TK_EOS = none)
  struct FuncState *fs;   // current function being compiled
  struct lua_State *L;    // Lua state (for memory, error handling)
  ZIO *z;                 // input stream
  Mbuffer *buff;          // dynamic buffer for token accumulation
  Table *h;               // hash table for string interning
  TString *source;        // source name (for error messages)
  TString *envn;          // "_ENV" string
} LexState;
```

Notable: the scanner maintains **two tokens** — current (`t`) and `lookahead`. The parser calls `luaX_lookahead()` to peek without consuming, and `luaX_next()` promotes the lookahead to current:

```c
void luaX_next (LexState *ls) {
  ls->lastline = ls->linenumber;
  if (ls->lookahead.token != TK_EOS) {
    ls->t = ls->lookahead;            // promote lookahead to current
    ls->lookahead.token = TK_EOS;
  }
  else
    ls->t.token = llex(ls, &ls->t.seminfo);  // scan fresh token
}
```

### Keyword lookup via string interning

Lua's most elegant scanner feature. During initialization, all reserved words are created as interned strings and **tagged**:

```c
void luaX_init (lua_State *L) {
  for (int i = 0; i < NUM_RESERVED; i++) {
    TString *ts = luaS_new(L, luaX_tokens[i]);
    luaC_fix(L, obj2gco(ts));      // never garbage-collect reserved words
    ts->extra = cast_byte(i + 1);  // mark as reserved (1-indexed)
  }
}
```

During scanning, when an identifier is read, the scanner checks the interned string's `extra` field:
- If `ts->extra != 0` → it's a reserved word, return `ts->extra - 1 + FIRST_RESERVED`
- Otherwise → it's a regular identifier, return `TK_NAME`

Since Lua interns all strings (deduplicated via hash table), this is just a pointer comparison + field check. No hash map lookup at scan time.

### Scanning approach

The `llex()` function is a big `switch` on `ls->current`:

```c
static int llex (LexState *ls, SemInfo *seminfo) {
  luaZ_resetbuffer(ls->buff);
  for (;;) {
    switch (ls->current) {
      case '\n': case '\r':  inclinenumber(ls); break;
      case '-':   // check for -- (comment) or just -
      case '[':   // check for [[ (long string) or just [
      case '=':   // check for == or just =
      case '<':   // check for <=, <<, or just <
      // ... other operators
      case '"': case '\'':  read_string(ls, ...); return TK_STRING;
      default:
        if (lisdigit(ls->current))   { read_numeral(ls, ...); return ...; }
        if (lislalpha(ls->current))  { /* identifier or reserved word */ }
    }
  }
}
```

### Lua-specific lexical features

1. **Long strings:** `[[...]]` or `[==[...]==]` — nestable with `=` level matching. No escape processing inside.
2. **Long comments:** `--[[...]]` — same bracket syntax as long strings.
3. **Two number types:** Returns `TK_INT` or `TK_FLT` depending on format. Hex (`0x`), binary, exponents, underscores supported.
4. **Concat operator:** `..` (two dots) vs `...` (three dots = varargs) vs `.` (single dot = field access).
5. **Not-equal:** `~=` instead of `!=` — unique to Lua.

## Parser (Single-Pass Compiler)

The parser is fundamentally different from ours: it **emits bytecode directly** during parsing, with no AST. The key enabler is the `expdesc` (expression descriptor) struct.

### expdesc — the expression descriptor

Instead of building AST nodes, the parser builds `expdesc` values that describe *how to generate code* for an expression:

```c
typedef enum {
  VVOID,           // empty (no expression)
  VNIL, VTRUE, VFALSE,  // constant values
  VK,              // constant in K table
  VKFLT, VKINT, VKSTR,  // inline constants
  VNONRELOC,       // value in a fixed register
  VLOCAL,          // local variable (register index)
  VUPVAL,          // upvalue (captured variable)
  VINDEXED,        // table[key]
  VJMP,            // test/comparison result (conditional jump)
  VRELOC,          // can put result in any register
  VCALL,           // function call result
  VVARARG,         // vararg expression
} expkind;

typedef struct expdesc {
  expkind k;
  union {
    lua_Integer ival;     // VKINT
    lua_Number nval;      // VKFLT
    TString *strval;      // VKSTR
    int info;             // generic: register, K index, or PC
    struct { short idx; lu_byte t; } ind;  // indexed variables
    struct { lu_byte ridx; short vidx; } var;  // local variables
  } u;
  int t;  // patch list: exit-when-true jumps
  int f;  // patch list: exit-when-false jumps
} expdesc;
```

The `t` and `f` fields are **patch lists** for short-circuit evaluation. When `and`/`or` are parsed, conditional jumps are emitted with placeholder targets, forming a linked list that gets patched when the final target PC is known.

This is the key insight: `expdesc` is a **delayed code generation descriptor**. Code isn't fully emitted until the expression is needed in a specific context (assignment, condition, call argument, etc.).

### FuncState — per-function compilation state

```c
typedef struct FuncState {
  Proto *f;              // bytecode chunk being built
  struct FuncState *prev; // enclosing function (for nested functions)
  struct LexState *ls;   // shared scanner
  struct BlockCnt *bl;   // chain of active blocks
  int pc;                // next bytecode position
  int nk;                // constants count
  int np;                // nested protos count
  lu_byte nups;          // upvalue count
  lu_byte freereg;       // first free register
  short nactvar;         // active local variable count
} FuncState;
```

Each function being compiled has its own `FuncState` linked to its parent via `prev`. Local variables occupy registers directly — `freereg` tracks the next available slot.

### Expression parsing: precedence climbing

Lua uses **precedence climbing** (same family as Pratt parsing) through the `subexpr()` function:

```c
static BinOpr subexpr (LexState *ls, expdesc *v, int limit) {
  UnOpr uop = getunopr(ls->t.token);
  if (uop != OPR_NOUNOPR) {        // prefix unary operator?
    luaX_next(ls);
    subexpr(ls, v, UNARY_PRIORITY);
    luaK_prefix(ls->fs, uop, v, line);
  }
  else simpleexp(ls, v);            // atom: literal, variable, call, etc.

  // expand while operators bind tighter than 'limit'
  BinOpr op = getbinopr(ls->t.token);
  while (op != OPR_NOBINOPR && priority[op].left > limit) {
    expdesc v2;
    luaX_next(ls);
    luaK_infix(ls->fs, op, v);                          // prepare left operand
    BinOpr nextop = subexpr(ls, &v2, priority[op].right); // parse right with higher priority
    luaK_posfix(ls->fs, op, v, &v2, line);               // emit code
    op = nextop;
  }
  return op;
}
```

Entry point: `expr(ls, v)` calls `subexpr(ls, v, 0)`.

### Priority table

```c
static const struct {
  lu_byte left;    // left priority
  lu_byte right;   // right priority
} priority[] = {
   {10, 10}, {10, 10},           // + -
   {11, 11}, {11, 11},           // * %
   {14, 13},                     // ^ (right associative)
   {11, 11}, {11, 11},           // / //
   {6, 6}, {4, 4}, {5, 5},      // & | ~
   {7, 7}, {7, 7},              // << >>
   {9, 8},                       // .. (right associative)
   {3, 3}, {3, 3}, {3, 3},      // == < <=
   {3, 3}, {3, 3}, {3, 3},      // ~= > >=
   {2, 2}, {1, 1}               // and or
};

#define UNARY_PRIORITY  12
```

Right-associative operators have `left > right` (e.g., `^` has 14/13), causing the right operand to bind more tightly. This is more elegant than our approach of having separate left/right functions.

### Three-phase code generation per operator

Each binary operator goes through three code generation calls:

1. **`luaK_infix(op, v)`** — process left operand before scanning right side
   - For `and`/`or`: emit conditional jump (short-circuit)
   - For arithmetic: ensure value is in a register
2. **`subexpr(v2, right_priority)`** — recursively parse right operand
3. **`luaK_posfix(op, v, v2)`** — combine both operands
   - Attempt **constant folding** (e.g., `5 + 3` → `8` at compile time)
   - Handle `and`/`or` patch list merging
   - Emit binary opcode (`OP_ADD`, `OP_MUL`, etc.)

### Statement parsing

Statements use standard recursive descent — same approach as ours:

```c
static void statement (LexState *ls) {
  switch (ls->t.token) {
    case TK_IF:       ifstat(ls); break;
    case TK_WHILE:    whilestat(ls); break;
    case TK_DO:       /* block */ break;
    case TK_FOR:      forstat(ls); break;
    case TK_REPEAT:   repeatstat(ls); break;
    case TK_FUNCTION: funcstat(ls); break;
    case TK_LOCAL:    localstat(ls); break;
    case TK_RETURN:   retstat(ls); break;
    case TK_BREAK:    breakstat(ls); break;
    case TK_GOTO:     gotostat(ls); break;
    default:          exprstat(ls); break;
  }
}
```

### Variable resolution

Three scopes with different bytecode, same concept as [[zig-lox]]:
- **Locals:** tracked in `FuncState.locals`, stored in registers. `OP_MOVE` to copy.
- **Upvalues:** captured from enclosing functions via `FuncState.prev` chain. `OP_GETUPVAL`/`OP_SETUPVAL`.
- **Globals:** accessed via the `_ENV` table (Lua 5.4 has no true globals — they're table lookups on `_ENV`).

### Control flow via jump patching

Like [[zig-lox]], control flow compiles to jump instructions with **backpatching**:
- `OP_JMP` with a signed 25-bit offset
- `OP_TEST` checks a value, skips next instruction if false
- Forward jumps emit a placeholder, then `patchlist()` fills in the target once known

## Error Handling

### No recovery — immediate abort

Lua's most distinctive error handling choice: **all errors are fatal**. Every error function is marked `l_noret` (noreturn). A single syntax error aborts the entire compilation.

### Error propagation via longjmp

Lua uses C's `setjmp`/`longjmp` for error unwinding:

```c
l_noret luaD_throw (lua_State *L, TStatus errcode) {
  if (L->errorJmp) {
    L->errorJmp->status = errcode;
    LUAI_THROW(L, L->errorJmp);   // longjmp to nearest handler
  }
  else {
    if (g->panic) g->panic(L);
    abort();
  }
}
```

Compilation is wrapped in `luaD_rawrunprotected()`, so a syntax error returns an error status to the caller rather than crashing the host program. But within a single compilation, only one error is ever reported.

### Error function hierarchy

```c
// Core scanner error — adds file:line, throws
static l_noret lexerror (LexState *ls, const char *msg, int token) {
  msg = luaG_addinfo(ls->L, msg, ls->source, ls->linenumber);
  if (token)
    luaO_pushfstring(ls->L, "%s near %s", msg, txtToken(ls, token));
  luaD_throw(ls->L, LUA_ERRSYNTAX);
}

// Parser "expected X" errors
static l_noret error_expected (LexState *ls, int token) {
  luaX_syntaxerror(ls,
      luaO_pushfstring(ls->L, "%s expected", luaX_token2str(ls, token)));
}

// Semantic errors during code generation (clears token to avoid misleading context)
l_noret luaK_semerror (LexState *ls, const char *fmt, ...) {
  ls->t.token = 0;                  // suppress "near <token>"
  ls->linenumber = ls->lastline;    // revert to last consumed token's line
  luaX_syntaxerror(ls, msg);
}
```

`luaK_semerror` is notable — it clears the current token and reverts the line number so the error points to the *last consumed* token, not the current lookahead. This prevents misleading "near X" messages for semantic errors.

### Error message format

`luaG_addinfo()` prepends `source:line:` to every error. Source names are formatted by `luaO_chunkid()`:
- `@filename.lua` → `filename.lua:42: 'then' expected`
- `=literal` → `literal:42: 'then' expected`
- Inline code → `[string "x = 1 + ..."]:1: unexpected symbol near '+'`

The `txtToken()` function describes the offending token:
- Identifiers/strings/numbers: `near 'actualtext'`
- Reserved words/operators: `near 'and'`, `near '+'`

### Example error messages

```
script.lua:42: ')' expected near 'end'
script.lua:10: attempt to assign to const variable 'x'
[string "..."]:1: <goto foo> at line 3 jumps into the scope of 'y'
script.lua:5: too many local variables (limit is 200) in function at line 1
script.lua:7: no visible label 'done' for <goto>
```

### Recursion depth limiting

```c
#define enterlevel(ls)  luaE_incCstack(ls->L)
#define leavelevel(ls)  ((ls)->L->nCcalls--)
```

`enterlevel()` increments the C call stack counter and checks against `LUAI_MAXCCALLS`. This prevents stack overflow from deeply nested input like `((((((x))))))`.

### Contrast with our error handling

| Aspect | Lua | Ours |
|--------|-----|------|
| Recovery | None — first error aborts | Returns `ParseError`, sets flag |
| Multiple errors | No (only one error per compilation) | Yes (continues after errors) |
| Propagation | `longjmp` to protected caller | Zig error return |
| Message format | `file:line: msg near 'token'` | `[file:line] msg` |
| Semantic errors | Separate `semerror` (adjusts line/token) | Same path as syntax errors |
| Nesting limit | `enterlevel`/`leavelevel` + `LUAI_MAXCCALLS` | None |

Lua's no-recovery approach is a deliberate simplicity trade-off — it keeps the parser ~2,200 lines instead of the ~10,000+ needed for full recovery. For an interactive language primarily used embedded, reporting one clear error is often more helpful than a cascade of confusing follow-up messages.

## Comparison with our interpreter

| Aspect | Lua | Ours |
|--------|-----|------|
| Language | C (~3,000 lines for scanner+parser) | Zig (~500 lines for scanner+parser) |
| Scanner | Switch-based, ASCII-as-token trick | Switch-based, builds token array |
| Keywords | 23, via string interning + tag field | ~20, comptime static map |
| Lookahead | Two tokens (current + lookahead) | All tokens materialized |
| Intermediate form | None (direct bytecode) | AST (tagged unions) |
| Expression parsing | Precedence climbing (`subexpr`) | Recursive descent (call chain) |
| Priority table | Explicit left/right priorities | Encoded in function call depth |
| Variables | Register-based (locals in R[n]) | Environment chain (hash maps) |
| Closures | Upvalue metadata at parse time | Enclosing environment pointers |
| Control flow | Jump patching | Conditional AST traversal |
| Constant folding | Yes, at compile time | No |
| Memory | Manual C allocation + GC | Arena allocators |

### Key insight

Lua's single-pass approach is the **original inspiration for Part III** of Crafting Interpreters (the bytecode VM). The `expdesc` struct is the crucial innovation — it acts as a mini-AST for a single expression, enabling delayed code generation without building a full tree. Our tree-walker builds the entire AST first, which is simpler but uses more memory and prevents compile-time optimizations like constant folding.

The priority table approach to operator precedence (with separate left/right priorities for associativity) is more general and more compact than encoding precedence in the call chain. Adding a new operator in Lua means adding one row to the table; in our interpreter, it means adding a new function and wiring it into the chain.

**Further reading:** The [Ravi project documentation](https://the-ravi-programming-language.readthedocs.io/en/latest/lua-parser.html) has excellent detailed analysis of Lua's parser internals.

#lua #c #single-pass #precedence-climbing #bytecode #reference
