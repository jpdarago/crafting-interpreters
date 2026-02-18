# Go (Compiler)

The Go toolchain's scanner and parser, written in Go itself. Go has **two** scanner/parser implementations — the standard library (`go/scanner`, `go/parser`) used by tools like `gofmt` and `go vet`, and the compiler's internal package (`cmd/compile/internal/syntax`) used by the actual compiler. Both are recursive descent with precedence climbing for expressions.

**Source files (standard library):**
- `references/go/src/go/token/token.go` (~340 lines) — token definitions and precedence
- `references/go/src/go/scanner/scanner.go` (~1,000 lines) — lexical scanner
- `references/go/src/go/parser/parser.go` (~2,960 lines) — recursive descent parser
- `references/go/src/go/ast/ast.go` (~1,150 lines) — AST node definitions

**Source files (compiler):**
- `references/go/src/cmd/compile/internal/syntax/tokens.go` (~160 lines)
- `references/go/src/cmd/compile/internal/syntax/scanner.go` (~880 lines)
- `references/go/src/cmd/compile/internal/syntax/parser.go` (~2,900 lines)
- `references/go/src/cmd/compile/internal/syntax/nodes.go` (~490 lines)

## Scanner

### Token type

```go
type Token int  // simple integer enum

const (
    ILLEGAL Token = iota
    EOF
    COMMENT

    IDENT   // identifiers
    INT     // 12345
    FLOAT   // 123.45
    IMAG    // 123.45i
    CHAR    // 'a'
    STRING  // "abc"

    ADD  // +
    SUB  // -
    // ... ~50 operator/delimiter tokens

    BREAK    // keywords start here
    CASE
    // ... 25 keywords total
    VAR
)
```

Tokens are organized with **sentinel markers** (`literal_beg`/`literal_end`, `operator_beg`/`operator_end`, `keyword_beg`/`keyword_end`) that enable category predicates like `tok.IsKeyword()` via simple range checks — no bitmask needed.

Go has 25 keywords — fewer than most languages because many concepts (generics, error handling, concurrency) use minimal syntax.

### Scanner struct

```go
type Scanner struct {
    file *token.File   // source file handle (for position tracking)
    src  []byte        // source buffer
    err  ErrorHandler  // callback: func(pos token.Position, msg string)

    ch         rune    // current character
    offset     int     // byte offset of ch
    rdOffset   int     // reading offset (position after ch)
    insertSemi bool    // insert semicolon before next newline
    ErrorCount int
}
```

One-character lookahead via `ch`. Tracks `offset`/`rdOffset` pair (same concept as our `start`/`current`).

### Scanning approach

`Scan()` returns `(pos, tok, lit)` one token at a time. Character-by-character dispatch with helpers:

```go
func (s *Scanner) Scan() (token.Pos, token.Token, string) {
    s.skipWhitespace()
    switch ch := s.ch; {
    case isLetter(ch):     return s.scanIdentifier()
    case isDecimal(ch):    return s.scanNumber()
    default:
        switch ch {
        case '"':          return s.scanString()
        case '\'':         return s.scanRune()
        case '+':          tok = s.switch2(ADD, ADD_ASSIGN)  // + or +=
        // ...
        }
    }
}
```

Multi-character operators use `switch2`/`switch3`/`switch4` helpers — e.g. `switch3(LSS, LEQ, SHL, SHL_ASSIGN)` handles `<`, `<=`, `<<`, `<<=`. This is more compact than our nested if/match approach.

### Automatic semicolon insertion (ASI)

Go's most distinctive scanner feature. The `insertSemi` flag is set after tokens that could end a statement:

```go
// After scanning IDENT, INT, FLOAT, STRING, BREAK, CONTINUE,
// FALLTHROUGH, RETURN, INC, DEC, RPAREN, RBRACK, RBRACE:
s.insertSemi = true
```

When a newline is encountered and `insertSemi` is true, the scanner emits a `SEMICOLON` token. This is why Go doesn't need explicit semicolons — the scanner inserts them based on the preceding token.

### Keyword lookup

```go
var keywords map[string]Token   // runtime hash map

func init() {
    keywords = make(map[string]Token, keyword_end-(keyword_beg+1))
    for i := keyword_beg + 1; i < keyword_end; i++ {
        keywords[tokens[i]] = i
    }
}

func Lookup(ident string) Token {
    if tok, is_keyword := keywords[ident]; is_keyword {
        return tok
    }
    return IDENT
}
```

Simple runtime `map[string]Token` — the standard library even has a TODO comment: `// TODO: opt: use a perfect hash function instead of a global map.`

The **compiler** fixes this with a perfect hash:

