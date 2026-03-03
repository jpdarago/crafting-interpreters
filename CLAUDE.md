# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A tree-walking Lox interpreter written in Zig, following [Crafting Interpreters](https://craftinginterpreters.com/) (currently in chapter 10: Functions, section 10.2.1).

## Toolchain

- **Zig 0.15.1** — provided automatically via [devenv](https://devenv.sh/) / Nix (`devenv.nix`), or install manually
- **ZLS** — available via devenv at `$ZLS_LOCATION`
- **Pre-commit hook** — `scripts/git-hooks/pre-commit` runs `zig fmt` on staged `.zig` files

## Build & Run

```bash
zig build              # build the interpreter
zig build test         # run all tests (auto-discovers *_test.zig in src/)
zig build run -- file.lox   # run a Lox script
zig build run          # start the REPL
zig build clean        # remove .zig-cache and zig-out
zig build examples     # run all examples/*.lox files
```

There is no way to run a single test file; `zig build test` runs all `*_test.zig` files. You can run a single named test with `zig build test -- --test-filter "test name"`.

## Architecture

The interpreter is a classic pipeline: source text → scanner → parser → AST → tree-walk interpreter.

**Pipeline flow** (`driver.zig` orchestrates):
1. **Scanner** (`scanner.zig`) — tokenizes source into `Token` array. Uses a compile-time static map for keyword lookup.
2. **Parser** (`parser.zig`) — recursive descent parser producing an AST. Operator precedence is encoded in the call chain: `expression → assignment → or_expr → and_expr → equality → comparison → term → factor → unary → primary`. Uses `SegmentedList` for pointer stability of AST nodes.
3. **AST** (`ast.zig`) — `Expr` and `Stmt` are tagged unions. `LoxValue` is a union of `f64 | bool | []const u8 | nil | LoxCallable`. `LoxCallable` is a tagged union of `NativeFunction | LoxFunction`, replacing Java's `LoxCallable` interface. Nodes are constructed via a comptime `make()` helper.
4. **Interpreter** (`interpreter.zig`) — evaluates AST nodes recursively. Manages a chain of `Environment` scopes for variable lookup.
5. **Environment** (`environment.zig`) — `StringHashMap(LoxValue)` with an `enclosing` pointer for lexical scoping. Each block creates a new environment linked to its parent.

**Entry point** (`main.zig`) — parses CLI args, sets up `DebugAllocator` (leak detection), dispatches to REPL or file execution via `Driver`.

**Supporting modules:**
- `diagnostics.zig` — error reporting (tracks `had_error`, writes to stderr)
- `errors.zig` — `ParseError` and `EvalError` error sets
- `debug.zig` — `dump()` helper for printing AST nodes to stdout

## Code Conventions

- **Self pattern:** all structs use `const Self = @This()` for self-referential types.
- **Tagged union constructors:** `Expr` and `Stmt` use a comptime `make(value)` method that infers the active union field from the value type.
- **Formatting:** use `zig fmt`. The pre-commit hook enforces this automatically.

## Memory Management

- Top-level `DebugAllocator` catches leaks (asserted on exit)
- `ArenaAllocator` for AST nodes and parser allocations
- Per-interpreter `ArenaAllocator` (`string_pool`) for concatenated string values
- `SegmentedList` used instead of `ArrayList` where pointer stability is needed (AST nodes, block statements)

## Testing

Tests live in `*_test.zig` files alongside their modules. Patterns:
- **Scanner tests** (`scanner_test.zig`) — create `Scanner`, call `scan()`, compare tokens with `checkTokens` helper.
- **Interpreter tests** (`interpreter_test.zig`) — `test_interpreter(source, expected_value)` runs the full pipeline (scan → parse → evaluate) and asserts the final `LoxValue`.
- All tests use `std.testing.allocator` (which detects leaks in test mode).

## Currently Implemented Lox Features

Literals, arithmetic/comparison/equality operators, unary operators, string concatenation, `print` statements, variable declarations/assignment, blocks with lexical scoping, `if`/`else`, logical operators (`and`/`or`), `while` loops, `for` loops, function call expressions (AST and parser done).

**In progress (chapter 10):** `LoxCallable`/`LoxFunction` types are defined in `ast.zig`. Call expression evaluation in `interpreter.zig` is partially wired up (section 10.2.1). Next steps: finish `call` evaluation, implement `fun` declaration parsing/evaluation, wire up `return` statements, add native `clock()` function.

**Not yet implemented:** closures, classes, inheritance.

## Example Programs

`examples/*.lox` — small programs demonstrating implemented features. New examples should follow the existing style: a comment on the first line describing the program, then straightforward code using only implemented features.

## Reference Material

- `book/` — the original [Crafting Interpreters](https://github.com/munificent/craftinginterpreters) repo (submodule). Java reference implementation is in `book/jlox/`, C implementation in `book/c/`.
- `references/` — git submodules of other Zig projects for comparison:
  - `references/zig` — the Zig compiler (self-hosted). Allocation-free tokenizer, `MultiArrayList` AST.
  - `references/arocc` — Aro C compiler. Closest architecture to ours (tokenizer → parser → tree).
  - `references/bun` — Bun JS/TS runtime. Production recursive descent parser in Zig.
  - `references/zig-lox` — Lox bytecode VM in Zig. Same language, Pratt parsing + bytecode execution.
- `notes/` — Obsidian vault with analysis of how each reference project implements scanning, parsing, and AST design.
