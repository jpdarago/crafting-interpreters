const std = @import("std");

const Ast = @import("ast.zig");
const Values = @import("values.zig");

const Diagnostics = @import("diagnostics.zig");

const Scanner = @import("scanner.zig");

const Parser = @import("parser.zig");

const Errors = @import("errors.zig");

// TODO(jp): We should have a StaticAnalysis error here.

const EvalError = Errors.EvalError;

const Self = @This();

const VarStatus = enum { DECLARED, DEFINED };

const FunctionType = enum { NONE, FUNCTION };

const Scope = struct {
    declarations: std.StringHashMap(VarStatus),
    enclosing: ?*Scope,
};

allocator: std.mem.Allocator,

diagnostics: *Diagnostics,

top_scope: ?*Scope,

scope_allocator: std.heap.ArenaAllocator,

current_function: FunctionType,

pub fn init(allocator: std.mem.Allocator, diagnostics: *Diagnostics) EvalError!Self {
    return Self{ .allocator = allocator, .diagnostics = diagnostics, .top_scope = null, .scope_allocator = std.heap.ArenaAllocator.init(allocator), .current_function = .NONE };
}

pub fn deinit(self: *Self) void {
    self.scope_allocator.deinit();
}

pub fn resolve(self: *Self, program: *Ast.Program) EvalError!void {
    var it = program.statements.iterator(0);

    while (it.next()) |stmt| {
        try self.resolve_statement(stmt.*);
    }
}

fn resolve_statement(self: *Self, stmt: *Ast.Stmt) EvalError!void {
    switch (stmt.*) {
        .expression => |expression| {
            try self.resolve_expression(expression.expression);
        },
        .variable => |variable| {
            try self.declare(variable.name);
            if (variable.initializer) |initializer| {
                try self.resolve_expression(initializer);
            }
            try self.define(variable.name);
        },
        .print => |print| {
            try self.resolve_expression(print.expression);
        },
        .ret => |ret| {
            if (self.current_function == .NONE) {
                self.diagnostics.report_error(ret.keyword.line, "Can't return from top level code");
                return EvalError.InvalidExpression;
            }
            if (ret.expression) |expr| {
                try self.resolve_expression(expr);
            }
        },
        .block => |block| {
            try self.begin_scope();
            var block_it = block.statements.constIterator(0);
            while (block_it.next()) |block_stmt| {
                try self.resolve_statement(block_stmt.*);
            }
            self.end_scope();
        },
        .loop => |loop| {
            try self.resolve_expression(loop.condition);
            try self.resolve_statement(loop.body);
        },
        .for_loop => |loop| {
            if (loop.initializer) |initializer| {
                try self.resolve_statement(initializer);
            }
            if (loop.condition) |condition| {
                try self.resolve_expression(condition);
            }
            if (loop.increment) |increment| {
                try self.resolve_expression(increment);
            }
            try self.resolve_statement(loop.body);
        },
        .conditional => |conditional| {
            try self.resolve_expression(conditional.condition);
            try self.resolve_statement(conditional.if_branch);
            if (conditional.else_branch) |else_branch| {
                try self.resolve_statement(else_branch);
            }
        },
        .function => |function| {
            try self.declare(function.name);
            try self.define(function.name);
            try self.resolve_function(&function, .FUNCTION);
        },
    }
}

fn resolve_function(self: *Self, function: *const Ast.Stmt.Function, function_type: FunctionType) EvalError!void {
    try self.begin_scope();
    const enclosing_function = self.current_function;
    self.current_function = function_type;
    defer self.current_function = enclosing_function;
    for (function.params.items) |param| {
        try self.define(param);
    }
    for (function.body.items) |stmt| {
        try self.resolve_statement(stmt);
    }
    self.end_scope();
}

fn resolve_expression(self: *Self, expr: *Ast.Expr) EvalError!void {
    switch (expr.data) {
        .literal => {},
        .grouping => |grouping| {
            try self.resolve_expression(grouping.expression);
        },
        .unary => |unary| {
            try self.resolve_expression(unary.expression);
        },
        .binary => |bin| {
            try self.resolve_expression(bin.left);
            try self.resolve_expression(bin.right);
        },
        .variable => |variable| {
            if (self.top_scope) |top| {
                if (top.declarations.get(variable.name.lexeme)) |status| {
                    if (status == .DECLARED) {
                        self.diagnostics.report_error(variable.name.line, "Can't read local variable in its own initializer");
                        return EvalError.InvalidExpression;
                    }
                }
            }
            self.resolve_local(expr, variable.name.lexeme);
        },
        .assign => |assign| {
            try self.resolve_expression(assign.value);
            self.resolve_local(expr, assign.name.lexeme);
        },
        .logical => |logical| {
            try self.resolve_expression(logical.left);
            try self.resolve_expression(logical.right);
        },
        .call => |call| {
            try self.resolve_expression(call.callee);
            for (call.args.items) |arg| {
                try self.resolve_expression(arg);
            }
        },
    }
}

fn resolve_local(self: *Self, expr: *Ast.Expr, name: []const u8) void {
    var ptr: ?*Scope = self.top_scope;
    var hops: i32 = 0;
    while (ptr) |scope| {
        if (scope.declarations.contains(name)) {
            expr.depth = hops;
            return;
        }
        hops += 1;
        ptr = scope.enclosing;
    }
}

fn declare(self: *Self, name: Ast.Token) EvalError!void {
    if (self.top_scope) |scope| {
        const result = scope.declarations.getOrPut(name.lexeme) catch return EvalError.InternalFailure;
        if (result.found_existing) {
            // TODO(jp): Pass parameters.
            self.diagnostics.report_error(name.line, "Variable already defined in scope");
            return EvalError.InvalidExpression;
        }
        result.value_ptr.* = .DECLARED;
    }
}

fn define(self: *Self, name: Ast.Token) EvalError!void {
    if (self.top_scope) |scope| scope.declarations.put(name.lexeme, .DEFINED) catch return EvalError.InternalFailure;
}

fn begin_scope(self: *Self) EvalError!void {
    const top = self.top_scope;
    const scope = self.scope_allocator.allocator().create(Scope) catch return EvalError.InternalFailure;
    scope.* = Scope{ .declarations = std.StringHashMap(VarStatus).init(self.scope_allocator.allocator()), .enclosing = top };
    self.top_scope = scope;
}

fn end_scope(self: *Self) void {
    if (self.top_scope) |scope| {
        self.top_scope = scope.enclosing;
    }
}
