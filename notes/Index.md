# Reference Projects

Notes on how other Zig projects implement scanning and parsing, for comparison with our tree-walking Lox interpreter.

## Projects

- [[Zig Compiler]] - The self-hosted Zig compiler. Allocation-free tokenizer, data-oriented AST with `MultiArrayList`.
- [[Aro (C Compiler)]] - Full C23 compiler in Zig. Closest architecture to our pipeline.
- [[Bun (JS Parser)]] - Production JS/TS parser. Shows how Zig handles a complex real-world grammar.
- [[zig-lox]] - Lox bytecode VM in Zig. Same language, different execution model (Pratt parsing + bytecode).

## Quick Comparison

| Aspect | Our Interpreter | Zig Compiler | Aro | Bun | zig-lox |
|--------|----------------|--------------|-----|-----|---------|
| **Tokenizer** | Switch-based, builds token array | Allocation-free state machine | State machine (~35 states) | Comptime-configurable, WTF-8 | Slice-based, trie keyword lookup |
| **Parser** | Recursive descent | Recursive descent (two-pass) | Recursive descent (10K lines) | Recursive descent | Pratt + recursive descent |
| **AST** | Tagged unions (`Expr`/`Stmt`) | `MultiArrayList` (SoA) | `MultiArrayList` (SoA) | Tagged union pointers (24-byte cap) | No AST (direct bytecode emit) |
| **Precedence** | Call chain encoding | Call chain encoding | Call chain encoding | Call chain encoding | Pratt precedence table |
| **Keywords** | Comptime static map | Comptime `StaticStringMap` | Comptime `ComptimeStringMap` | Comptime `ComptimeStringMap` | Runtime trie dispatch |
| **Memory** | Arena allocators | Pre-allocated arrays | Arena + SoA | Thread-local pools + indices | GC (mark-and-sweep) |
| **Execution** | Tree-walk | Compilation to machine code | Compilation | Bundling/transpilation | Bytecode VM |

## Key Patterns Worth Studying

- **Allocation-free tokenizer** ([[Zig Compiler#Tokenizer]]) - no allocations during scanning
- **MultiArrayList for AST** ([[Zig Compiler#AST]]) - struct-of-arrays for cache efficiency
- **Pratt parsing** ([[zig-lox#Compiler (Pratt Parsing)]]) - alternative to recursive descent for expressions
- **Short-circuit via jump patching** ([[zig-lox#Logical Operators]]) - how `and`/`or` compile to jumps
- **Comptime configuration** ([[Bun (JS Parser)#Lexer]]) - `NewLexer()` with compile-time feature flags

#index #reference
