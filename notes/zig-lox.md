# zig-lox

A Lox **bytecode VM** in Zig, implementing Part III of Crafting Interpreters. Same language as ours, completely different execution model.

**Source files:**
- `references/zig-lox/src/scanner.zig` - Scanner
- `references/zig-lox/src/compiler.zig` - Compiler (Pratt parser + bytecode emitter)
- `references/zig-lox/src/chunk.zig` - Bytecode format
- `references/zig-lox/src/vm.zig` - Virtual machine
- `references/zig-lox/src/debug.zig` - Value representation (NaN boxing)

## Scanner

### Token struct

```zig
pub const Token = struct {
    tokenType: TokenType,
    lexeme: []const u8,  // slice into source
    line: usize,
};
```

Same as ours — simple 3-field token.

### Scanner struct

```zig
pub const Scanner = struct {
    start: []const u8,   // remaining source from current token
    current: usize,      // offset into start
    line: usize,
};
```

Interesting difference: instead of tracking separate `start` and `current` offsets into the full source, the scanner **resets `start`** to point to the current position after each token:

```zig
self.start = self.start[self.current..];
self.current = 0;
```

### TokenType enum (51 variants)

Exactly the Lox token set from the book — identical to ours.

### Keyword lookup: runtime trie dispatch

Unlike the comptime `StaticStringMap` used by Zig/Aro/Bun, zig-lox uses a **hand-written trie** via nested switches:

```zig
fn identifierType(self: *Scanner) TokenType {
    return switch (self.start[0]) {
        'a' => self.checkKeyword(1, "nd", .And),
        'c' => self.checkKeyword(1, "lass", .Class),
        'f' => switch (self.start[1]) {
            'a' => self.checkKeyword(2, "lse", .False),
            'o' => self.checkKeyword(2, "r", .For),
            'u' => self.checkKeyword(2, "n", .Fun),
            else => .Identifier,
        },
        't' => switch (self.start[1]) {
            'h' => self.checkKeyword(2, "is", .This),
            'r' => self.checkKeyword(2, "ue", .True),
            else => .Identifier,
        },
        // ... other first characters
    };
}
```

This is the approach from the book — `checkKeyword(offset, suffix, type)` verifies the rest of the identifier matches the expected suffix. For Lox's small keyword set (~20 words), this is perfectly efficient and arguably clearer than a hash map.

### Scanning approach

Same as ours: `scanToken()` skips whitespace, reads one character, dispatches via switch. Helper `match(char)` for two-character operators.

## Compiler (Pratt Parsing)

This is where zig-lox diverges most from our interpreter. Instead of building an AST and walking it, the compiler **emits bytecode directly during parsing**. There is no AST.

### Compiler struct

```zig
pub const Compiler = struct {
    enclosing: ?*Compiler,        // for nested function compilation
    function: *Obj.Function,      // owns the bytecode chunk
    functionType: FunctionType,   // Script | Function | Initializer | Method
    locals: std.ArrayList(Local), // variables in current scope
    upvalues: std.ArrayList(Upvalue),
    scopeDepth: usize,            // 0 = global, >0 = local
};
```

### Parser struct

```zig
pub const Parser = struct {
    scanner: Scanner,
    current: Token,       // lookahead
    previous: Token,      // just consumed
    hadError: bool,
    panicMode: bool,      // suppress cascading errors
    compiler: *Compiler,
    vm: *VM,
};
```

### Pratt parsing

The fundamental difference from our recursive descent expression parser. Instead of encoding precedence in function call depth, Pratt parsing uses an **explicit precedence table**.

**Precedence enum:**
```zig
const Precedence = enum(u8) {
    None,        // 0
    Assignment,  // 1  =
    Or,          // 2  or
    And,         // 3  and
    Equality,    // 4  == !=
    Comparison,  // 5  < > <= >=
    Term,        // 6  + -
    Factor,      // 7  * /
    Unary,       // 8  ! -
    Call,         // 9  . ()
    Primary,     // 10
};
```

**Core algorithm — `parsePrecedence(precedence)`:**
```zig
fn parsePrecedence(self: *Parser, precedence: Precedence) !void {
    try self.advance();
    const canAssign = @intFromEnum(precedence) <= @intFromEnum(.Assignment);
    try self.prefix(self.previous.tokenType, canAssign);

    while (@intFromEnum(precedence) <= @intFromEnum(getPrecedence(self.current.tokenType))) {
        try self.advance();
        try self.infix(self.previous.tokenType, canAssign);
    }
}
```

1. Consume token, call its **prefix handler** (number, string, identifier, unary op, grouping)
2. While next token's precedence >= current level, consume it and call its **infix handler** (binary op, call, dot access)

Each token type maps to prefix/infix handlers and a precedence level.

### Prefix handlers

