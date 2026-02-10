# Crafting Interpreters

A tree-walking Lox interpreter written in Zig, following [Crafting Interpreters](https://craftinginterpreters.com/) by Robert Nystrom.

## Progress

Currently up to **Chapter 8, Section 8.5.2** — Statements and State / Scoping.

### Implemented

- Literals: numbers, strings, booleans, `nil`
- Arithmetic operators: `+`, `-`, `*`, `/`
- Comparison and equality: `<`, `<=`, `>`, `>=`, `==`, `!=`
- Unary operators: `-` (negation), `!` (logical NOT)
- String concatenation with `+`
- `print` statements
- Variable declarations (`var`) and assignment
- Blocks `{ ... }` with lexical scoping

### Not yet implemented

- Control flow (`if`/`else`, `while`, `for`)
- Logical operators (`and`, `or`)
- Functions and closures
- Classes and inheritance

## Prerequisites

- **Zig 0.15.1** — provided automatically via [devenv](https://devenv.sh/) / Nix, or install manually

## Usage

```bash
make              # run tests (default)
make build        # build the interpreter
make test         # run all unit tests
make run          # start the REPL
make clean        # remove build artifacts
```

Run Lox scripts:

```bash
zig build run -- examples/hello.lox      # run a single script
make example F=hello                      # shorthand for the above
make examples                             # run all example programs
```

## Project Structure

```
src/
  main.zig          # entry point, CLI argument parsing
  driver.zig        # orchestrates the pipeline
  scanner.zig       # lexical analysis (source → tokens)
  parser.zig        # recursive descent parser (tokens → AST)
  ast.zig           # AST node definitions (Expr, Stmt, LoxValue)
  interpreter.zig   # tree-walk evaluator (AST → result)
  environment.zig   # lexical scope chain for variables
  diagnostics.zig   # error reporting
  errors.zig        # error type definitions
  *_test.zig        # unit tests (auto-discovered by build)
examples/           # sample Lox programs
```

## Architecture

The interpreter follows a classic multi-stage pipeline:

```
source text → Scanner → tokens → Parser → AST → Interpreter → result
```

**Scanner** tokenizes source code, using a compile-time static map for keyword lookup. **Parser** uses recursive descent with operator precedence encoded in the call chain (`expression → assignment → equality → comparison → term → factor → unary → primary`). **AST** nodes are tagged unions (`Expr`, `Stmt`) stored in `SegmentedList`s for pointer stability. **Interpreter** walks the AST and resolves variables through a chain of `Environment` scopes, where each block pushes a new environment linked to its parent.

Memory is managed with a top-level `DebugAllocator` for leak detection, arena allocators for AST nodes and string values, and `SegmentedList` wherever pointer stability is needed during growth.
