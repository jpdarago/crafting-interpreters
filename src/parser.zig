const std = @import("std");

const Ast = @import("ast.zig");
const Diagnostics = @import("diagnostics.zig");
const Scanner = @import("scanner.zig");

const ParseError = @import("errors.zig").ParseError;

const Expr = Ast.Expr;
const LoxValue = Ast.LoxValue;
const Program = Ast.Program;
const Stmt = Ast.Stmt;

const Self = @This();

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

pub fn parse(self: *Self) !Program {

    var program = Program.init(self.allocator);

    while (!self.at_end()) {
        try program.statements.append(self.allocator, try self.statement());
    }

    return program;
}

fn make_node(self: *Self, node: anytype) !*Expr {
    try self.nodes.append(self.allocator, undefined);
    const p = self.nodes.at(self.nodes.len - 1);
    p.* = Expr.make(node);
    return p;
}

fn declaration(self: *Self) !Stmt {
    
    const is_var_decl = self.match(.{ .VAR }) catch |err| {
        // TODO(jp): We should synchronize only on parse error.
        self.synchronize();
        return err;
    };

    if (is_var_decl) {
        return self.var_declaration();
    }
}

fn var_declaration(self: *Self) !Stmt {

    const name = try self.consume(.IDENTIFIER, "Expected variable name");

    var initializer : ?*Ast.Expr = null;

    if (self.match(.{ .EQUAL })) {
        initializer = try self.expression();
    }

    try self.consume(.SEMICOLON, "Expect ';' after variable declaration");
    return self.make_node(Expr.Variable {
        .name = name,
        .initializer = initializer 
    });
}

fn synchronize(self: *Self) void {

    self.advance();

    while (!self.at_end()) {

        if (self.previous().?.type == .SEMICOLON) {
            return;
        }

        switch (self.peek().?.type) {
            .CLASS => return,
            .FUN => return,
            .VAR => return,
            .FOR => return,
            .IF => return,
            .WHILE => return,
            .PRINT => return,
            .RETURN => return,
        }
    }

    self.advance();
}

fn statement(self: *Self) !Stmt {
    if (self.match(.{.PRINT})) {
        return self.print_statement();
    }

    return self.expression_statement();
}

fn print_statement(self: *Self) !Stmt {

    const expr = try self.expression();

    try self.consume(.SEMICOLON, "Expected ';' after value");

    return Stmt { .print = Stmt.Print { .expression = expr.* } };
}

pub fn expression_statement(self: *Self) !Stmt {

    const expr = try self.expression();

    try self.consume(.SEMICOLON, "Expected ';' after value");

    return Stmt { .expression = Stmt.Expression { .expression = expr.* } };
}

fn expression(self: *Self) !*Expr {
    return self.equality();
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

    if (self.at_end()) {

        self.diagnostics.report_error(0, message);

        return ParseError.ExpressionExpected;
    }

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

    if (self.match(.{.IDENTIFIER})) {

        const token = self.previous().?;

        return self.make_node(Expr.Variable {
            .name = token
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

        self.diagnostics.report("<eof>", 0, "Expected expression", .{});

    } else {

        self.diagnostics.report_error(self.previous().?.line, "Expected expression");
    }

    return ParseError.ExpressionExpected;
}
