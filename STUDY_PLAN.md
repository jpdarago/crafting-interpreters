# Crafting Interpreters Study Plan

15-20 minutes per day. Each day: read the section, then implement in Zig.

Started: 2026-03-03
Current position: Chapter 10, Section 10.2.1

## Part II: Tree-Walk Interpreter (Weeks 1-4)

### Week 1 — Ch 10: Functions (finish)

- [ ] Day 1: 10.2.1 Interpreting function calls — finish wiring up call evaluation
- [ ] Day 2: 10.2.2 Call type errors + 10.2.3 Checking arity — add runtime error handling for calls
- [ ] Day 3: 10.3 Native functions — implement native function support (clock)
- [ ] Day 4: 10.4 Function declarations + 10.5 Function objects — parse `fun`, create LoxFunction
- [ ] Day 5: 10.5.1 Interpreting function declarations — wire up function declaration evaluation
- [ ] Day 6: 10.6 Return statements — parse and evaluate `return`
- [ ] Day 7: 10.7 Local functions and closures + challenges — read closures preview, try challenges

### Week 2 — Ch 11: Resolving and Binding

- [ ] Day 1: 11.1-11.2 — read the scoping problem, understand the Resolver concept
- [ ] Day 2: 11.3.1-11.3.3 — implement Resolver: blocks, variable declarations, variable expressions
- [ ] Day 3: 11.3.4-11.3.7 — Resolver: assignment, function declarations, remaining node types
- [ ] Day 4: 11.4 — interpreter: use resolved variable depths
- [ ] Day 5: 11.5-11.6 — resolution errors + challenges

### Week 3 — Ch 12: Classes

- [ ] Day 1: 12.1-12.2 — read OOP intro, parse class declarations
- [ ] Day 2: 12.3 — LoxClass runtime representation
- [ ] Day 3: 12.4 — creating instances (LoxInstance)
- [ ] Day 4: 12.5 — properties: get and set expressions
- [ ] Day 5: 12.6 — methods on classes
- [ ] Day 6: 12.7 — `this` binding
- [ ] Day 7: 12.7 (cont) + challenges — resolver support for `this`, challenges

### Week 4 — Ch 13: Inheritance

- [ ] Day 1: 13.1-13.2 — superclass parsing, inheriting methods
- [ ] Day 2: 13.3 — `super` expressions
- [ ] Day 3: 13.4 + challenges — resolver support for `super`, challenges
- [ ] Day 4: Buffer day — catch up, refactor, write tests

## Part III: Bytecode Virtual Machine (Weeks 5-15)

### Week 5 — Ch 14: Chunks of Bytecode

- [ ] Day 1: Read intro, understand Chunk structure (bytecode array + constants)
- [ ] Day 2: Implement Chunk, write/free operations
- [ ] Day 3: Constant pool
- [ ] Day 4: Disassembler
- [ ] Day 5: Line information encoding

### Week 6 — Ch 15: A Virtual Machine + Ch 16: Scanning on Demand

- [ ] Day 1: VM struct, instruction execution loop
- [ ] Day 2: Stack-based value operations
- [ ] Day 3: Arithmetic + error reporting
- [ ] Day 4: Ch 16 — single-pass scanner (start)
- [ ] Day 5: Ch 16 — token types, keywords, finish scanner

### Week 7 — Ch 17: Compiling Expressions + Ch 18: Types of Values

- [ ] Day 1: Single-pass compilation, Pratt parser intro
- [ ] Day 2: Parse rules table, unary/binary expressions
- [ ] Day 3: Precedence handling, grouping
- [ ] Day 4: Ch 18 — tagged union values (not just doubles)
- [ ] Day 5: Ch 18 — booleans, nil, comparison/equality operators

### Week 8 — Ch 19: Strings + Ch 20: Hash Tables

- [ ] Day 1: Heap-allocated Obj type, ObjString
- [ ] Day 2: String concatenation, memory management
- [ ] Day 3: Ch 20 — hash table implementation (start)
- [ ] Day 4: Ch 20 — hashing, collision handling
- [ ] Day 5: Ch 20 — string interning

### Week 9 — Ch 21: Global Variables + Ch 22: Local Variables

- [ ] Day 1: Statements, expression statements, print
- [ ] Day 2: Global variable declaration and access
- [ ] Day 3: Ch 22 — block scoping in the compiler
- [ ] Day 4: Ch 22 — local variable resolution, scope depth

### Week 10 — Ch 23: Jumping Back and Forth + Ch 24: Calls and Functions (start)

- [ ] Day 1: If statements, jump instructions
- [ ] Day 2: Logical operators, while loops
- [ ] Day 3: For loops
- [ ] Day 4: Ch 24 — function objects, call frames (start)
- [ ] Day 5: Ch 24 — function compilation

### Week 11 — Ch 24 (finish) + Ch 25: Closures (start)

- [ ] Day 1: Ch 24 — function calls at runtime
- [ ] Day 2: Ch 24 — native functions, return statements
- [ ] Day 3: Ch 25 — upvalue concept, compiler changes
- [ ] Day 4: Ch 25 — capturing upvalues at runtime
- [ ] Day 5: Ch 25 — closing upvalues

### Week 12 — Ch 25 (finish) + Ch 26: Garbage Collection

- [ ] Day 1: Ch 25 — upvalues on the heap, closed-over loop vars
- [ ] Day 2: Ch 26 — mark-sweep GC concept, reachability
- [ ] Day 3: Ch 26 — marking roots, tracing references
- [ ] Day 4: Ch 26 — sweeping, freeing objects
- [ ] Day 5: Ch 26 — GC tuning, stress testing

### Week 13 — Ch 27: Classes and Instances + Ch 28: Methods and Initializers

- [ ] Day 1: Ch 27 — class objects, instance creation
- [ ] Day 2: Ch 27 — get/set property operations
- [ ] Day 3: Ch 28 — method compilation and binding
- [ ] Day 4: Ch 28 — `this`, bound methods
- [ ] Day 5: Ch 28 — initializers, `init()`

### Week 14 — Ch 29: Superclasses + Ch 30: Optimization (start)

- [ ] Day 1: Ch 29 — inheriting methods
- [ ] Day 2: Ch 29 — `super` calls
- [ ] Day 3: Ch 30 — measuring performance
- [ ] Day 4: Ch 30 — NaN boxing
- [ ] Day 5: Ch 30 — optimization techniques

### Week 15 — Ch 30 (finish) + Wrap-up

- [ ] Day 1: Ch 30 — finishing optimizations
- [ ] Day 2: Challenges, review
- [ ] Day 3-4: Buffer — catch up on anything you fell behind on

## Notes

- **Part II remaining:** ~4 weeks (currently ~70% done)
- **Part III:** ~11 weeks
- **Total:** ~15 weeks / ~3.5 months
- **Hardest chapters:** Closures (25), Calls and Functions (24), Garbage Collection (26)
- Buffer days are built in — use them to catch up or explore challenges
- Check off items as you go: change `[ ]` to `[x]`