```go
func hash(s []byte) uint {
    return (uint(s[0])<<4 ^ uint(s[1]) + uint(len(s))) & uint(len(keywordMap)-1)
}

var keywordMap [1 << 6]token   // 64-entry array

func init() {
    for tok := _Break; tok <= _Var; tok++ {
        h := hash([]byte(tok.String()))
        if keywordMap[h] != 0 {
            panic("imperfect hash")   // fail fast if hash collides
        }
        keywordMap[h] = tok
    }
}
```

64-entry fixed array with compile-time collision check. For 25 keywords this gives O(1) lookup with no heap allocation.

### Compiler scanner differences

The compiler's scanner pre-computes operator information during scanning:

```go
type scanner struct {
    source
    nlsemi bool     // newline-to-semicolon flag

    tok    token
    op     Operator // valid for _Operator, _Star, _AssignOp, _IncOp
    prec   int      // pre-computed precedence
}
```

Instead of querying `tok.Precedence()` during parsing, the scanner stores `op` and `prec` directly. The parser can check `p.prec > prec` without a method call.

## Parser

### Parser struct (standard library)

```go
type parser struct {
    file    *token.File
    errors  scanner.ErrorList
    scanner scanner.Scanner

    pos token.Pos    // one-token lookahead
    tok token.Token
    lit string

    syncPos token.Pos  // error recovery position
    syncCnt int        // error recovery counter
    nestLev int        // recursion depth limiting
}
```

Standard single-token lookahead. Error recovery tracks sync position to prevent infinite loops.

### Expression parsing: precedence climbing

Go uses **precedence climbing** — similar to Pratt parsing but expressed as a recursive loop:

```go
func (p *parser) parseBinaryExpr(x ast.Expr, prec1 int) ast.Expr {
    if x == nil {
        x = p.parseUnaryExpr()
    }
    for {
        op, oprec := p.tokPrec()
        if oprec < prec1 {
            return x
        }
        pos := p.expect(op)
        y := p.parseBinaryExpr(nil, oprec+1)
        x = &ast.BinaryExpr{X: x, OpPos: pos, Op: op, Y: y}
    }
}
```

Entry point: `parseBinaryExpr(nil, token.LowestPrec+1)`. The precedence levels are defined on the token:

```go
func (op Token) Precedence() int {
    switch op {
    case LOR:                                          return 1  // ||
    case LAND:                                         return 2  // &&
    case EQL, NEQ, LSS, LEQ, GTR, GEQ:                return 3
    case ADD, SUB, OR, XOR:                            return 4
    case MUL, QUO, REM, SHL, SHR, AND, AND_NOT:       return 5
    }
    return LowestPrec
}
```

Only **5 binary precedence levels** — Go's operator set is deliberately minimal.

### Recursion protection

```go
const maxNestLev = 1e5

func incNestLev(p *parser) {
    p.nestLev++
    if p.nestLev > maxNestLev {
        p.error(p.pos, "exceeded max nesting depth")
        panic(bailout{})
    }
}
```

Prevents stack overflow from malicious/malformed input. Our interpreter doesn't have this yet.

### Error recovery

Same concept as our panic mode — skip tokens until a synchronization point:

```go
func (p *parser) advance(to map[token.Token]bool) {
    for ; p.tok != token.EOF; p.next() {
        if to[p.tok] { return }
    }
}
```

The parser maintains `syncPos`/`syncCnt` to prevent cascading errors from triggering infinite advance loops.

## AST

### Node interfaces

Go uses **interfaces** rather than tagged unions for AST nodes:

```go
type Node interface {
    Pos() token.Pos   // position of first character
    End() token.Pos   // position after last character
}

type Expr interface { Node; exprNode() }
type Stmt interface { Node; stmtNode() }
type Decl interface { Node; declNode() }
```

The marker methods (`exprNode()`, `stmtNode()`, `declNode()`) enforce type safety at compile time — only types that explicitly implement them can be used as expressions/statements/declarations.

### Expression nodes

```go
type BinaryExpr struct {
    X     Expr       // left operand
    OpPos token.Pos  // operator position
    Op    token.Token
    Y     Expr       // right operand
}

type UnaryExpr struct {
    OpPos token.Pos
    Op    token.Token
    X     Expr
}

type CallExpr struct {
    Fun      Expr     // function
    Lparen   token.Pos
    Args     []Expr
    Ellipsis token.Pos  // for f(args...)
    Rparen   token.Pos
}

type Ident struct {
    NamePos token.Pos
    Name    string
    Obj     *Object    // resolved object (filled by resolver, not parser)
}
```

Every node records source positions for error messages and formatting tools like `gofmt`.

### Compiler nodes (more compact)

The compiler unifies binary and unary expressions:

```go
type Operation struct {
    Op Operator
    X  Expr
    Y  Expr   // nil for unary operations
}
```

