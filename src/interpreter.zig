const std = @import("std");

const Ast = @import("ast.zig");

const Diagnostics = @import("diagnostics.zig");

const Scanner = @import("scanner.zig");

const Parser = @import("parser.zig");

const Environment = @import("environment.zig");

const Stdfile = std.fs.File;

const Self = @This();

const EvalError = error {
    InvalidType,
    TypeMismatch,
    InvalidExpression,
    DivisionByZero,
    UndefinedVariable
};

allocator: std.mem.Allocator,

diagnostics: *Diagnostics,

parser: *Parser,

environment: Environment,

pub fn init(allocator: std.mem.Allocator, diagnostics: *Diagnostics, parser: *Parser) Self {
    return Self {
        .allocator = allocator,
        .diagnostics =  diagnostics,
        .parser = parser,
        .environment = Environment.init(allocator)
    };
}

pub fn deinit(self: *Self) void {
    self.environment.deinit();
}

pub fn evaluate(self: *Self) !Ast.LoxValue {
    const ast = try self.parser.parse();

    var result : Ast.LoxValue = .nil;

    var it = ast.statements.constIterator(0);

    while (it.next()) |stmt| {
        result = try self.evaluate_statement(stmt);        
    }

    return result;
}

fn evaluate_statement(self: *Self, stmt: *const Ast.Stmt) !Ast.LoxValue {

    switch (stmt.*) {
        .expression => |expr| { 
            return try self.evaluate_expr(expr.expression);
        },
        .variable => |variable| {
            var val : Ast.LoxValue = .nil;

            if (variable.initializer) |initializer| {
                val = try self.evaluate_expr(initializer);
            }

            try self.environment.define(variable.name.lexeme, val);
        
            return .nil;
        },
        .print => |print| {

            var value = try self.evaluate_expr(print.expression);

            var buffer : [1024]u8 = undefined;

            var stdout = Stdfile.stdout().writer(&buffer);

            try value.write(&stdout.interface);
            _ = try stdout.interface.write("\n");

            try stdout.interface.flush();

            return .nil;
        }
    }
}

fn evaluate_expr(self: *Self, expr: *const Ast.Expr) !Ast.LoxValue {
    
    switch (expr.*) {
        .literal => |lit| { return lit.value; },
        .binary => |bin| {
            const lhs = try self.evaluate_expr(bin.left);
            const rhs = try self.evaluate_expr(bin.right);

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
            const val = try self.evaluate_expr(un.expression);

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
            return self.evaluate_expr(grouping.expression);
        },
        .variable => |variable| {
            return self.environment.lookup(variable.name.lexeme) catch {
                // TODO(jp): Pass the file to diagnostics and change report_error to take anyargs as well.
                // TODO(jp): Check the error type.
                self.diagnostics.report("<inline>", variable.name.line, "Undefined variable '{s}'", .{variable.name.lexeme});
                return EvalError.UndefinedVariable;
            };
        }
    }

    return error.InvalidExpression;
}

fn check_tag(self: *Self, token: Scanner.Token, val: Ast.LoxValue, comptime tags: anytype) !void {

    const tag = std.meta.activeTag(val);

    inline for (tags) |t| {
        if (tag == t) {
            return;
        }
    }

    self.diagnostics.report_error(token.line, "Unexpected type");

    return error.InvalidExpression;
}

fn check_number(self: *Self, token: Scanner.Token, lhs: Ast.LoxValue) !f64 {

    try self.check_tag(token, lhs, .{ .number });

    return lhs.number;
}

fn check_bool(lhs: *Ast.LoxValue) !f64 {

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

fn check_same_tag(self: *Self, token: Scanner.Token, lhs: Ast.LoxValue, rhs: Ast.LoxValue) !void {
    if (@intFromEnum(lhs) != @intFromEnum(rhs)) {
        self.diagnostics.report_error(token.line, "Mismatched types");
        return error.TypeMismatch;
    }
}

fn are_equal(self: *Self, token: Scanner.Token, lhs: Ast.LoxValue, rhs: Ast.LoxValue) !bool {

    try self.check_same_tag(token, lhs, rhs);

    return switch (lhs) {
        .number => lhs.number == rhs.number,
        .string => std.mem.eql(u8, lhs.string, rhs.string),
        .boolean => lhs.boolean == rhs.boolean,
        .nil => true
    };
}

// TODO(jp): This needs a garbage collector of some sort.
fn concat_strings(self: *Self, lhs: []const u8, rhs: []const u8) ![]u8 {

    const result = try self.allocator.alloc(u8, lhs.len + rhs.len);

    std.mem.copyForwards(u8, result[0..lhs.len], lhs);
    std.mem.copyForwards(u8, result[lhs.len..], rhs);

    return result;
}
