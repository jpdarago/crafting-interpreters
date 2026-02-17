const std = @import("std");

const Ast = @import("ast.zig");

const Diagnostics = @import("diagnostics.zig");

const Scanner = @import("scanner.zig");

const Parser = @import("parser.zig");

const Environment = @import("environment.zig");

const Errors = @import("errors.zig");

const EvalError = Errors.EvalError;

const Stdfile = std.fs.File;

const Self = @This();

allocator: std.mem.Allocator,

diagnostics: *Diagnostics,

parser: *Parser,

environment: Environment,

string_pool: std.heap.ArenaAllocator,

pub fn init(allocator: std.mem.Allocator, diagnostics: *Diagnostics, parser: *Parser) Self {

    const environment = Environment.init(allocator, null);
    const pool = std.heap.ArenaAllocator.init(allocator);

    return Self {
        .allocator = allocator,
        .diagnostics =  diagnostics,
        .parser = parser,
        .environment = environment,
        .string_pool = pool
    };
}

pub fn deinit(self: *Self) void {
    self.environment.deinit();
    self.string_pool.deinit();
}

pub fn evaluate(self: *Self) !Ast.LoxValue {

    var program = try self.parser.parse();
    defer program.deinit();

    var result : Ast.LoxValue = .nil;

    var it = program.statements.constIterator(0);

    while (it.next()) |stmt| {
        result = try self.evaluate_statement(stmt.*, &self.environment);        
    }

    return result;
}

fn evaluate_statement(self: *Self, stmt: *const Ast.Stmt, env: *Environment) EvalError!Ast.LoxValue {

    switch (stmt.*) {
        .expression => |expr| { 
            return try self.evaluate_expr(expr.expression, env);
        },
        .variable => |variable| {
            var val : Ast.LoxValue = .nil;

            if (variable.initializer) |initializer| {
                val = try self.evaluate_expr(initializer, env);
            }

            env.define(variable.name.lexeme, val) catch {

                self.diagnostics.report("<inline>", variable.name.line, "Internal error: Failed to set variable {s}", .{variable.name.lexeme});
                
                return EvalError.InternalFailure;
            };
        
            return .nil;
        },
        .print => |print| {

            var value = try self.evaluate_expr(print.expression, env);

            var buffer : [1024]u8 = undefined;

            var stdout = Stdfile.stdout().writer(&buffer);

            value.write(&stdout.interface) catch {

                // TODO(jp): Better error handling.
                self.diagnostics.report_error(0, "Internal error: Failed to write expression");
                
                return EvalError.InternalFailure;
            };

            _ = stdout.interface.write("\n") catch {

                // TODO(jp): Better error handling.
                self.diagnostics.report_error(0, "Internal error: Failed to write expression");
                
                return error.InternalFailure;
            };

            stdout.interface.flush() catch {

                // TODO(jp): Better error handling.
                self.diagnostics.report_error(0, "Internal error: Failed to write expression");
                
                return error.InternalFailure;
            };

            return .nil;
        },
        .block => |block| {

            try self.evaluate_block(block, env); 

            return .nil;
        },
        .loop => |loop| {

            while (true) {

                const cond = try self.evaluate_expr(loop.condition, env);

                if (!is_truthy(cond)) {
                    break;
                }

                _ = try self.evaluate_statement(loop.body, env);
            }
            
            return .nil;

        },
        .for_loop => |loop| {

            if (loop.initializer) |initializer| {

                _ = try self.evaluate_statement(initializer, env);
            }

            while (true) {

                var cond = Ast.LoxValue { .boolean = true };

                if (loop.condition) |condition| {
                    cond = try self.evaluate_expr(condition, env);
                }

                if (!is_truthy(cond)) {
                    break;
                }

                _ = try self.evaluate_statement(loop.body, env);

                if (loop.increment) |increment| {
                    _ = try self.evaluate_expr(increment, env);
                }
            }
            
            return .nil;

        },
        .conditional => |conditional| {

            const cond = try self.evaluate_expr(conditional.condition, env);

            if (is_truthy(cond)) {

                return self.evaluate_statement(conditional.if_branch, env);

            } else if (conditional.else_branch) |else_branch| {

                return self.evaluate_statement(else_branch, env);

            }
        
            return .nil;
        }
    }
}

fn evaluate_block(self: *Self, block: Ast.Stmt.Block, env: *Environment) EvalError!void {

    var new_env = Environment.init(self.allocator, env);
    defer new_env.deinit();
    
    var it = block.statements.constIterator(0);

    while (it.next()) |stmt| {
        _ = try self.evaluate_statement(stmt.*, &new_env);
    }
}

