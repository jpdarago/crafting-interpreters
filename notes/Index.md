# Reference Projects

Notes on how other projects implement scanning and parsing, for comparison with our tree-walking Lox interpreter.

## Projects

- [[Zig Compiler]] - The self-hosted Zig compiler. Allocation-free tokenizer, data-oriented AST with `MultiArrayList`.
- [[Aro (C Compiler)]] - Full C23 compiler in Zig. Closest architecture to our pipeline.
- [[Bun (JS Parser)]] - Production JS/TS parser. Shows how Zig handles a complex real-world grammar.
- [[zig-lox]] - Lox bytecode VM in Zig. Same language, different execution model (Pratt parsing + bytecode).
- [[Go (Compiler)]] - Go toolchain scanner/parser (in Go). Precedence climbing, automatic semicolon insertion, interface-based AST.
- [[Lua]] - PUC-Rio Lua implementation (in C). Single-pass compiler with no AST — direct bytecode emission via `expdesc`. Lox's primary inspiration.
- [[Dart (SDK)]] - Dart SDK front-end (in Dart). Linked-list tokens, listener-pattern parser, trie-based keyword lookup.

## Quick Comparison

| Aspect | Our Interpreter | Zig Compiler | Aro | Bun | zig-lox | Go | Lua | Dart |
|--------|----------------|--------------|-----|-----|---------|-----|-----|------|
| **Tokenizer** | Switch-based, builds token array | Allocation-free state machine | State machine (~35 states) | Comptime-configurable, WTF-8 | Slice-based, trie keyword lookup | Switch-based, ASI | Switch-based, ASCII-as-token | Linked-list tokens, bit-packed |
| **Parser** | Recursive descent | Recursive descent (two-pass) | Recursive descent (10K lines) | Recursive descent | Pratt + recursive descent | Recursive descent + prec. climbing | Precedence climbing (single-pass) | Listener pattern + prec. loop |
| **AST** | Tagged unions (`Expr`/`Stmt`) | `MultiArrayList` (SoA) | `MultiArrayList` (SoA) | Tagged union pointers (24-byte cap) | No AST (direct bytecode emit) | Interface + structs | No AST (direct bytecode emit) | Built by listener, not parser |
| **Precedence** | Call chain encoding | Call chain encoding | Call chain encoding | Call chain encoding | Pratt precedence table | Precedence climbing (5 levels) | Priority table (left/right) | Loop-based (17 levels) |
| **Keywords** | Comptime static map | Comptime `StaticStringMap` | Comptime `ComptimeStringMap` | Comptime `ComptimeStringMap` | Runtime trie dispatch | Runtime hash map / perfect hash | String interning + tag field | Trie automaton (flat array) |
| **Memory** | Arena allocators | Pre-allocated arrays | Arena + SoA | Thread-local pools + indices | GC (mark-and-sweep) | GC (Go runtime) | Manual C + GC | GC (Dart runtime) |
| **Execution** | Tree-walk | Compilation to machine code | Compilation | Bundling/transpilation | Bytecode VM | Compilation to machine code | Bytecode VM | Compilation (AOT/JIT) |
| **Error recovery** | `had_error` flag, no sync | Accumulate errors, skip to container | Configurable diagnostics (75+ `-W` flags) | Centralized log, continue | Panic mode + synchronize | ErrorList, skip to sync set, 10-error limit | No recovery (first error aborts via `longjmp`) | Synthetic token insertion, listener-based |
| **Error format** | `[file:line] msg` | ErrorBundle with source context | GCC/Clang-compatible with macro backtrace | Source line + caret + notes | `[line N] Error at 'tok': msg` | `expected X, found Y` with context | `file:line: msg near 'token'` | Structured (problem + correction) |

## Key Patterns Worth Studying

- **Allocation-free tokenizer** ([[Zig Compiler#Tokenizer]]) - no allocations during scanning
- **MultiArrayList for AST** ([[Zig Compiler#AST]]) - struct-of-arrays for cache efficiency
- **Pratt parsing** ([[zig-lox#Compiler (Pratt Parsing)]]) - alternative to recursive descent for expressions
- **Short-circuit via jump patching** ([[zig-lox#Logical Operators]]) - how `and`/`or` compile to jumps
- **Comptime configuration** ([[Bun (JS Parser)#Lexer]]) - `NewLexer()` with compile-time feature flags
- **Automatic semicolon insertion** ([[Go (Compiler)#Automatic semicolon insertion (ASI)]]) - Go's newline-to-semicolon trick
- **Precedence climbing** ([[Go (Compiler)#Expression parsing: precedence climbing]]) - loop-based alternative to call-chain precedence
- **Expression descriptors** ([[Lua#expdesc — the expression descriptor]]) - Lua's key to single-pass compilation without AST
- **String interning for keywords** ([[Lua#Keyword lookup via string interning]]) - tag interned strings to identify reserved words
- **Listener pattern** ([[Dart (SDK)#The listener pattern]]) - decouple parsing from AST construction
- **Linked-list tokens** ([[Dart (SDK)#Token class — a doubly-linked list]]) - enable speculative parsing and synthetic token insertion
- **Panic mode recovery** ([[zig-lox#Error Handling]]) - simplest effective error recovery (suppress cascading errors, sync at statement keywords)
- **No-recovery design** ([[Lua#Error Handling]]) - Lua's deliberate choice to abort on first error (via `longjmp`)
- **Configurable diagnostics** ([[Aro (C Compiler)#Error Handling]]) - GCC/Clang-style `-W` flags with per-warning severity control
- **Synthetic token insertion** ([[Dart (SDK)#Error Handling]]) - insert fake tokens to complete broken constructs for IDE use
- **Synchronization sets** ([[Go (Compiler)#Error Handling]]) - skip to statement-start keywords with progress tracking to prevent infinite loops

#index #reference
