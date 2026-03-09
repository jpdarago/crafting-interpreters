const std = @import("std");

const Ast = @import("ast.zig");
const Values = @import("values.zig");

const Diagnostics = @import("diagnostics.zig");

const Environment = @import("environment.zig");

const Natives = @import("natives.zig");

const Errors = @import("errors.zig");

const EvalError = Errors.EvalError;

const StmtResult = union(enum) {
    value: Values.LoxValue,
    ret: Values.LoxValue,
};

const Stdfile = std.fs.File;

const Self = @This();

allocator: std.mem.Allocator,

diagnostics: *Diagnostics,

environment: *Environment,

string_pool: std.heap.ArenaAllocator,

env_pool: std.heap.ArenaAllocator,

globals: *Environment,

pub fn init(allocator: std.mem.Allocator, diagnostics: *Diagnostics) EvalError!Self {
    const string_pool = std.heap.ArenaAllocator.init(allocator);

    const env_pool = std.heap.ArenaAllocator.init(allocator);

    var environment = allocator.create(Environment) catch return EvalError.InternalFailure;
    environment.* = Environment.init(allocator, null);

    for (Natives.builtins) |native| {
        const callable = Values.LoxValue{ .callable = .{ .native = native } };
        _ = try environment.define(native.name, callable);
    }

    return Self{ .allocator = allocator, .diagnostics = diagnostics, .environment = environment, .string_pool = string_pool, .env_pool = env_pool, .globals = environment };
}

pub fn deinit(self: *Self) void {
    self.environment.deinit();
    self.allocator.destroy(self.environment);
    self.env_pool.deinit();
    self.string_pool.deinit();
}

pub fn evaluate(self: *Self, program: *const Ast.Program) !Values.LoxValue {
    var result: Values.LoxValue = .nil;

    var it = program.statements.constIterator(0);

    while (it.next()) |stmt| {
        const stmt_result = try self.evaluate_statement(stmt.*, self.environment);
        result = switch (stmt_result) {
            .value => |v| v,
            .ret => |v| v,
        };
    }

    return result;
}

fn evaluate_statement(self: *Self, stmt: *const Ast.Stmt, env: *Environment) EvalError!StmtResult {
    switch (stmt.*) {
        .expression => |expr| {
            return .{ .value = try self.evaluate_expr(expr.expression, env) };
        },
        .variable => |variable| {
            var val: Values.LoxValue = .nil;

            if (variable.initializer) |initializer| {
                val = try self.evaluate_expr(initializer, env);
            }

            env.define(variable.name.lexeme, val) catch {
                self.diagnostics.report("<inline>", variable.name.line, "Internal error: Failed to set variable {s}", .{variable.name.lexeme});

                return EvalError.InternalFailure;
            };

            return .{ .value = .nil };
        },
        .print => |print| {
            var value = try self.evaluate_expr(print.expression, env);

            var buffer: [1024]u8 = undefined;

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

            return .{ .value = .nil };
        },
        .ret => |ret| {
            var val: Values.LoxValue = .nil;

            if (ret.expression) |expr| {
                val = try self.evaluate_expr(expr, env);
            }

            return .{ .ret = val };
        },
        .block => |block| {
            return self.evaluate_block(block, env);
        },
        .loop => |loop| {
            while (true) {
                const cond = try self.evaluate_expr(loop.condition, env);

                if (!is_truthy(cond)) {
                    break;
                }

                const result = try self.evaluate_statement(loop.body, env);
                if (result == .ret) return result;
            }

            return .{ .value = .nil };
        },
        .for_loop => |loop| {
            if (loop.initializer) |initializer| {
                const result = try self.evaluate_statement(initializer, env);
                if (result == .ret) return result;
            }

            while (true) {
                var cond = Values.LoxValue{ .boolean = true };

                if (loop.condition) |condition| {
                    cond = try self.evaluate_expr(condition, env);
                }

                if (!is_truthy(cond)) {
                    break;
                }

                const result = try self.evaluate_statement(loop.body, env);
                if (result == .ret) return result;

                if (loop.increment) |increment| {
                    _ = try self.evaluate_expr(increment, env);
                }
            }

            return .{ .value = .nil };
        },
        .conditional => |conditional| {
            const cond = try self.evaluate_expr(conditional.condition, env);

            if (is_truthy(cond)) {
                return self.evaluate_statement(conditional.if_branch, env);
            } else if (conditional.else_branch) |else_branch| {
                return self.evaluate_statement(else_branch, env);
            }

            return .{ .value = .nil };
        },
        .function => |func| {
            const function = Values.LoxFunction{ .name = func.name, .body = func.body.items, .arity = @intCast(func.params.items.len), .params = func.params.items, .closure = env };

            try self.environment.define(func.name.lexeme, Values.LoxValue{ .callable = .{ .function = function } });

            return .{ .value = .nil };
        },
    }
}

