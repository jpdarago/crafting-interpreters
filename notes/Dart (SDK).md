# Dart (SDK)

The Dart SDK's front-end scanner and parser, written in Dart. Uses the **Fasta** (Fast Analyzer) infrastructure — a production scanner/parser designed for IDE responsiveness and incremental compilation. The most architecturally distinct of all reference projects: tokens form a **linked list**, and the parser uses a **listener pattern** instead of building an AST directly.

**Source files (scanner):**
- `references/dart/pkg/_fe_analyzer_shared/lib/src/scanner/token.dart` (~2,930 lines) — token classes and types
- `references/dart/pkg/_fe_analyzer_shared/lib/src/scanner/abstract_scanner.dart` (~2,590 lines) — scanner implementation
- `references/dart/pkg/_fe_analyzer_shared/lib/src/scanner/keyword_state.dart` (~73 lines) — keyword trie automaton

**Source files (parser):**
- `references/dart/pkg/_fe_analyzer_shared/lib/src/parser/parser_impl.dart` (~12,350 lines) — main parser
- `references/dart/pkg/_fe_analyzer_shared/lib/src/parser/listener.dart` (~2,450 lines) — listener interface

## Scanner

### Token class — a doubly-linked list

Dart's most distinctive scanner feature: tokens are **linked list nodes**, not array elements.

```dart
class SimpleToken extends SyntacticEntity implements Token {
  // Type (8 bits) and offset (24 bits) packed into one int
  int _typeAndOffset;

  TokenType get type => _tokenTypesByIndex[_typeAndOffset & 0xff];
  int get offset => (_typeAndOffset >> 8) - 1;

  Token? previous;    // previous token in stream
  Token? next;        // next token in stream

  CommentToken? _precedingComment;  // comment chain
}
```

**Bit packing:** Token type index (8 bits) and source offset (24 bits) are combined into a single `int`, reducing per-token memory. The type is recovered via a 256-entry lookup array.

**Token hierarchy:**
```
SimpleToken
├── StringToken        — carries the string value of the token
│   ├── CommentToken   — comments form a separate linked chain
│   ├── KeywordToken   — keyword instances
│   └── SyntheticToken — inserted during error recovery
└── BeginToken         — grouping openers: (, [, {, <
    └── endToken → links to matching closer
```

`BeginToken` links to its matching close delimiter — parentheses, brackets, and braces are pre-matched during scanning, so the parser can skip balanced groups in O(1).

### Scanning approach

The scanner builds the linked list in a single forward pass. Entry points:

```dart
scan(Uint8List bytes)     // binary input
scanString(String source) // string input
```

Produces a linked token stream starting with a synthetic first token and ending with EOF (which points to itself for safe infinite lookahead).

### Keyword lookup: trie automaton

Instead of a hash map, Dart uses a **pre-built trie** stored as a flat `Uint16List`:

```dart
class KeywordStateHelper {
  static Uint16List? _table;
  static KeywordState get table {
    Uint16List table = _table = new Uint16List(297 * KeywordState.blockSize);
    int nextEmpty = 2 * KeywordState.blockSize;
    for (int i = 0; i < Keyword.values.length; i++) {
      Keyword keyword = Keyword.values[i];
      String lexeme = keyword.lexeme;
      int offset = KeywordState.blockSize;
      for (int j = 0; j < lexeme.length; j++) {
        int charOffset = lexeme.codeUnitAt(j) - $A;
        int link = table[offset + 1 + charOffset];
        if (link == 0) {
          table[offset + 1 + charOffset] = nextEmpty;
          offset = nextEmpty;
          nextEmpty += KeywordState.blockSize;
        } else {
          offset = link;
        }
      }
      table[offset] = i + 1;  // keyword index (+1, so 0 = no keyword)
    }
  }
}
```

The trie is built once and stored as a flat array. Lookup walks character-by-character — O(keyword length) with cache-friendly memory access. Each block has one slot for the keyword index and slots for transitions indexed by character code.

### Dart keywords: 61 total, three categories

```dart
enum KeywordStyle { reserved, builtIn, pseudo }
```

