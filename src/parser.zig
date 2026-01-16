const std = @import("std");

const Ast = @import("ast.zig");
const Diagnostics = @import("diagnostics.zig");
const Scanner = @import("scanner.zig");

const Expr = Ast.Expr;
const LoxValue = Ast.LoxValue;

const Self = @This();

const ParseError = error {
    UnexpectedToken,
    ExpressionExpected,
    FloatError,
    OutOfMemory
};

allocator: std.mem.Allocator,

current: usize,

tokens: []const Scanner.Token,

// We use a segmented list to ensure pointer stability.
nodes: std.SegmentedList(Expr, 64),

ast: ?*Expr,

diagnostics: *Diagnostics,

pub fn init(
    allocator: std.mem.Allocator, 
    diagnostics: *Diagnostics,
    tokens: []const Scanner.Token,
) Self {
    return Self {
        .allocator = allocator,
        .diagnostics = diagnostics,
        .tokens = tokens,
        .current = 0,
        .nodes = std.SegmentedList(Expr, 64) {},
        .ast = null,
    };
}

pub fn deinit(self: *Self) void {
    self.nodes.deinit(self.allocator);
}

pub fn parse(self: *Self) !*Expr {
    return self.expression();
}

fn expression(self: *Self) !*Expr {
    return self.equality();
}

fn make_node(self: *Self, node: anytype) !*Expr {
    try self.nodes.append(self.allocator, undefined);
    const p = self.nodes.at(self.nodes.len - 1);
    p.* = Expr.make(node);
    return p;
}

fn match(self: *Self, comptime args: anytype) bool {

    inline for (args) |tok| {
        if (self.check(tok)) {
            _ = self.advance();
            return true;
        }
    } 

    return false;
}

fn check(self: *Self, tok: Scanner.TokenType) bool {
    if (self.peek()) |token| {
        return token.type == tok;
    } else {
        return false;
    }
}

fn at_end(self: *Self) bool {
    return self.current == self.tokens.len;
}

fn peek(self: *Self) ?Scanner.Token {
    if (self.at_end()) return null;
    return self.tokens[self.current];
}

fn consume(self: *Self, token: Scanner.TokenType, message: []const u8) ParseError!void {

    if (self.check(token)) {
        _ = self.advance();
        return;
    }

    const current = self.peek().?;

    self.diagnostics.report_error(current.line, message);

    return ParseError.UnexpectedToken; 
}

fn previous(self: *Self) ?Scanner.Token {
    if (self.current == 0) return null;
    return self.tokens[self.current - 1];
}

fn advance(self: *Self) ?Scanner.Token {
    if (!self.at_end()) {
        self.current += 1;
    }
    return self.previous();
}

fn equality(self: *Self) ParseError!*Expr {
    var expr = try self.comparison();

    while (self.match(.{.BANG_EQUAL, .EQUAL_EQUAL})) {

        const operator = self.previous().?;
        const right = try self.comparison();

        expr = try self.make_node(Expr.Binary {
            .left = expr, 
            .operator = operator, 
            .right = right 
        });
    }

    return expr;
}

fn comparison(self: *Self) ParseError!*Expr {

    var expr = try self.term();

    while (self.match(.{.GREATER, .GREATER_EQUAL, .LESS, .LESS_EQUAL})) {

        const operator = self.previous().?;
        const right = try self.term();

        expr = try self.make_node(Expr.Binary {
            .left = expr, 
            .operator = operator, 
            .right = right 
        });
    }

    return expr;
}

fn term(self: *Self) ParseError!*Expr {

    var expr = try self.factor();

    while (self.match(.{.MINUS, .PLUS})) {

        const operator = self.previous().?;
        const right = try self.factor();

        expr = try self.make_node(Expr.Binary {
            .left = expr, 
            .operator = operator, 
            .right = right 
        });
    }

    return expr;
}

fn factor(self: *Self) ParseError!*Expr {
    
    var expr = try self.unary();

    while (self.match(.{.SLASH, .STAR})) {
        
        const operator = self.previous().?;
        const right = try self.unary();

        expr = try self.make_node(Expr.Binary {
            .left = expr,
            .operator = operator,
            .right = right
        });
    }

    return expr;
}

fn unary(self: *Self) ParseError!*Expr {

    if (self.match(.{.BANG, .MINUS})) {
        
        const operator = self.previous();
        const right = try self.unary();

        return self.make_node(Expr.Unary {
            .operator = operator.?,
            .expression = right
        });
    }

    return self.primary();
}

fn primary(self: *Self) ParseError!*Expr {

    if (self.match(.{.FALSE})) {

        const value = LoxValue {
            .boolean = false
        };

        return self.make_node(Expr.Literal { 
            .value = value 
        });
    }

    if (self.match(.{.TRUE})) {

        const value = LoxValue {
            .boolean = true
        };

        return self.make_node(Expr.Literal { 
            .value = value 
        });
    }

    if (self.match(.{.NIL})) {

        const value : LoxValue = .nil;

        return self.make_node(Expr.Literal { 
            .value = value 
        });
    }

    if (self.match(.{.NUMBER})) {

        const token = self.previous().?;

        const fp = std.fmt.parseFloat(f64, token.lexeme) catch {
            self.diagnostics.report("<inline>", token.line, "Unparseable float [{s}]", .{token.lexeme});
            return ParseError.FloatError;
        };

        const value = LoxValue {
            .number = fp
        };

        return self.make_node(Expr.Literal { 
            .value = value 
        });
    }

    if (self.match(.{.STRING})) {

        const token = self.previous().?;

        const value = LoxValue {
            .string = token.lexeme
        };

        return self.make_node(Expr.Literal { 
            .value = value
        });
    }

    if (self.match(.{ .LEFT_PAREN })) {

        const expr = try self.expression();

        try self.consume(.RIGHT_PAREN, "Expect ')' after expression.");

        return self.make_node(Expr.Grouping {
            .expression = expr
        });
    }

    if (self.at_end()) {

        // TODO(jp): Fix properly.
        self.diagnostics.report_error(9999, "Expected expression");

    } else {

        self.diagnostics.report_error(self.previous().?.line, "Expected expression");
    }


    return ParseError.ExpressionExpected;
}
