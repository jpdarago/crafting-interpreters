const std = @import("std");

const Ast = @import("ast.zig");
const Values = @import("values.zig");

const Diagnostics = @import("diagnostics.zig");

const Parser = @import("parser.zig");

const Environment = @import("environment.zig");

const Natives = @import("natives.zig");

const Errors = @import("errors.zig");

const EvalError = Errors.EvalError;

const Stdfile = std.fs.File;

const Self = @This();

allocator: std.mem.Allocator,

diagnostics: *Diagnostics,

environment: Environment,

string_pool: std.heap.ArenaAllocator,

globals: Environment,

pub fn init(allocator: std.mem.Allocator, diagnostics: *Diagnostics) EvalError!Self {
    var environment = Environment.init(allocator, null);

    for (Natives.builtins) |native| {
        const callable = Values.LoxValue{ .callable = .{ .native = native } };
        _ = try environment.define(native.name, callable);
    }

    const pool = std.heap.ArenaAllocator.init(allocator);

    return Self{ .allocator = allocator, .diagnostics = diagnostics, .environment = environment, .string_pool = pool, .globals = environment };
}

pub fn deinit(self: *Self) void {
    self.environment.deinit();
    self.string_pool.deinit();
}

pub fn evaluate(self: *Self, parser: *Parser) !Values.LoxValue {
    var program = try parser.parse();
    defer program.deinit();

    var result: Values.LoxValue = .nil;

    var it = program.statements.constIterator(0);

    while (it.next()) |stmt| {
        result = try self.evaluate_statement(stmt.*, &self.environment);
    }

    return result;
}

fn evaluate_statement(self: *Self, stmt: *const Ast.Stmt, env: *Environment) EvalError!Values.LoxValue {
    switch (stmt.*) {
        .expression => |expr| {
            return try self.evaluate_expr(expr.expression, env);
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

            return .nil;
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
                var cond = Values.LoxValue{ .boolean = true };

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
        },
        .function => |func| {

            const function = Values.LoxFunction{
                .name = func.name,
                .body = func.body.items,
                .arity = @intCast(func.params.items.len),
                .params = func.params.items,
            };

            try self.environment.define(func.name.lexeme, Values.LoxValue{ .callable = .{ .function = function }});

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

fn evaluate_expr(self: *Self, expr: *const Ast.Expr, env: *Environment) EvalError!Values.LoxValue {
    switch (expr.*) {
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

                    var new_env = Environment.init(self.allocator, &self.globals);
                    defer new_env.deinit();

                    for (func.params, 0..) |param, i| {
                        try new_env.define(param.lexeme, args.items[i]);
                    }

                    for (func.body) |stmt| {
                        _ = try self.evaluate_statement(stmt, &new_env);
                    }

                    return .nil;
                }
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
