# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A tree-walking Lox interpreter written in Zig, following [Crafting Interpreters](https://craftinginterpreters.com/) (currently up to chapter 8, section 8.5.2: Statements and State / Scoping).

## Build & Run

```bash
zig build              # build the interpreter
zig build test         # run all tests (auto-discovers *_test.zig in src/)
zig build run -- file.lox   # run a Lox script
zig build run          # start the REPL
```

`make` runs `zig build test` by default.

## Architecture

The interpreter is a classic pipeline: source text → scanner → parser → AST → tree-walk interpreter.

**Pipeline flow** (`driver.zig` orchestrates):
1. **Scanner** (`scanner.zig`) — tokenizes source into `Token` array. Uses a compile-time static map for keyword lookup.
2. **Parser** (`parser.zig`) — recursive descent parser producing an AST. Operator precedence is encoded in the call chain: `expression → assignment → equality → comparison → term → factor → unary → primary`. Uses `SegmentedList` for pointer stability of AST nodes.
3. **AST** (`ast.zig`) — `Expr` and `Stmt` are tagged unions. `LoxValue` is a union of `f64 | bool | []const u8 | nil`. Nodes are constructed via a comptime `make()` helper.
4. **Interpreter** (`interpreter.zig`) — evaluates AST nodes recursively. Manages a chain of `Environment` scopes for variable lookup.
5. **Environment** (`environment.zig`) — `StringHashMap(LoxValue)` with an `enclosing` pointer for lexical scoping. Each block creates a new environment linked to its parent.

**Entry point** (`main.zig`) — parses CLI args, sets up `DebugAllocator` (leak detection), dispatches to REPL or file execution via `Driver`.

## Memory Management

- Top-level `DebugAllocator` catches leaks (asserted on exit)
- `ArenaAllocator` for AST nodes and parser allocations
- Per-environment `ArenaAllocator` (`stores`) for string values
- `SegmentedList` used instead of `ArrayList` where pointer stability is needed (AST nodes, block statements)

## Currently Implemented Lox Features

Literals, arithmetic/comparison/equality operators, unary operators, string concatenation, `print` statements, variable declarations/assignment, blocks with lexical scoping.

**Not yet implemented:** control flow (`if`/`while`/`for`), logical operators (`and`/`or`), functions, classes.

## Example Programs

`examples/*.lox` — small programs demonstrating implemented features. New examples should follow the existing style: a comment on the first line describing the program, then straightforward code using only implemented features.