- **Reserved** (33): `if`, `else`, `for`, `while`, `class`, `extends`, `return`, `var`, `final`, `const`, `void`, `true`, `false`, `null`, etc.
- **Built-in** (18): `abstract`, `as`, `dynamic`, `export`, `factory`, `get`, `set`, `typedef`, `operator`, etc. — can't be type names but can be identifiers elsewhere.
- **Pseudo** (10): `async`, `await`, `yield`, `show`, `hide`, `of`, `on`, `when`, etc. — only reserved in specific contexts.

This three-level system is far more complex than our binary reserved/not-reserved approach, but allows Dart to add keywords without breaking existing code.

### Precedence constants

```dart
const int NO_PRECEDENCE = 0;
const int ASSIGNMENT_PRECEDENCE = 1;
const int CASCADE_PRECEDENCE = 2;
const int CONDITIONAL_PRECEDENCE = 3;
const int IF_NULL_PRECEDENCE = 4;         // ??
const int LOGICAL_OR_PRECEDENCE = 5;
const int LOGICAL_AND_PRECEDENCE = 6;
const int EQUALITY_PRECEDENCE = 7;
const int RELATIONAL_PRECEDENCE = 8;
const int BITWISE_OR_PRECEDENCE = 9;
const int BITWISE_XOR_PRECEDENCE = 10;
const int BITWISE_AND_PRECEDENCE = 11;
const int SHIFT_PRECEDENCE = 12;
const int ADDITIVE_PRECEDENCE = 13;
const int MULTIPLICATIVE_PRECEDENCE = 14;
const int PREFIX_PRECEDENCE = 15;
const int POSTFIX_PRECEDENCE = 16;
const int SELECTOR_PRECEDENCE = 17;
```

17 precedence levels — more than Go (5), more than Lua (~14), more than ours (~10). Includes Dart-specific levels for cascades (`..`) and if-null (`??`).

## Parser

### The listener pattern

Dart's parser is the most architecturally unusual of all reference projects. Instead of building an AST directly, the parser **emits events** to a `Listener` object:

```dart
abstract class Listener implements UnescapeErrorListener {
  void beginArguments(Token token) {}
  void endArguments(int count, Token beginToken, Token endToken) {}

  void beginBlock(Token token, BlockKind blockKind) {}
  void endBlock(int count, Token beginToken, Token endToken, BlockKind blockKind) {}

  void beginIfStatement(Token token) {}
  void endIfStatement(Token ifToken, Token? elseToken) {}

  void handleBinaryExpression(Token token) {}
  void handleIdentifier(Token token, IdentifierContext context) {}
  void handleLiteralInt(Token token) {}
  // ... ~200 methods
}
```

Methods follow three patterns:
- **`begin*`/`end*` pairs** — bracket constructs (blocks, if statements, classes)
- **`handle*` singletons** — atomic events (literals, identifiers, operators)
- **`handleRecoverableError`** — error recovery events