fn evaluate_expr(self: *Self, expr: *const Ast.Expr, env: *Environment) EvalError!Ast.LoxValue {
    
    switch (expr.*) {
        .literal => |lit| { return lit.value; },
        .binary => |bin| {
            const lhs = try self.evaluate_expr(bin.left, env);
            const rhs = try self.evaluate_expr(bin.right, env);

            try self.check_same_tag(bin.operator, lhs, rhs);
            try self.check_tag(bin.operator, lhs, .{ .number, .string });

            switch(bin.operator.type) {
                .PLUS => {
                    switch (lhs) {
                        .number => { return Ast.LoxValue { .number = lhs.number + rhs.number }; },
                        .string => { return Ast.LoxValue { .string = try self.concat_strings(lhs.string, rhs.string) }; },
                        else => unreachable
                    }
                },
                .MINUS => { 
                    const l = try self.check_number(bin.operator, lhs);

                    const r = try self.check_number(bin.operator, rhs);

                    return Ast.LoxValue { .number = l - r }; 
                },
                .STAR => { 
                    const l = try self.check_number(bin.operator, lhs);

                    const r = try self.check_number(bin.operator, rhs);

                    return Ast.LoxValue { .number = l * r }; 
                },
                .SLASH => { 

                    const l = try self.check_number(bin.operator, lhs);

                    const r = try self.check_number(bin.operator, rhs);

                    if (r < 1e-10) {
                        self.diagnostics.report_error(bin.operator.line, "Division by zero");
                        return error.InvalidExpression;
                    }

                    return Ast.LoxValue { .number = l / r }; 
                },
                .GREATER => { 

                    const l = try self.check_number(bin.operator, lhs);

                    const r = try self.check_number(bin.operator, rhs);

                    return Ast.LoxValue { .boolean = l > r }; 
                },
                .GREATER_EQUAL => { 

                    const l = try self.check_number(bin.operator, lhs);

                    const r = try self.check_number(bin.operator, rhs);

                    return Ast.LoxValue { .boolean = l >= r }; 
                },
                .LESS => { 

                    const l = try self.check_number(bin.operator, lhs);

                    const r = try self.check_number(bin.operator, rhs);

                    return Ast.LoxValue { .boolean = l < r }; 
                },
                .LESS_EQUAL => { 

                    const l = try self.check_number(bin.operator, lhs);

                    const r = try self.check_number(bin.operator, rhs);

                    return Ast.LoxValue { .boolean = l <= r }; 
                },
                .EQUAL_EQUAL => { 
                    return Ast.LoxValue { 
                        .boolean = try self.are_equal(bin.operator, lhs, rhs)
                    }; 
                },
                .BANG_EQUAL => { 
                    return Ast.LoxValue { 
                        .boolean = !try self.are_equal(bin.operator, lhs, rhs)
                    }; 
                },
                else => { return error.InvalidExpression; }
            }
        },
        .unary => |un| {
            const val = try self.evaluate_expr(un.expression, env);

            if (un.operator.type == .MINUS) {
                return Ast.LoxValue {
                   .number = -try self.check_number(un.operator, val)
                };
            }

            if (un.operator.type == .BANG) {

                try self.check_tag(un.operator, val, .{ .nil, .boolean });

                return Ast.LoxValue {
                    .boolean = !is_truthy(val)
                };
            }
        },
        .grouping => |grouping| {
            return self.evaluate_expr(grouping.expression, env);
        },
        .variable => |variable| {
            return env.lookup(variable.name.lexeme) catch {
                // TODO(jp): Pass the file to diagnostics and change report_error to take anyargs as well.
                // TODO(jp): Check the error type.
                self.diagnostics.report("<inline>", variable.name.line, "Undefined variable '{s}'", .{variable.name.lexeme});
                return EvalError.UndefinedVariable;
            };
        },
        .assign => |assign| {
            const value = try self.evaluate_expr(assign.value, env);
            env.assign(assign.name.lexeme, value) catch |err| {
                self.diagnostics.report("<inline>", assign.name.line, "Undefined variable {s}", .{assign.name.lexeme});
                return err;
            };
            return value;
        },
        .logical => |logical| {

            const lhs = try self.evaluate_expr(logical.left, env);

            if (logical.operator.type == .OR) {

                if (is_truthy(lhs)) {
                    return lhs;
                }

            } else if (logical.operator.type == .AND){

                if (!is_truthy(lhs)) {
                    return lhs;
                }
            }

            return self.evaluate_expr(logical.right, env);
        }
    }

    return error.InvalidExpression;
}

fn check_tag(self: *Self, token: Scanner.Token, val: Ast.LoxValue, comptime tags: anytype) EvalError!void {

    const tag = std.meta.activeTag(val);

    inline for (tags) |t| {
        if (tag == t) {
            return;
        }
    }

    self.diagnostics.report_error(token.line, "Unexpected type");

    return error.InvalidExpression;
}

fn check_number(self: *Self, token: Scanner.Token, lhs: Ast.LoxValue) EvalError!f64 {

    try self.check_tag(token, lhs, .{ .number });

    return lhs.number;
}

fn check_bool(lhs: *Ast.LoxValue) EvalError!f64 {

    try check_tag(lhs, .{ .number });

    if (std.meta.activeTag(lhs) != .number) {
        return error.InvalidExpression;
    }

    return lhs.number;
}

fn is_truthy(val: Ast.LoxValue) bool {
    return switch (val) {
        .boolean => |b| b,
        .nil => false,
        else => true
    };
}

fn check_same_tag(self: *Self, token: Scanner.Token, lhs: Ast.LoxValue, rhs: Ast.LoxValue) EvalError!void {
    if (@intFromEnum(lhs) != @intFromEnum(rhs)) {
        self.diagnostics.report_error(token.line, "Mismatched types");
        return error.TypeMismatch;
    }
}

fn are_equal(self: *Self, token: Scanner.Token, lhs: Ast.LoxValue, rhs: Ast.LoxValue) EvalError!bool {

    try self.check_same_tag(token, lhs, rhs);

    return switch (lhs) {
        .number => lhs.number == rhs.number,
        .string => std.mem.eql(u8, lhs.string, rhs.string),
        .boolean => lhs.boolean == rhs.boolean,
        .nil => true
    };
}

// TODO(jp): This needs a garbage collector of some sort.
fn concat_strings(self: *Self, lhs: []const u8, rhs: []const u8) EvalError![]u8 {

    const result = self.string_pool.allocator().alloc(u8, lhs.len + rhs.len) catch {
        std.log.err("Failed to get memory", .{});
        return error.InternalFailure;
    };

    std.mem.copyForwards(u8, result[0..lhs.len], lhs);
    std.mem.copyForwards(u8, result[lhs.len..], rhs);

    return result;
}