- `.Number` -> parse float, emit `Constant` opcode
- `.String` -> intern string, emit `Constant`
- `.Identifier` -> resolve variable, emit `GetLocal`/`GetGlobal`/`GetUpvalue`
- `.LeftParen` -> grouping: parse expression recursively
- `.Minus` -> unary negate: parse operand, emit `Negate`
- `.Bang` -> unary not: parse operand, emit `Not`
- `.True`/`.False`/`.Nil` -> emit literal opcodes directly

### Infix handlers

- `.Plus`, `.Minus`, `.Star`, `.Slash` -> parse right operand at next precedence, emit binary opcode
- `.EqualEqual`, `.BangEqual`, `.Less`, etc. -> comparison opcodes
- `.And`, `.Or` -> short-circuit with jump opcodes
- `.LeftParen` -> function call
- `.Dot` -> property access

### Logical Operators

Short-circuit `and`/`or` compile to **jump instructions** rather than evaluating both sides:

```zig
// and: skip right side if left is false
fn and_(self: *Parser) !void {
    const endJump = try self.emitJump(.JumpIfFalse);
    try self.emitOp(.Pop);
    try self.parsePrecedence(.And);
    try self.patchJump(endJump);
}

// or: skip right side if left is true
fn or_(self: *Parser) !void {
    const elseJump = try self.emitJump(.JumpIfFalse);
    const endJump = try self.emitJump(.Jump);
    try self.patchJump(elseJump);
    try self.emitOp(.Pop);
    try self.parsePrecedence(.Or);
    try self.patchJump(endJump);
}
```

Our tree-walker implements short-circuit by conditionally evaluating the right operand at runtime. The bytecode approach must decide at compile time where to jump, using placeholder offsets that get **patched** after the right-side code is emitted.

### Jump patching

```zig
fn emitJump(self: *Parser, op: OpCode) !usize {
    try self.emitOp(op);
    try self.emitByte(0xff);  // placeholder high byte
    try self.emitByte(0xff);  // placeholder low byte
    return self.currentChunk().code.items.len - 2;
}

fn patchJump(self: *Parser, offset: usize) !void {
    const jump = self.currentChunk().code.items.len - offset - 2;
    self.currentChunk().code.items[offset] = @intCast((jump >> 8) & 0xff);
    self.currentChunk().code.items[offset + 1] = @intCast(jump & 0xff);
}
```

Jumps are 2-byte big-endian offsets. Emit placeholder `0xFFFF`, then patch with the actual distance once the jump target is known.

### Statement parsing (recursive descent)

Statements use normal recursive descent (not Pratt) — same as ours:

```zig
fn declaration(self: *Parser) !void {
    if (try self.match(.Class)) {
        try self.classDeclaration();
    } else if (try self.match(.Fun)) {
        try self.funDeclaration();
    } else if (try self.match(.Var)) {
        try self.varDeclaration();
    } else {
        try self.statement();
    }
    if (self.panicMode) try self.synchronize();
}
```

Control flow (`if`/`while`/`for`) compiles to jumps. `for` is desugared into `while` with optional init/increment, same as our approach.

### Variable resolution

Three scopes with different bytecode:
- **Globals:** stored by name in a hash table. `GetGlobal`/`SetGlobal` + constant index for the name string.
- **Locals:** tracked in `Compiler.locals` array by stack slot index. `GetLocal`/`SetLocal` + stack slot.
- **Upvalues (closures):** resolved by walking the `Compiler.enclosing` chain. `GetUpvalue`/`SetUpvalue` + upvalue index. Captured locals are "closed over" when their scope exits (`CloseUpvalue`).

### Function compilation

Each function gets its own `Compiler` instance linked to its parent via `enclosing`. The function's bytecode is emitted into its own `Chunk`. A `Closure` opcode wraps the function with its captured upvalues.

## Bytecode Format

### OpCode enum (44 opcodes)

```zig
pub const OpCode = enum(u8) {
    Return, Pop,
    GetLocal, SetLocal, GetGlobal, DefineGlobal, SetGlobal,
    GetUpvalue, SetUpvalue, GetProperty, SetProperty, GetSuper,
    Jump, JumpIfFalse, Loop,
    Call, Invoke, SuperInvoke, Closure, CloseUpvalue,
    Class, Inherit, Method,
    Constant, Nil, True, False,
    Equal, Greater, Less, Negate, Add, Subtract, Multiply, Divide, Not,
    Print,
};
```

### Chunk struct

```zig
pub const Chunk = struct {
    code: ArrayList(u8),         // bytecode
    constants: ArrayList(Value), // constant pool
    lines: ArrayList(usize),     // line number per byte
};
```

### Instruction format

Most instructions are 1 byte + optional operands:
- `Constant <u8 index>` — push `constants[index]`
- `GetLocal <u8 slot>` — push `stack[frame_base + slot]`
- `Jump <u16 offset>` — `PC += offset`
- `Loop <u16 offset>` — `PC -= offset` (backward jump)
- `Add`, `Not`, etc. — no operands, operate on stack top