fn evaluate_block(self: *Self, block: Ast.Stmt.Block, env: *Environment) EvalError!StmtResult {
    const new_env = try self.create_env(env);

    var it = block.statements.constIterator(0);

    while (it.next()) |stmt| {
        const result = try self.evaluate_statement(stmt.*, new_env);
        if (result == .ret) return result;
    }

    return .{ .value = .nil };
}

fn evaluate_expr(self: *Self, expr: *const Ast.Expr, env: *Environment) EvalError!Values.LoxValue {
    switch (expr.data) {
        .literal => |lit| {
            return lit.value;
        },
        .call => |call| {
            var callee = switch (try self.evaluate_expr(call.callee, env)) {
                .callable => |c| c,
                else => {
                    self.diagnostics.report_error(call.paren.line, "Can only call functions and classes.");
                    return EvalError.InvalidExpression;
                },
            };

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const num_args = call.args.items.len;

            if (callee.arity() != num_args) {
                self.diagnostics.report("<inline>", call.paren.line, "Invalid number of arguments, expected {d} got {d}", .{ callee.arity(), num_args });
                return EvalError.InvalidArguments;
            }

            var args = std.ArrayList(Values.LoxValue).initCapacity(arena.allocator(), num_args) catch return EvalError.InternalFailure;
            defer args.deinit(arena.allocator());

            for (call.args.items) |arg| {
                args.appendAssumeCapacity(try self.evaluate_expr(arg, env));
            }

            return switch (callee) {
                .native => |native| native.call(self.diagnostics, args.items),
                .function => |func| {
                    var new_env = try self.create_env(func.closure);

                    for (func.params, 0..) |param, i| {
                        try new_env.define(param.lexeme, args.items[i]);
                    }

                    for (func.body) |stmt| {
                        const result = try self.evaluate_statement(stmt, new_env);
                        if (result == .ret) return result.ret;
                    }

                    return .nil;
                },
            };
        },
        .binary => |bin| {
            const lhs = try self.evaluate_expr(bin.left, env);
            const rhs = try self.evaluate_expr(bin.right, env);

            try self.check_same_tag(bin.operator, lhs, rhs);
            try self.check_tag(bin.operator, lhs, .{ .number, .string });

            switch (bin.operator.type) {
                .PLUS => {
                    switch (lhs) {
                        .number => {
                            return Values.LoxValue{ .number = lhs.number + rhs.number };
                        },
                        .string => {
                            return Values.LoxValue{ .string = try self.concat_strings(lhs.string, rhs.string) };
                        },
                        else => unreachable,
                    }
                },
                .MINUS => {
                    const l = try self.check_number(bin.operator, lhs);

                    const r = try self.check_number(bin.operator, rhs);

                    return Values.LoxValue{ .number = l - r };
                },
                .STAR => {
                    const l = try self.check_number(bin.operator, lhs);

                    const r = try self.check_number(bin.operator, rhs);

                    return Values.LoxValue{ .number = l * r };
                },
                .SLASH => {
                    const l = try self.check_number(bin.operator, lhs);

                    const r = try self.check_number(bin.operator, rhs);

                    if (r < 1e-10) {
                        self.diagnostics.report_error(bin.operator.line, "Division by zero");
                        return error.InvalidExpression;
                    }

                    return Values.LoxValue{ .number = l / r };
                },
                .GREATER => {
                    const l = try self.check_number(bin.operator, lhs);

                    const r = try self.check_number(bin.operator, rhs);

                    return Values.LoxValue{ .boolean = l > r };
                },
                .GREATER_EQUAL => {
                    const l = try self.check_number(bin.operator, lhs);

                    const r = try self.check_number(bin.operator, rhs);

                    return Values.LoxValue{ .boolean = l >= r };
                },
                .LESS => {
                    const l = try self.check_number(bin.operator, lhs);

                    const r = try self.check_number(bin.operator, rhs);

                    return Values.LoxValue{ .boolean = l < r };
                },
                .LESS_EQUAL => {
                    const l = try self.check_number(bin.operator, lhs);

                    const r = try self.check_number(bin.operator, rhs);

                    return Values.LoxValue{ .boolean = l <= r };
                },
                .EQUAL_EQUAL => {
                    return Values.LoxValue{ .boolean = try self.are_equal(bin.operator, lhs, rhs) };
                },
                .BANG_EQUAL => {
                    return Values.LoxValue{ .boolean = !try self.are_equal(bin.operator, lhs, rhs) };
                },
                else => {
                    return error.InvalidExpression;
                },
            }
        },
        .unary => |un| {
            const val = try self.evaluate_expr(un.expression, env);

            if (un.operator.type == .MINUS) {
                return Values.LoxValue{ .number = -try self.check_number(un.operator, val) };
            }

            if (un.operator.type == .BANG) {
                try self.check_tag(un.operator, val, .{ .nil, .boolean });

                return Values.LoxValue{ .boolean = !is_truthy(val) };
            }
        },
        .grouping => |grouping| {
            return self.evaluate_expr(grouping.expression, env);
        },
        .variable => |variable| {
            const source = try self.resolve_environment(env, expr);

            return source.lookup(variable.name.lexeme) catch {
                self.diagnostics.report("<inline>", variable.name.line, "Undefined variable '{s}'", .{variable.name.lexeme});
                return EvalError.UndefinedVariable;
            };
        },
        .assign => |assign| {
            const value = try self.evaluate_expr(assign.value, env);

            const source = try self.resolve_environment(env, expr);

            source.assign(assign.name.lexeme, value) catch |err| {
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
            } else if (logical.operator.type == .AND) {
                if (!is_truthy(lhs)) {
                    return lhs;
                }
            }

            return self.evaluate_expr(logical.right, env);
        },
    }

    return error.InvalidExpression;
}