This decouples parsing from AST construction. Different listeners can:
- Build an AST (the analyzer's `AstBuilder`)
- Build kernel IR (the compiler's `BodyBuilder`)
- Do nothing (the `NullListener` used for speculative parsing)
- Count or validate (for IDE features)

### Expression parsing: precedence loop

Dart uses a loop-based Pratt-style approach inside `parsePrecedenceExpression`:

```dart
Token parsePrecedenceExpression(
    Token token, int precedence, bool allowCascades,
    ConstantPatternContext constantPatternContext) {
  // Parse prefix (unary expression or atom)
  token = parseUnaryExpression(token, allowCascades, constantPatternContext);

  // Loop: while next operator has sufficient precedence
  return _parsePrecedenceExpressionLoop(
      precedence, allowCascades, typeArg, token, constantPatternContext);
}

Token _parsePrecedenceExpressionLoop(int precedence, ..., Token token, ...) {
  Token next = token.next!;
  TokenType type = next.type;
  int tokenLevel = _computePrecedence(next, forPattern: ...);

  while (tokenLevel >= precedence) {
    // handle the operator: binary, cascade, conditional, is/as, etc.
    Token operator = next;
    if (tokenLevel == CASCADE_PRECEDENCE) {
      token = parseCascadeExpression(token);
    } else if (tokenLevel == ASSIGNMENT_PRECEDENCE) {
      token = parseAssignmentExpression(token);
    } else if (tokenLevel == CONDITIONAL_PRECEDENCE) {
      token = parseConditionalExpressionRest(token);
    } else {
      // binary operator
      token = parsePrecedenceExpression(
          operator, tokenLevel + 1, allowCascades, ...);
      listener.handleBinaryExpression(operator);
    }
    next = token.next!;
    tokenLevel = _computePrecedence(next, forPattern: ...);
  }
  return token;
}
```

Instead of calling functions per precedence level, the parser has **one loop** that dispatches on precedence category. The `listener.handleBinaryExpression(operator)` call replaces AST node construction.

### Speculative parsing

Dart uses an `UndoableTokenStreamRewriter` for speculative parsing — for example, to determine if `?` starts a conditional expression or a nullable type:

```dart
bool canParseAsConditional(Token question) {
  Listener originalListener = listener;
  listener = new NullListener();           // discard events
  cachedRewriter = new UndoableTokenStreamRewriter();

  bool isConditional = false;
  Token afterExpression1 = parseExpressionWithoutCascade(question);
  if (!nullListener.hasErrors && afterExpression1.next!.isA(TokenType.COLON)) {
    parseExpressionWithoutCascade(afterExpression1.next!);
    if (!nullListener.hasErrors) isConditional = true;
  }

  undoableTokenStreamRewriter.undo();      // restore token stream
  listener = originalListener;             // restore real listener
  return isConditional;
}
```

This is possible because the linked-list token stream can be modified and restored. With our array-based tokens, backtracking would require saving/restoring an index.

### Error recovery

Dart's error recovery is sophisticated — designed for IDE use where partial/broken code is the norm:
- **`SyntheticToken`** and **`SyntheticKeywordToken`** — inserted into the token stream to complete expected constructs
- **`ReplacementToken`** — wraps invalid tokens while keeping originals for tooling
- **`handleRecoverableError()`** — listener call, allowing different responses (the IDE can still show completions)

### Parser size

At **~12,350 lines**, `parser_impl.dart` is the largest parser in our reference set. For comparison:
- Aro (C compiler): ~10,900 lines
- Go (standard library): ~2,960 lines
- Our Lox parser: ~500 lines
- Lua parser: ~2,200 lines

The size comes from Dart's complex grammar (generics, async/await, patterns, extensions, mixins, cascades, null safety) and extensive error recovery.

## AST

The AST is **not built by the parser** — it's built by listener implementations. The analyzer's AST uses abstract classes:

```dart
// In the analyzer package
abstract class Expression implements AstNode { ... }
abstract class Statement implements AstNode { ... }
abstract class Declaration implements AstNode { ... }

abstract class BinaryExpression implements Expression {
  Expression get leftOperand;
  Token get operator;
  Expression get rightOperand;
}

abstract class IfStatement implements Statement {
  Token get ifKeyword;
  Expression get expression;
  Statement get thenStatement;
  Token? get elseKeyword;
  Statement? get elseStatement;
}
```

Each node type is an abstract class with concrete implementations that store the actual data. This is similar to Go's interface approach but with stronger typing.

## Error Handling

Dart has the most sophisticated error handling of all reference projects — designed for IDE use where broken, partial code is the norm.

### Scanner: error tokens in the stream

Instead of callbacks or flags, the scanner creates **error token objects** and inserts them into the linked list:

```dart
abstract class ErrorToken extends SimpleToken {
  ErrorToken(int offset) : super(TokenType.BAD_INPUT, offset, null);
  Message get assertionMessage;   // structured error message
}
```

Specific subtypes for different failures:
- `UnterminatedString` — unclosed string literal (tracks opening quote position)
- `UnmatchedToken` — unbalanced bracket/paren (links to the opening `BeginToken`)
- `UnsupportedOperator` — operators not in Dart (e.g., `===`, `!==`)
- `NonAsciiIdentifierToken` — non-ASCII character outside string (stores the code point)
- `AsciiControlCharacterToken` — control characters in source

The scanner continues after every error — no error is fatal. Error tokens sit in the stream alongside normal tokens, and the parser decides how to handle them.

### Parser: synthetic token insertion

When the parser expects a token that isn't there, it **inserts a synthetic token** into the linked list rather than just reporting an error:

```dart
class SyntheticToken extends SimpleToken {
  @override bool get isSynthetic => true;
  @override int get length => 0;   // synthetic tokens have zero width
  Token? beforeSynthetic;          // tracks insertion point
}
```

Examples of recovery:
- Missing `)` → insert `SyntheticToken(TokenType.CLOSE_PAREN, offset)`
- Missing identifier → insert `SyntheticStringToken(TokenType.IDENTIFIER, '', offset)`
- Missing keyword → insert `SyntheticKeywordToken(Keyword.FUNCTION, offset)`

`ReplacementToken` wraps an invalid token while keeping the original for tooling — the IDE can still show completions based on what the user actually typed.

### Error reporting via listener

Errors flow through the same listener pattern as everything else:

```dart
abstract class Listener {
  void handleRecoverableError(
    Message message, Token startToken, Token endToken) {}

  void handleErrorToken(ErrorToken token) {
    handleRecoverableError(token.assertionMessage, token, token);
  }
}
```

This decouples error policy from error detection:
- The compiler's listener collects errors in a list
- The IDE's listener displays inline diagnostics
- The `NullListener` (for speculative parsing) silently discards errors

### Structured error messages

Error messages are **structured objects** with separate problem and correction text:

```dart
const MessageCode abstractClassMember = const MessageCode(
  "AbstractClassMember",
  problemMessage: "Members of classes can't be declared to be 'abstract'.",
  correctionMessage: "Try removing the 'abstract' keyword.",
);
```

Template messages interpolate runtime values:

```dart
Message _withArgumentsUnexpectedToken({required Token lexeme}) {
  return new Message(
    unexpectedToken,
    problemMessage: "Unexpected token '${lexeme.lexeme}'.",
  );
}
```

### Contrast with our error handling

| Aspect | Dart | Ours |
|--------|------|------|
| Scanner errors | Error tokens in stream | `report_error()`, continues |
| Parser recovery | Synthetic token insertion | Returns `ParseError` |
| Error channel | Listener callback | Direct stderr write |
| Multiple errors | Yes (all collected) | Yes (flag-based) |
| Message format | Structured (problem + correction) | Plain string |
| Error context | Start token + end token range | Line number only |
| Speculative parsing | NullListener discards errors | Not supported |

Dart's approach is the most complex but also the most user-friendly — synthetic tokens mean the parser always produces a complete (if partially wrong) result, and structured messages with corrections guide users to fixes.

## Comparison with our interpreter

| Aspect | Dart (SDK) | Ours |
|--------|-----------|------|
| Language | Dart (~18,000 lines scanner+parser) | Zig (~500 lines) |
| Token structure | Doubly-linked list | ArrayList |
| Token data | Bit-packed type + offset | Tag + lexeme slice + line |
| Keywords | 61 (3 categories), trie automaton | ~20 (all reserved), comptime hash map |
| Keyword context | Reserved / built-in / pseudo | All reserved |
| Parser pattern | Listener events (decoupled from AST) | Direct AST construction |
| Expression parsing | Loop-based precedence (17 levels) | Call-chain encoding (~10 levels) |
| AST building | Separate listener implementations | Inline in parser |
| Error recovery | Synthetic tokens, undoable rewrites | Simple error flag |
| Speculative parsing | Yes (NullListener + undo) | No |
| Bracket matching | Pre-matched during scanning | Checked during parsing |

### Key insight

The listener pattern is Dart's most novel contribution. By decoupling "how to parse" from "what to build", the same parser serves the compiler (builds kernel IR), the analyzer (builds AST for refactoring), the formatter (only needs structure), and the IDE (needs partial results from broken code). Our parser tightly couples parsing with AST construction — simpler, but means the parser can only produce one thing.

The linked-list token stream enables features impossible with arrays: synthetic token insertion, undoable modifications, and O(1) bracket group skipping. The trade-off is more complex memory management and loss of cache locality.

#dart #listener-pattern #linked-list #trie #precedence-loop #reference