## Value Representation

Two implementations switchable at compile time:

### NaN-boxed (optimized)
```zig
pub const NanBoxedValue = packed struct { data: u64 };
```
Uses IEEE 754 quiet-NaN bit patterns to pack booleans, nil, and object pointers into a single u64. Same technique as the book.

### Union-based (clear)
```zig
pub const UnionValue = union(enum) {
    Bool: bool,
    Nil,
    Number: f64,
    Obj: *Obj,
};
```
Tagged union — same concept as our `LoxValue`.

## VM

Stack-based execution with call frames:

```zig
pub const VM = struct {
    frames: ArrayList(CallFrame),
    stack: FixedCapacityStack(Value),
    objects: ?*Obj,              // GC linked list
    strings: Table,              // string interning
    globals: Table,
    openUpvalues: ?*Upvalue,     // closure capture chain
};
```

Simple fetch-decode-execute loop:
```zig
fn run(self: *VM) !void {
    while (true) {
        const opCode = @enumFromInt(self.readByte());
        try self.runOp(opCode);
    }
}
```

### Garbage collection

Mark-and-sweep GC with an intrusive gray list (linked list embedded in objects, not a separate ArrayList — avoids OOM during GC).

## Error Handling

### Panic mode — straight from the book

zig-lox implements the **exact panic mode** from Crafting Interpreters Part III:

```zig
pub const Parser = struct {
    hadError: bool,
    panicMode: bool,
    // ...
};

fn errorAt(self: *Parser, token: *Token, message: []const u8) {
    if (self.panicMode) return;   // suppress cascading errors
    self.panicMode = true;

    vm.errWriter.print("[line {d}] Error", .{token.line});
    if (token.tokenType == .Eof) {
        vm.errWriter.print(" at end", .{});
    } else {
        vm.errWriter.print(" at '{s}'", .{token.lexeme});
    }
    vm.errWriter.print(": {s}\n", .{message});
    self.hadError = true;
}
```

### Synchronization

After entering panic mode, the parser skips tokens until finding a statement boundary:

```zig
fn synchronize(self: *Parser) {
    self.panicMode = false;

    while (!self.check(.Eof)) {
        if (self.previous.tokenType == .Semicolon) return;
        switch (self.current.tokenType) {
            .Class, .Fun, .Var, .For, .If, .While, .Print, .Return => return,
            else => try self.advance(),
        }
    }
}
```

Called after each declaration: `if (self.panicMode) try self.synchronize()`.

### Error messages

Simple format with line number and token context:
```
[line 42] Error at 'x': Invalid assignment target.
[line 10] Error at end: Expect '}' after block.
```

No column numbers, no source line display. Direct write to stderr.

### Contrast with our error handling

| Aspect | zig-lox | Ours |
|--------|---------|------|
| Strategy | Panic mode + synchronize | `had_error` flag + return error |
| Cascading suppression | Yes (panicMode flag) | No |
| Recovery | Skip to statement keyword | None (error propagates up) |
| Message format | `[line N] Error at 'tok': msg` | `[file:line] msg` |
| Multiple errors | Yes (after synchronization) | Yes (but no sync, so more noise) |

This is the textbook implementation our interpreter could adopt — `panicMode` is the simplest effective error recovery strategy.

## Comparison with our tree-walker

| Aspect | zig-lox (bytecode VM) | Ours (tree-walker) |
|--------|----------------------|---------------------|
| **Execution** | Fetch-decode-execute loop | Recursive AST traversal |
| **Intermediate form** | Bytecode in `Chunk` | AST (tagged unions) |
| **Expression parsing** | Pratt (precedence table) | Recursive descent (call chain) |
| **Statement parsing** | Recursive descent | Recursive descent |
| **Variables** | Stack slots (locals) + hash map (globals) | Environment chain (hash maps) |
| **Control flow** | Jump/Loop opcodes with patched offsets | Conditional evaluation in `visitIfStmt` etc. |
| **Closures** | Upvalue objects, explicit capture | Enclosing environment pointers |
| **Values** | NaN-boxed u64 or union | `LoxValue` tagged union |
| **Memory** | GC (mark-and-sweep) | Arena allocators |
| **Loops** | Backward jump (reuse bytecode) | Re-traverse AST nodes each iteration |

### Key insight

The bytecode VM **separates compilation from execution**. Loops emit their body once as bytecode, then the `Loop` opcode jumps backward to re-execute. Our tree-walker re-traverses the AST nodes on every iteration — conceptually simpler but less efficient.

Pratt parsing is more compact than recursive descent for expressions (one function vs. many), but recursive descent is clearer for statements where precedence isn't relevant.

#zig-lox #bytecode #pratt-parsing #vm #reference