fn resolve_environment(self: *Self, env: *Environment, expr: *const Ast.Expr) EvalError!*Environment {
    if (expr.depth) |start_depth| {
        var depth : i32 = start_depth;
        var source = env;
        while (depth > 0) {
            source = source.enclosing orelse return EvalError.InternalFailure;
            depth -= 1;
        }
        return source;
    } else {
        return self.globals;
    }
}

fn check_tag(self: *Self, token: Ast.Token, val: Values.LoxValue, comptime tags: anytype) EvalError!void {
    const tag = std.meta.activeTag(val);

    inline for (tags) |t| {
        if (tag == t) {
            return;
        }
    }

    self.diagnostics.report_error(token.line, "Unexpected type");

    return error.InvalidExpression;
}

fn check_number(self: *Self, token: Ast.Token, lhs: Values.LoxValue) EvalError!f64 {
    try self.check_tag(token, lhs, .{.number});

    return lhs.number;
}

fn check_bool(lhs: *Values.LoxValue) EvalError!f64 {
    try check_tag(lhs, .{.number});

    if (std.meta.activeTag(lhs) != .number) {
        return error.InvalidExpression;
    }

    return lhs.number;
}

fn is_truthy(val: Values.LoxValue) bool {
    return switch (val) {
        .boolean => |b| b,
        .nil => false,
        else => true,
    };
}

fn check_same_tag(self: *Self, token: Ast.Token, lhs: Values.LoxValue, rhs: Values.LoxValue) EvalError!void {
    if (@intFromEnum(lhs) != @intFromEnum(rhs)) {
        self.diagnostics.report_error(token.line, "Mismatched types");
        return error.TypeMismatch;
    }
}

fn are_equal(self: *Self, token: Ast.Token, lhs: Values.LoxValue, rhs: Values.LoxValue) EvalError!bool {
    try self.check_same_tag(token, lhs, rhs);

    return switch (lhs) {
        .number => lhs.number == rhs.number,
        .string => std.mem.eql(u8, lhs.string, rhs.string),
        .boolean => lhs.boolean == rhs.boolean,
        .callable => false,
        .nil => true,
    };
}

// TODO(jp): This uses an arena that grows unbounded - implement reference counting.
fn create_env(self: *Self, parent: ?*Environment) EvalError!*Environment {
    var allocator = self.env_pool.allocator();
    const result = allocator.create(Environment) catch return EvalError.InternalFailure;
    result.* = Environment.init(allocator, parent);
    return result;
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