One struct instead of two — more compact, fewer types to switch on.

### Contrast with our AST

| Aspect | Go (stdlib) | Go (compiler) | Ours |
|--------|-------------|---------------|------|
| Node type | Interface + struct | Interface + struct | Tagged union |
| Children | Pointers via interface | Pointers via interface | Pointers in union fields |
| Expr/Stmt split | Separate interfaces | Separate interfaces | Separate tagged unions |
| Binary/Unary | Two distinct structs | Single `Operation` struct | Separate union variants |
| Position info | Start + End per node | Start per node | Line number per token |
| Dispatch | Type switch | Type switch | Switch on tag |

Go's interface approach enables open-ended extension (add new node types without modifying existing code), while our tagged union approach gives exhaustive matching at compile time.

## Error Handling

### Scanner errors

The scanner uses an **error callback** — a simple function pointer installed at initialization:

```go
type ErrorHandler func(pos token.Position, msg string)
```

When the scanner encounters invalid input (bad UTF-8, unterminated strings, invalid digits), it calls the handler and **continues scanning**. The `ErrorCount` field tracks how many errors occurred. If no handler is installed, errors are silently counted.

### Error collection

The standard library provides `ErrorList` — a sortable, deduplicatable list of errors:

```go
type Error struct {
    Pos token.Position   // file, line, column
    Msg string
}

type ErrorList []*Error
```

`ErrorList.RemoveMultiples()` keeps only the first error per line — useful for suppressing cascading errors from a single mistake. The parser initializes the scanner with a handler that accumulates into this list.

### Parser error reporting

The parser's `error()` function suppresses same-line duplicates and stops after 10 errors:

```go
func (p *parser) error(pos token.Pos, msg string) {
    epos := p.file.Position(pos)
    if p.mode&AllErrors == 0 {
        n := len(p.errors)
        if n > 0 && p.errors[n-1].Pos.Line == epos.Line {
            return   // discard — likely a spurious cascading error
        }
        if n > 10 {
            panic(bailout{})   // stop parsing entirely
        }
    }
    p.errors.Add(epos, msg)
}
```

`errorExpected()` builds context-aware messages — it appends what was actually found:

```go
// "expected ')', found newline"
// "expected expression, found 'break'"
```

### Error recovery: synchronization sets

After an error, the parser skips tokens until reaching a **synchronization point** — a token that's likely to start a new valid construct:

```go
var stmtStart = map[token.Token]bool{
    token.BREAK: true, token.CONST: true, token.CONTINUE: true,
    token.DEFER: true, token.FOR: true, token.GO: true,
    token.IF: true, token.RETURN: true, token.SWITCH: true,
    token.TYPE: true, token.VAR: true,
}
```

A `syncPos`/`syncCnt` mechanism prevents infinite loops — if the parser calls `advance()` without making forward progress, it gives up after 10 attempts.

The **compiler** parser uses a bitmask instead of a hash map for the sync set, and includes `fnest` (function nesting level) to decide which sync tokens are valid in the current context.

### Contrast with our error handling

| Aspect | Go | Ours |
|--------|-----|------|
| Scanner errors | Callback, continues scanning | `report_error()`, continues scanning |
| Parser errors | Accumulates in `ErrorList` | Sets `had_error` flag |
| Error limit | Stops after 10 | No limit |
| Same-line dedup | Yes | No |
| Recovery | Skip to sync set (statement keywords) | Returns `ParseError`, no sync |
| Message format | `"expected ')', found 'break'"` | `"[<inline>:42] Expected expression"` |
| Nesting protection | `maxNestLev = 100,000` | None |

## Comparison with our interpreter

| Aspect | Go | Ours |
|--------|-----|------|
| Scanner | Character-by-character, switch dispatch | Same approach |
| Token count | ~80 (operators, keywords, literals) | ~40 |
| Keywords | 25, runtime hash map (stdlib) / perfect hash (compiler) | ~20, comptime static map |
| ASI | Automatic semicolon insertion | No semicolons |
| Parser | Recursive descent + precedence climbing | Recursive descent (call chain) |
| Precedence levels | 5 binary + unary | ~10 |
| AST | Go interfaces + structs, heap-allocated | Zig tagged unions, arena-allocated |
| Error recovery | Skip to sync token, cascading error limit | Simple error flag |
| Nesting limit | 100,000 | None |
| Execution | Compilation to machine code | Tree-walk interpretation |

The most instructive comparison is in expression parsing — Go's precedence climbing (`parseBinaryExpr` with explicit levels) vs our call-chain encoding (`equality` → `comparison` → `term` → etc.). Both are correct; the climbing approach scales better when precedence levels change or new operators are added.

#go #tokenizer #parser #ast #reference
